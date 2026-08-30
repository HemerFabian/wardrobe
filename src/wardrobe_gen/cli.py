from __future__ import annotations

import argparse
import base64
import datetime as _dt
import hashlib
import json
import os
import random
import re
import shutil
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Tuple

import requests
from PIL import Image

from .config import load_config, resolve_path
from .dataset import (
    ClassificationInfo,
    Dataset,
    Item,
    PendingIntakeItem,
    Pose,
    overlay_meta_output_path,
    overlay_output_path,
    render_meta_output_path,
    render_output_path,
    scan_dataset,
    slugify,
)
from .doctor import print_doctor_report, run_doctor
from .output_size import resolve_output_size
from .overlay import build_overlay_band_from_rendered
from .packaging import build_thumbnails, build_zip
from .progress import ProgressTracker, format_duration
from .render_types import RenderRequest
from .renderers.comfyui import ComfyUIRenderer
from .renderers.mock import MockRenderer
from .renderers.ollama_vlm import OllamaVLMClient, OllamaVLMError
from .result_manifest import ResultManifest, build_result_manifest

CATEGORIES = ["top", "bottom", "headwear", "shoes"]
OVERLAY_REPRESENTATIVE_SAMPLE_LIMIT = 48
OVERLAY_PREVIEW_SAMPLE_LIMIT = 5
MAX_RENDER_SEED = 2**31


@dataclass(frozen=True)
class _PendingOverlayJob:
    pose: Pose
    category: str
    item: Item
    base_for_overlay_generation: Path
    base_renders: list[Path]
    overlay_render_path: Path
    output_path: Path
    started_at: float


def _hash32(text: str) -> int:
    digest = hashlib.md5(text.encode("utf-8"), usedforsecurity=False).digest()
    return int.from_bytes(digest[:4], "little")


def _resolve_render_seed(base_seed: int | None, key: str, *, offset: int = 0) -> int:
    if base_seed is None:
        return random.randrange(MAX_RENDER_SEED)
    return (base_seed + offset + _hash32(key)) % MAX_RENDER_SEED


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Wardrobe generator CLI")
    parser.add_argument(
        "--config",
        default=None,
        help="Optional YAML/JSON config (default: ./config.local.yaml when present)",
    )

    subparsers = parser.add_subparsers(dest="command", required=True)

    render = subparsers.add_parser("render", help="Render base images and overlays")
    render.add_argument(
        "workspace",
        help="Workspace root directory",
    )
    render.add_argument("--pose", default=None, help="Pose id to render")
    render.add_argument("--top", default=None, help="Top item id to render (slug)")
    render.add_argument(
        "--bottom", default=None, help="Bottom item id to render (slug)"
    )
    render.add_argument("--renderer", default=None, help="Renderer override")
    render.add_argument(
        "--include-overlay-previews",
        action="store_true",
        help="Generate debug overlay previews (base render + overlay composite)",
    )
    render.add_argument("--force", action="store_true", help="Force re-render")
    render.add_argument(
        "--max-images",
        type=int,
        default=None,
        help="Maximum number of images to generate (across base + overlays)",
    )
    render.add_argument(
        "--input-megapixels",
        type=float,
        default=None,
        help="Megapixels target for ImageScaleToTotalPixels nodes (overrides config)",
    )
    render.add_argument(
        "--seed",
        type=int,
        default=None,
        help="Base seed for deterministic renders (omit for non-deterministic mode)",
    )
    render.add_argument("--steps", type=int, default=None, help="Override steps")
    render.add_argument("--cfg", type=float, default=None, help="Override cfg")
    render.add_argument("--sampler", default=None, help="Override sampler")

    pack = subparsers.add_parser("pack", help="Build content pack ZIP")
    pack.add_argument(
        "workspace",
        help="Workspace root directory",
    )
    pack.add_argument(
        "--zip-path",
        default=None,
        help="Output zip path (default: workspace_root/wardrobe_pack.zip)",
    )

    validate = subparsers.add_parser("validate", help="Validate workspace and outputs")
    validate.add_argument(
        "workspace",
        help="Workspace root directory",
    )
    validate.add_argument("--pose", default=None, help="Pose id to validate")

    classify = subparsers.add_parser(
        "classify",
        help="Classify pending intake clothing items and pose names with VLM",
    )
    classify.add_argument(
        "workspace",
        help="Workspace root directory",
    )
    classify.add_argument(
        "--limit",
        type=int,
        default=None,
        help="Maximum number of pending items to classify",
    )
    classify.add_argument(
        "--force",
        action="store_true",
        help="Re-run classification for all poses and use unique fallback IDs for duplicate item names",
    )
    classify.add_argument(
        "--dry-run",
        action="store_true",
        help="Validate model outputs without writing workspace changes",
    )
    classify.add_argument(
        "--show-raw-vlm",
        action="store_true",
        help="Print raw prompts and raw VLM responses during classify",
    )

    subparsers.add_parser("doctor", help="Check the local AI pipeline setup")

    return parser.parse_args()


def main() -> None:
    args = parse_args()
    repo_root = Path.cwd()
    config = load_config(args.config, cwd=repo_root)

    if args.command == "doctor":
        checks = run_doctor(config, cwd=repo_root)
        if not print_doctor_report(checks, explicit_config=args.config):
            raise SystemExit(1)
        return

    _apply_cutout_config(config, repo_root)

    workspace_root = _resolve_workspace_root(
        repo_root=repo_root,
        workspace_arg=args.workspace,
        config=config,
    )

    dataset = scan_dataset(workspace_root, CATEGORIES)

    if args.command == "render":
        _ensure_classification_ready_for_render(dataset, config)
        workflow_path = resolve_path(repo_root, config["workflow_template"])
        renderer_name = args.renderer or config.get("renderer", "comfyui")
        renderer = _build_renderer(renderer_name, config, workflow_path)
        _render_all(
            args,
            config,
            dataset,
            workspace_root,
            renderer,
            repo_root=repo_root,
        )
        return

    if args.command == "classify":
        _run_classify(args, config, dataset, workspace_root)
        return

    if args.command == "pack":
        _ensure_pack_preconditions(dataset)
        images_cfg = config["images"]
        build_thumbnails(
            dataset,
            workspace_root,
            tuple(images_cfg["thumbnail_size"]),
            images_cfg["thumbnail_format"],
        )
        manifest_payload = build_result_manifest(dataset, workspace_root, config)
        _ensure_required_renders_complete(manifest_payload)
        manifest_path = ResultManifest(workspace_root).path
        _preserve_generated_at_for_unchanged_manifest(
            manifest_payload,
            manifest_path,
        )
        manifest_path.write_text(
            json.dumps(manifest_payload, indent=2),
            encoding="utf-8",
        )
        zip_path = (
            Path(args.zip_path)
            if args.zip_path
            else workspace_root / "wardrobe_pack.zip"
        )
        build_zip(workspace_root, zip_path, manifest_payload)
        print(f"Pack written to {zip_path}")
        return

    if args.command == "validate":
        _validate(args, dataset, workspace_root)
        print("Validation complete")
        return



def _apply_cutout_config(config: dict[str, Any], repo_root: Path) -> None:
    cutout = config.get("cutout") or {}
    checkpoint = resolve_path(repo_root, cutout["sam_checkpoint"])
    os.environ.setdefault("WARDROBE_SAM_VIT_H_CHECKPOINT", str(checkpoint))
    os.environ.setdefault("WARDROBE_CUTOUT_DEVICE", str(cutout.get("device", "auto")))
    os.environ.setdefault(
        "WARDROBE_CUTOUT_ALLOW_DOWNLOAD",
        "1" if bool(cutout.get("allow_download", False)) else "0",
    )


def _preserve_generated_at_for_unchanged_manifest(
    payload: dict[str, Any],
    existing_path: Path,
) -> None:
    if not existing_path.is_file():
        return
    try:
        existing = json.loads(existing_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return
    if not isinstance(existing, dict):
        return

    existing_generated_at = existing.get("generated_at")
    if not isinstance(existing_generated_at, str) or not existing_generated_at:
        return

    existing_without_timestamp = dict(existing)
    payload_without_timestamp = dict(payload)
    existing_without_timestamp.pop("generated_at", None)
    payload_without_timestamp.pop("generated_at", None)
    if existing_without_timestamp == payload_without_timestamp:
        payload["generated_at"] = existing_generated_at


def _resolve_workspace_root(
    *,
    repo_root: Path,
    workspace_arg: str | None,
    config: dict[str, Any],
) -> Path:
    raw_workspace = (workspace_arg or "").strip()
    if not raw_workspace:
        raw_workspace = str(config.get("workspace_root") or "").strip()
    if not raw_workspace:
        raise SystemExit(
            "Workspace path missing. Pass <workspace> or set workspace_root in config."
        )

    workspace_root = resolve_path(repo_root, raw_workspace)
    if not workspace_root.exists():
        raise SystemExit(f"Workspace path not found: {workspace_root}")
    if not workspace_root.is_dir():
        raise SystemExit(f"Workspace path is not a directory: {workspace_root}")
    return workspace_root


def _build_renderer(name: str, config: dict, workflow_path: Path | None):
    if name == "comfyui":
        if workflow_path is None:
            raise ValueError("workflow_path is required for comfyui renderer")
        return ComfyUIRenderer(config, workflow_path)
    if name == "mock":
        return MockRenderer(config)
    raise ValueError(f"Unknown renderer: {name}")


def _run_classify(
    args: argparse.Namespace,
    config: dict[str, Any],
    dataset: Dataset,
    workspace_root: Path,
) -> None:
    pending_items = list(dataset.intake_queue)
    pending_pose_indexes = _collect_pending_pose_indexes(
        dataset,
        include_all=args.force,
    )
    pending_work: list[tuple[str, Any]] = [("item", item) for item in pending_items] + [
        ("pose", pose_index) for pose_index in pending_pose_indexes
    ]
    if args.limit is not None:
        pending_work = pending_work[: max(0, int(args.limit))]

    if not pending_work:
        print("No pending intake items or pose names found.")
        return

    vlm_cfg = config.get("vlm") or {}
    provider = str(vlm_cfg.get("provider", "ollama")).strip().lower()
    if provider != "ollama":
        raise SystemExit(f"Unsupported VLM provider: {provider}")

    client = OllamaVLMClient(
        endpoint=str(vlm_cfg.get("endpoint", "http://127.0.0.1:11434")),
        model=str(vlm_cfg.get("model", "qwen3-vl:8b")),
        timeout_sec=int(vlm_cfg.get("timeout_sec", 120)),
        temperature=float(vlm_cfg.get("temperature", 0.1)),
    )
    max_retries = max(0, int(vlm_cfg.get("max_retries", 2)))
    prompt_version = str(vlm_cfg.get("prompt_version", "2026-02-21-v1"))

    existing_ids_by_category: dict[str, set[str]] = {
        category: {item.item_id for item in dataset.items_by_category.get(category, [])}
        for category in CATEGORIES
    }
    existing_pose_names = {
        _normalize_pose_name_value(pose.name).lower()
        for pose in dataset.poses
        if _normalize_pose_name_value(pose.name)
    }
    vocab = _collect_existing_vocab(dataset)

    item_success_count = 0
    item_failure_count = 0
    pose_success_count = 0
    pose_failure_count = 0
    emit_raw_trace = bool(getattr(args, "show_raw_vlm", False))
    tracker = ProgressTracker(name="classify", total_units=len(pending_work))
    print(tracker.format_start_line())

    for work_type, work_payload in pending_work:
        if work_type == "item":
            pending_item = work_payload
            step_label = f"item={pending_item.item_id}"
        else:
            pose = dataset.poses[int(work_payload)]
            step_label = f"pose={pose.pose_id}"

        step_started = time.perf_counter()
        try:

            def _emit_raw_trace(
                phase: str,
                payload: Any,
                *,
                _step_label: str = step_label,
            ) -> None:
                if not emit_raw_trace:
                    return
                print(f"  [raw][{_step_label}][{phase}]")
                formatted = _format_raw_trace_payload(payload)
                if not formatted:
                    print("    <empty>")
                    return
                for line in formatted.splitlines():
                    print(f"    {line}")

            if work_type == "item":
                normalized = _classify_pending_item(
                    client=client,
                    pending_item=pending_item,
                    vocab=vocab,
                    max_retries=max_retries,
                    raw_trace=_emit_raw_trace if emit_raw_trace else None,
                )
                print(
                    "  name={name} category={category} subcategory={subcategory} "
                    "color_primary={color_primary} material={material} "
                    "style_occasion={style_occasion} pattern_design={pattern_design}".format(
                        **normalized
                    )
                )

                if not args.dry_run:
                    _apply_classification_result(
                        workspace_root=workspace_root,
                        dataset=dataset,
                        pending_item=pending_item,
                        normalized=normalized,
                        provider=provider,
                        model=client.model,
                        prompt_version=prompt_version,
                        existing_ids_by_category=existing_ids_by_category,
                    )
                    _update_vocab(vocab, normalized)

                item_success_count += 1
            else:
                pose_index = int(work_payload)
                pose = dataset.poses[pose_index]
                generated_name = _classify_pose_name(
                    client=client,
                    pose=pose,
                    max_retries=max_retries,
                    raw_trace=_emit_raw_trace if emit_raw_trace else None,
                )
                resolved_pose_name = _make_unique_pose_name(
                    base_name=generated_name,
                    existing_lower=existing_pose_names,
                    current_name=pose.name,
                )
                print(f"  pose_name={resolved_pose_name}")
                if not args.dry_run:
                    _apply_pose_name_result(
                        workspace_root=workspace_root,
                        dataset=dataset,
                        pose_index=pose_index,
                        pose=pose,
                        pose_name=resolved_pose_name,
                    )
                pose_success_count += 1

            tracker.record_step(
                duration_sec=time.perf_counter() - step_started,
                label=step_label,
                success=True,
            )
            print(tracker.format_line(label=step_label, success=True))
        except Exception as error:
            if work_type == "item":
                item_failure_count += 1
            else:
                pose_failure_count += 1
            print(f"  ERROR: {error}")
            tracker.record_step(
                duration_sec=time.perf_counter() - step_started,
                label=step_label,
                success=False,
            )
            print(tracker.format_line(label=step_label, success=False))
            continue

    if args.dry_run:
        print(
            "Dry-run complete. "
            f"items_ok={item_success_count} "
            f"items_failed={item_failure_count} "
            f"poses_ok={pose_success_count} "
            f"poses_failed={pose_failure_count} "
            f"elapsed={format_duration(tracker.elapsed_seconds())}"
        )
        print(tracker.format_finish_line())
        return

    ResultManifest(workspace_root).write(dataset, config)
    print(
        "Classification complete. "
        f"items_ok={item_success_count} "
        f"items_failed={item_failure_count} "
        f"poses_ok={pose_success_count} "
        f"poses_failed={pose_failure_count} "
        f"elapsed={format_duration(tracker.elapsed_seconds())}"
    )
    print(tracker.format_finish_line())


def _format_raw_trace_payload(payload: Any) -> str:
    if isinstance(payload, str):
        return payload
    try:
        return json.dumps(payload, indent=2, ensure_ascii=False)
    except Exception:
        return repr(payload)


def _error_with_raw_response(error: Exception, response_payload: Any | None) -> str:
    base = str(error)
    if response_payload is None:
        return base
    raw = _format_raw_trace_payload(response_payload).strip()
    if not raw:
        return base
    return f"{base}\nraw_response:\n{raw}"


def _collect_pending_pose_indexes(
    dataset: Dataset, include_all: bool = False
) -> list[int]:
    if include_all:
        return list(range(len(dataset.poses)))
    return [
        index
        for index, pose in enumerate(dataset.poses)
        if _pose_name_requires_classification(pose.name)
    ]


_POSE_PLACEHOLDER_PATTERN = re.compile(r"^pose(?:\s+\d+)?$")


def _pose_name_requires_classification(name: str | None) -> bool:
    normalized = _normalize_pose_name_value(name).lower()
    if not normalized:
        return True
    if normalized in {
        "pose",
        "pending pose",
        "pending-pose",
        "new pose",
        "unnamed pose",
    }:
        return True
    return bool(_POSE_PLACEHOLDER_PATTERN.fullmatch(normalized))


def _normalize_pose_name_value(raw_value: Any) -> str:
    return " ".join(str(raw_value or "").strip().split())


def _build_pose_name_prompt() -> str:
    schema = {"name": "Front"}
    schema_text = json.dumps(schema, indent=2)
    return (
        "Analyze the person pose image and respond with JSON only.\n"
        "Return a very simple pose name using 1-2 common words.\n"
        "Use a generic everyday label, not a detailed description.\n"
        "Capitalize the first letter of the name.\n"
        'Good examples: "Front", "Side", "Back", "Sitting", "Walking".\n'
        "Few-shot examples:\n"
        '- Person facing the camera -> {"name": "Front"}\n'
        '- Person shown in profile -> {"name": "Side"}\n'
        '- Person turned away from the camera -> {"name": "Back"}\n'
        '- Person is seated -> {"name": "Sitting"}\n'
        "Do not include category or clothing metadata.\n"
        "Do not return arrays.\n\n"
        "Output JSON schema:\n"
        f"{schema_text}\n"
    )


def _classify_pose_name(
    *,
    client: OllamaVLMClient,
    pose: Pose,
    max_retries: int,
    raw_trace: Callable[[str, Any], None] | None = None,
) -> str:
    prompt = _build_pose_name_prompt()
    if raw_trace is not None:
        raw_trace("prompt", prompt)
    attempt = 0
    while True:
        attempt += 1
        response_payload: Any = None
        try:
            response = client.classify(pose.path, prompt)
            response_payload = response
            if raw_trace is not None:
                raw_trace(f"response_attempt_{attempt}", response)
            return _normalize_and_validate_pose_name(response)
        except Exception as error:
            error_detail = _error_with_raw_response(error, response_payload)
            if raw_trace is not None:
                raw_trace(f"error_attempt_{attempt}", error_detail)
            fallback_name = _classify_pose_name_with_loose_parser(
                client=client,
                pose=pose,
                prompt=prompt,
                raw_trace=raw_trace,
            )
            if fallback_name is not None:
                return fallback_name
            if attempt >= (max_retries + 1):
                raise RuntimeError(
                    f"pose naming failed for {pose.pose_id} after {attempt - 1} retries: {error_detail}"
                ) from error
            print(f"  retry {attempt}/{max_retries} due to: {error_detail}")


def _normalize_and_validate_pose_name(response: Any) -> str:
    if isinstance(response, dict):
        raw_name = (
            response.get("name")
            or response.get("pose_name")
            or response.get("label")
            or response.get("id")
        )
    elif isinstance(response, str):
        stripped = response.strip()
        raw_name = stripped
        if stripped:
            try:
                parsed = json.loads(stripped)
            except Exception:
                parsed = None
            if isinstance(parsed, dict):
                raw_name = (
                    parsed.get("name")
                    or parsed.get("pose_name")
                    or parsed.get("label")
                    or parsed.get("id")
                    or stripped
                )
    else:
        raw_name = response
    name = _normalize_pose_name_value(raw_name)
    if not name:
        raise ValueError("missing pose name")
    return name[:1].upper() + name[1:]


def _classify_pose_name_with_loose_parser(
    *,
    client: OllamaVLMClient,
    pose: Pose,
    prompt: str,
    raw_trace: Callable[[str, Any], None] | None = None,
) -> str | None:
    if not pose.path.exists():
        return None
    encoded_image = base64.b64encode(pose.path.read_bytes()).decode("ascii")
    payload = {
        "model": client.model,
        "stream": False,
        "messages": [
            {
                "role": "user",
                "content": prompt,
                "images": [encoded_image],
            }
        ],
        "options": {"temperature": client.temperature},
    }
    url = f"{client.endpoint.rstrip('/')}/api/chat"
    try:
        response = requests.post(url, json=payload, timeout=client.timeout_sec)
        response.raise_for_status()
        parsed = response.json()
    except Exception as error:
        if raw_trace is not None:
            raw_trace("fallback_error", repr(error))
        return None

    if not isinstance(parsed, dict):
        return None

    content = ""
    message = parsed.get("message")
    if isinstance(message, dict):
        content = str(message.get("content") or "")
    if not content:
        content = str(parsed.get("response") or "")
    if raw_trace is not None:
        raw_trace("fallback_response_content", content)
    if not content:
        return None

    try:
        return _normalize_and_validate_pose_name(content)
    except Exception:
        return None


def _make_unique_pose_name(
    *,
    base_name: str,
    existing_lower: set[str],
    current_name: str | None,
) -> str:
    normalized_base = _normalize_pose_name_value(base_name)
    if not normalized_base:
        normalized_base = "Pose"

    current_normalized = _normalize_pose_name_value(current_name).lower()
    if current_normalized:
        existing_lower.discard(current_normalized)

    candidate = normalized_base
    counter = 2
    while candidate.lower() in existing_lower:
        candidate = f"{normalized_base} {counter}"
        counter += 1
    existing_lower.add(candidate.lower())
    return candidate


def _apply_pose_name_result(
    *,
    workspace_root: Path,
    dataset: Dataset,
    pose_index: int,
    pose: Pose,
    pose_name: str,
) -> None:
    meta_path = pose.meta_path or (
        workspace_root / "poses" / pose.pose_id / "pose.yaml"
    )
    meta_payload: dict[str, Any] = {}
    if meta_path.exists():
        try:
            loaded = json.loads(meta_path.read_text(encoding="utf-8"))
            if isinstance(loaded, dict):
                meta_payload = loaded
        except Exception:
            meta_payload = {}

    meta_payload.update(
        {
            "id": pose.pose_id,
            "name": pose_name,
            "path": _relative_path(pose.path, workspace_root),
            "thumb_path": _relative_path(pose.thumb_path, workspace_root)
            if pose.thumb_path is not None
            else None,
            "meta_path": _relative_path(meta_path, workspace_root),
            "render_ready": bool(pose.render_ready),
        }
    )
    if pose.neck_y is not None:
        meta_payload["neck_y"] = pose.neck_y
    if pose.ankle_y is not None:
        meta_payload["ankle_y"] = pose.ankle_y
    meta_path.parent.mkdir(parents=True, exist_ok=True)
    meta_path.write_text(json.dumps(meta_payload, indent=2), encoding="utf-8")

    updated_pose = Pose(
        pose_id=pose.pose_id,
        name=pose_name,
        path=pose.path,
        thumb_path=pose.thumb_path,
        meta_path=meta_path,
        neck_y=pose.neck_y,
        ankle_y=pose.ankle_y,
        render_ready=pose.render_ready,
    )
    dataset.poses[pose_index] = updated_pose


def _ensure_classification_ready_for_render(
    dataset: Dataset, config: dict[str, Any]
) -> None:
    classify_cfg = config.get("classify") or {}
    require = bool(classify_cfg.get("require_before_render", True))
    if not require:
        return
    pending_count = len(dataset.intake_queue)
    pending_pose_count = len(_collect_pending_pose_indexes(dataset))
    if pending_count > 0 or pending_pose_count > 0:
        raise SystemExit(
            "Render blocked: pending classification exists "
            f"(intake_queue={pending_count}, pending_pose_names={pending_pose_count}). Run "
            "`python -m tools.wardrobe_gen.cli classify <workspace>` first."
        )


def _ensure_pack_preconditions(dataset: Dataset) -> None:
    pending_count = len(dataset.intake_queue)
    pending_pose_count = len(_collect_pending_pose_indexes(dataset))
    if pending_count > 0 or pending_pose_count > 0:
        raise SystemExit(
            "Pack blocked: pending classification exists "
            f"(intake_queue={pending_count}, pending_pose_names={pending_pose_count}). Run "
            "`python -m tools.wardrobe_gen.cli classify <workspace>` first."
        )


def _ensure_required_renders_complete(manifest_payload: dict[str, Any]) -> None:
    missing: list[str] = []

    poses = manifest_payload.get("poses")
    if isinstance(poses, list):
        for pose in poses:
            if not isinstance(pose, dict):
                continue
            if bool(pose.get("render_ready", False)):
                continue
            pose_id = pose.get("id", "<unknown>")
            missing.append(f"pose:{pose_id}")

    categories = manifest_payload.get("categories")
    if isinstance(categories, dict):
        for category in ("top", "bottom"):
            raw_items = categories.get(category, [])
            if not isinstance(raw_items, list):
                continue
            for item in raw_items:
                if not isinstance(item, dict):
                    continue
                if bool(item.get("render_ready", False)):
                    continue
                item_id = item.get("id", "<unknown>")
                missing.append(f"{category}:{item_id}")

    if missing:
        preview = ", ".join(missing[:12])
        raise SystemExit(
            "Pack blocked: required renders are missing for "
            f"{preview}. Run render before pack."
        )


def _classify_pending_item(
    *,
    client: OllamaVLMClient,
    pending_item: PendingIntakeItem,
    vocab: dict[str, Any],
    max_retries: int,
    raw_trace: Callable[[str, Any], None] | None = None,
) -> dict[str, str]:
    prompt = _build_classify_prompt(vocab)
    if raw_trace is not None:
        raw_trace("prompt", prompt)
    attempt = 0
    while True:
        attempt += 1
        response_payload: Any = None
        try:
            response = client.classify(pending_item.path, prompt)
            response_payload = response
            if raw_trace is not None:
                raw_trace(f"response_attempt_{attempt}", response)
            if not isinstance(response, dict):
                raise ValueError("Model output is not a JSON object.")
            return _normalize_and_validate_classification(response)
        except Exception as error:
            error_detail = _error_with_raw_response(error, response_payload)
            if raw_trace is not None:
                raw_trace(f"error_attempt_{attempt}", error_detail)
            if _is_non_retryable_classify_error(error):
                raise RuntimeError(
                    f"classification failed for {pending_item.item_id} after {attempt - 1} retries: {error_detail}"
                ) from error
            if attempt >= (max_retries + 1):
                raise RuntimeError(
                    f"classification failed for {pending_item.item_id} after {attempt - 1} retries: {error_detail}"
                ) from error
            print(f"  retry {attempt}/{max_retries} due to: {error_detail}")


def _is_non_retryable_classify_error(error: Exception) -> bool:
    if isinstance(error, FileNotFoundError):
        return True
    if isinstance(error, OllamaVLMError) and str(error).lower().startswith(
        "image not found:"
    ):
        return True
    return "image not found:" in str(error).lower()


def _build_classify_prompt(vocab: dict[str, Any]) -> str:
    def _line(name: str) -> str:
        raw_values = vocab.get(name, [])
        values = (
            [str(value).strip() for value in raw_values]
            if isinstance(raw_values, list)
            else []
        )
        values = [value for value in values if value]
        if not values:
            return f"- {name}: []"
        joined = ", ".join(values[:40])
        return f"- {name}: [{joined}]"

    def _subcategory_lines() -> str:
        raw_map = vocab.get("subcategory_by_category", {})
        by_category = raw_map if isinstance(raw_map, dict) else {}
        lines: list[str] = []
        for category in CATEGORIES:
            raw_values = by_category.get(category, [])
            values = (
                [str(value).strip() for value in raw_values]
                if isinstance(raw_values, list)
                else []
            )
            values = [value for value in values if value]
            if not values:
                lines.append(f"- {category}: []")
                continue
            joined = ", ".join(values[:40])
            lines.append(f"- {category}: [{joined}]")
        return "\n".join(lines)

    schema = {
        "name": "string",
        "category": "top|bottom|headwear|shoes",
        "subcategory": "string",
        "color_primary": "string",
        "material": "string",
        "style_occasion": "string",
        "pattern_design": "string",
    }
    schema_text = json.dumps(schema, indent=2)
    return (
        "Classify the clothing item in the image and respond with JSON only.\n"
        "You MUST return exactly one value per field.\n"
        "Generate a short human-readable name for the item.\n"
        "Do not output any id or label fields.\n"
        "If an existing value semantically fits, reuse it exactly.\n"
        "If no existing value fits, create a new concise lowercase value.\n"
        "Do not output arrays. Do not output tags.\n"
        "Avoid composite/multi values like 'casual, private' or 'sport/business'.\n"
        "Never use conjunctions in field values (for example: and, und, or, &).\n\n"
        "Allowed category values: top, bottom, headwear, shoes\n\n"
        "Field guidance:\n"
        "- name: 2-5 words, human-readable title/name for this item.\n"
        "- category: choose exactly one allowed category.\n"
        "- subcategory: concrete item type inside the chosen category (e.g. hoodie, jeans, sneaker).\n"
        "- color_primary: dominant visible color as one value; if no single color dominates, use 'mixed'.\n"
        "- material: dominant visible material/fabric as one value.\n"
        "- style_occasion: one concise style/occasion descriptor.\n"
        "- pattern_design: one dominant pattern descriptor (use 'solid' when no pattern is visible).\n\n"
        "Existing workspace subcategories by category (prefer reuse in chosen category):\n"
        f"{_subcategory_lines()}\n\n"
        "Existing workspace values (prefer reuse):\n"
        f"{_line('color_primary')}\n"
        f"{_line('material')}\n"
        f"{_line('style_occasion')}\n"
        f"{_line('pattern_design')}\n\n"
        "Few-shot examples (illustrative only; DO NOT copy values blindly):\n"
        "Example A image: plain black hoodie.\n"
        '{"name":"Black Hoodie","category":"top","subcategory":"hoodie","color_primary":"black","material":"cotton","style_occasion":"casual","pattern_design":"solid"}\n'
        "Example B image: blue denim jeans.\n"
        '{"name":"Blue Jeans","category":"bottom","subcategory":"jeans","color_primary":"blue","material":"denim","style_occasion":"casual","pattern_design":"solid"}\n'
        "Use the examples only as output-format guidance; describe the current image, not the examples.\n\n"
        "Respond exclusively in the following JSON schema.\n"
        "No additional explanations.\n"
        "Output JSON schema:\n"
        f"{schema_text}\n"
    )


def _collect_existing_vocab(dataset: Dataset) -> dict[str, Any]:
    subcategory_by_category: dict[str, dict[str, str]] = {
        category: {} for category in CATEGORIES
    }
    buckets: dict[str, dict[str, str]] = {
        "color_primary": {},
        "material": {},
        "style_occasion": {},
        "pattern_design": {},
    }
    for category in CATEGORIES:
        items = dataset.items_by_category.get(category, [])
        for item in items:
            _add_vocab_value(subcategory_by_category[category], item.subcategory)
            _add_vocab_value(buckets["color_primary"], item.color_primary)
            _add_vocab_value(buckets["material"], item.material)
            _add_vocab_value(buckets["style_occasion"], item.style_occasion)
            _add_vocab_value(buckets["pattern_design"], item.pattern_design)

    result: dict[str, Any] = {
        "subcategory_by_category": {
            category: sorted(values.values(), key=lambda value: value.lower())
            for category, values in subcategory_by_category.items()
        }
    }
    result.update(
        {
            field: sorted(values.values(), key=lambda value: value.lower())
            for field, values in buckets.items()
        }
    )
    return result


def _update_vocab(vocab: dict[str, Any], normalized: dict[str, str]) -> None:
    raw_subcategory_map = vocab.get("subcategory_by_category")
    if not isinstance(raw_subcategory_map, dict):
        raw_subcategory_map = {}
        vocab["subcategory_by_category"] = raw_subcategory_map

    category = normalized["category"]
    raw_existing_subcategories = raw_subcategory_map.get(category, [])
    existing_subcategories = (
        {
            value.lower(): value
            for value in raw_existing_subcategories
            if isinstance(value, str)
        }
        if isinstance(raw_existing_subcategories, list)
        else {}
    )
    subcategory_value = normalized["subcategory"]
    existing_subcategories[subcategory_value.lower()] = subcategory_value
    raw_subcategory_map[category] = sorted(
        existing_subcategories.values(),
        key=lambda current: current.lower(),
    )

    for field in (
        "color_primary",
        "material",
        "style_occasion",
        "pattern_design",
    ):
        raw_values = vocab.get(field, [])
        existing = (
            {value.lower(): value for value in raw_values if isinstance(value, str)}
            if isinstance(raw_values, list)
            else {}
        )
        value = normalized[field]
        existing[value.lower()] = value
        vocab[field] = sorted(existing.values(), key=lambda current: current.lower())


def _add_vocab_value(bucket: dict[str, str], value: str | None) -> None:
    if value is None:
        return
    normalized = _normalize_field_value(value)
    if not normalized:
        return
    bucket[normalized.lower()] = normalized


_COMPOSITE_PATTERN = re.compile(r"[,/;|]")
_MULTIWORD_PATTERN = re.compile(r"\b(and|und|or|oder)\b")


def _normalize_and_validate_classification(raw: dict[str, Any]) -> dict[str, str]:
    category = _normalize_category(raw.get("category"))
    values = {
        "name": _normalize_display_value(raw.get("name"), "name"),
        "category": category,
        "subcategory": _normalize_single_value(raw.get("subcategory"), "subcategory"),
        "color_primary": _normalize_single_value(
            raw.get("color_primary"), "color_primary"
        ),
        "material": _normalize_single_value(raw.get("material"), "material"),
        "style_occasion": _normalize_single_value(
            raw.get("style_occasion"), "style_occasion"
        ),
        "pattern_design": _normalize_single_value(
            raw.get("pattern_design"), "pattern_design"
        ),
    }
    return values


def _normalize_category(raw_value: Any) -> str:
    value = _normalize_field_value(raw_value)
    if value not in {"top", "bottom", "headwear", "shoes"}:
        raise ValueError(f"invalid category: {raw_value!r}")
    return value


def _normalize_single_value(raw_value: Any, field_name: str) -> str:
    normalized = _normalize_field_value(raw_value)
    if not normalized:
        raise ValueError(f"missing value for {field_name}")
    if _COMPOSITE_PATTERN.search(normalized):
        raise ValueError(
            f"composite value not allowed for {field_name}: {normalized!r}"
        )
    if _MULTIWORD_PATTERN.search(normalized):
        raise ValueError(
            f"multi-value conjunction not allowed for {field_name}: {normalized!r}"
        )
    return normalized


def _normalize_display_value(raw_value: Any, field_name: str) -> str:
    text = str(raw_value or "").strip()
    normalized = " ".join(text.split())
    if not normalized:
        raise ValueError(f"missing value for {field_name}")
    return normalized


def _normalize_field_value(raw_value: Any) -> str:
    text = str(raw_value or "").strip().lower()
    return " ".join(text.split())


def _apply_classification_result(
    *,
    workspace_root: Path,
    dataset: Dataset,
    pending_item: PendingIntakeItem,
    normalized: dict[str, str],
    provider: str,
    model: str,
    prompt_version: str,
    existing_ids_by_category: dict[str, set[str]],
) -> None:
    category = normalized["category"]
    item_name = normalized["name"]
    existing_ids = existing_ids_by_category.setdefault(category, set())
    item_id = _make_unique_slug(item_name, existing_ids)
    existing_ids.add(item_id)

    item_dir = workspace_root / "items" / category / item_id
    item_dir.mkdir(parents=True, exist_ok=True)

    image_ext = pending_item.path.suffix.lower() or ".png"
    image_target = item_dir / f"image{image_ext}"
    thumb_ext = (
        pending_item.thumb_path.suffix.lower() if pending_item.thumb_path else ".jpg"
    )
    thumb_target = item_dir / f"thumb{thumb_ext}"
    meta_target = item_dir / "item.yaml"

    _move_or_copy_file(pending_item.path, image_target)
    if pending_item.thumb_path and pending_item.thumb_path.exists():
        _move_or_copy_file(pending_item.thumb_path, thumb_target)

    classification = ClassificationInfo(
        provider=provider,
        model=model,
        classified_at=_dt.datetime.now(_dt.timezone.utc).isoformat(),
        prompt_version=prompt_version,
    )
    item_payload = {
        "id": item_id,
        "name": item_name,
        "category": category,
        "subcategory": normalized["subcategory"],
        "color_primary": normalized["color_primary"],
        "material": normalized["material"],
        "style_occasion": normalized["style_occasion"],
        "pattern_design": normalized["pattern_design"],
        "tags": [],
        "path": _relative_path(image_target, workspace_root),
        "thumb_path": _relative_path(thumb_target, workspace_root)
        if thumb_target.exists()
        else None,
        "meta_path": _relative_path(meta_target, workspace_root),
        "render_ready": False,
        "classification": {
            "provider": classification.provider,
            "model": classification.model,
            "classified_at": classification.classified_at,
            "prompt_version": classification.prompt_version,
        },
    }
    meta_target.write_text(json.dumps(item_payload, indent=2), encoding="utf-8")

    item = Item(
        item_id=item_id,
        name=item_name,
        category=category,
        path=image_target,
        thumb_path=thumb_target if thumb_target.exists() else None,
        meta_path=meta_target,
        subcategory=normalized["subcategory"],
        color_primary=normalized["color_primary"],
        material=normalized["material"],
        style_occasion=normalized["style_occasion"],
        pattern_design=normalized["pattern_design"],
        tags=(),
        classification=classification,
        render_ready=False,
    )
    dataset.items_by_category.setdefault(category, []).append(item)
    dataset.intake_queue = [
        entry for entry in dataset.intake_queue if entry.item_id != pending_item.item_id
    ]

    if pending_item.meta_path and pending_item.meta_path.exists():
        try:
            pending_item.meta_path.unlink()
        except Exception:
            pass
    _cleanup_empty_parents(pending_item.path.parent, workspace_root)


def _move_or_copy_file(source: Path, target: Path) -> None:
    if source.resolve() == target.resolve():
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    try:
        shutil.move(str(source), str(target))
    except Exception:
        shutil.copy2(source, target)
        try:
            source.unlink()
        except Exception:
            pass


def _cleanup_empty_parents(path: Path, workspace_root: Path) -> None:
    current = path
    for _ in range(6):
        if current == workspace_root or not current.exists():
            return
        try:
            current.rmdir()
        except OSError:
            return
        current = current.parent


def _make_unique_slug(base: str, existing: set[str]) -> str:
    candidate = slugify(base)
    if candidate not in existing:
        return candidate
    counter = 2
    while True:
        trial = f"{candidate}-{counter}"
        if trial not in existing:
            return trial
        counter += 1


def _relative_path(path: Path, workspace_root: Path) -> str:
    try:
        return path.relative_to(workspace_root).as_posix()
    except Exception:
        return path.as_posix()


def _render_progress_label(output_path: Path, progress_root: Path) -> str:
    return _relative_path(output_path, progress_root)


def _count_planned_render_outputs(
    *,
    workspace_root: Path,
    poses: list[Any],
    tops: list[Item],
    bottoms: list[Item],
    dataset: Dataset,
    image_format: str,
    overlay_format: str,
    force: bool,
    max_images: int | None,
    targeted_render_keys: set[tuple[str, str, str]] | None = None,
    targeted_overlay_keys: set[tuple[str, str, str]] | None = None,
) -> int:
    planned = 0
    targeted_render_keys = targeted_render_keys or set()
    targeted_overlay_keys = targeted_overlay_keys or set()

    def _count(path: Path) -> bool:
        nonlocal planned
        if not force and path.exists():
            return False
        planned += 1
        return True

    for pose in poses:
        for bottom in bottoms:
            for top in tops:
                output_path = render_output_path(
                    workspace_root,
                    pose.pose_id,
                    top.item_id,
                    bottom.item_id,
                    image_format,
                )
                key = (pose.pose_id, top.item_id, bottom.item_id)
                if key in targeted_render_keys:
                    planned += 1
                else:
                    _count(output_path)
                if max_images is not None and planned >= max_images:
                    return planned

        for category in ("headwear", "shoes"):
            for item in dataset.items_by_category.get(category, []):
                key = (pose.pose_id, category, item.item_id)
                output_path = overlay_output_path(
                    workspace_root,
                    pose.pose_id,
                    category,
                    item.item_id,
                    overlay_format,
                )
                if key in targeted_overlay_keys:
                    planned += 1
                else:
                    _count(output_path)
                if max_images is not None and planned >= max_images:
                    return planned

    return planned


def _parse_request_timestamp(value: str | None) -> _dt.datetime | None:
    if value is None:
        return None
    text = value.strip()
    if not text:
        return None
    if text.endswith("Z"):
        text = f"{text[:-1]}+00:00"
    try:
        parsed = _dt.datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=_dt.timezone.utc)
    return parsed.astimezone(_dt.timezone.utc)


def _output_satisfies_regeneration_request(
    path: Path, requested_at: str | None
) -> bool:
    if not path.exists():
        return False
    requested_at_dt = _parse_request_timestamp(requested_at)
    if requested_at_dt is None:
        return False
    output_written_at = _dt.datetime.fromtimestamp(
        path.stat().st_mtime, tz=_dt.timezone.utc
    )
    return output_written_at >= requested_at_dt


def _collect_targeted_render_keys(
    *,
    dataset: Dataset,
    workspace_root: Path,
    poses: list[Pose],
    tops: list[Item],
    bottoms: list[Item],
    image_format: str,
) -> tuple[set[tuple[str, str, str]], set[tuple[str, str]]]:
    pose_ids = {pose.pose_id for pose in poses}
    top_ids = {item.item_id for item in tops}
    bottom_ids = {item.item_id for item in bottoms}
    targeted: set[tuple[str, str, str]] = set()
    forced_bottom_bases: set[tuple[str, str]] = set()

    for request in dataset.regenerate_items:
        if request.category == "top" and request.item_id in top_ids:
            for pose in poses:
                for bottom in bottoms:
                    output_path = render_output_path(
                        workspace_root,
                        pose.pose_id,
                        request.item_id,
                        bottom.item_id,
                        image_format,
                    )
                    if not _output_satisfies_regeneration_request(
                        output_path, request.requested_at
                    ):
                        targeted.add((pose.pose_id, request.item_id, bottom.item_id))
        elif request.category == "bottom" and request.item_id in bottom_ids:
            for pose in poses:
                bottom_base_path = (
                    workspace_root
                    / "_passes"
                    / pose.pose_id
                    / f"base_bottom__{request.item_id}.png"
                )
                for top in tops:
                    output_path = render_output_path(
                        workspace_root,
                        pose.pose_id,
                        top.item_id,
                        request.item_id,
                        image_format,
                    )
                    if _output_satisfies_regeneration_request(
                        output_path, request.requested_at
                    ):
                        continue
                    targeted.add((pose.pose_id, top.item_id, request.item_id))
                    if not _output_satisfies_regeneration_request(
                        bottom_base_path,
                        request.requested_at,
                    ):
                        forced_bottom_bases.add((pose.pose_id, request.item_id))

    for request in dataset.regenerate_targets:
        if request.type == "pose_item":
            if (
                request.pose_id not in pose_ids
                or request.category is None
                or request.item_id is None
            ):
                continue
            if request.category == "top" and request.item_id in top_ids:
                for bottom in bottoms:
                    output_path = render_output_path(
                        workspace_root,
                        request.pose_id,
                        request.item_id,
                        bottom.item_id,
                        image_format,
                    )
                    if not _output_satisfies_regeneration_request(
                        output_path, request.requested_at
                    ):
                        targeted.add((request.pose_id, request.item_id, bottom.item_id))
            elif request.category == "bottom" and request.item_id in bottom_ids:
                bottom_base_path = (
                    workspace_root
                    / "_passes"
                    / request.pose_id
                    / f"base_bottom__{request.item_id}.png"
                )
                for top in tops:
                    output_path = render_output_path(
                        workspace_root,
                        request.pose_id,
                        top.item_id,
                        request.item_id,
                        image_format,
                    )
                    if _output_satisfies_regeneration_request(
                        output_path, request.requested_at
                    ):
                        continue
                    targeted.add((request.pose_id, top.item_id, request.item_id))
                    if not _output_satisfies_regeneration_request(
                        bottom_base_path,
                        request.requested_at,
                    ):
                        forced_bottom_bases.add((request.pose_id, request.item_id))
        elif (
            request.type == "render"
            and request.pose_id in pose_ids
            and request.top_id in top_ids
            and request.bottom_id in bottom_ids
        ):
            output_path = render_output_path(
                workspace_root,
                request.pose_id,
                request.top_id,
                request.bottom_id,
                image_format,
            )
            if _output_satisfies_regeneration_request(
                output_path, request.requested_at
            ):
                continue
            targeted.add((request.pose_id, request.top_id, request.bottom_id))
            bottom_base_path = (
                workspace_root
                / "_passes"
                / request.pose_id
                / f"base_bottom__{request.bottom_id}.png"
            )
            if not _output_satisfies_regeneration_request(
                bottom_base_path, request.requested_at
            ):
                forced_bottom_bases.add((request.pose_id, request.bottom_id))

    return targeted, forced_bottom_bases


def _collect_targeted_overlay_keys(
    *,
    dataset: Dataset,
    workspace_root: Path,
    poses: list[Pose],
    overlay_format: str,
) -> set[tuple[str, str, str]]:
    pose_ids = {pose.pose_id for pose in poses}
    headwear_ids = {
        item.item_id for item in dataset.items_by_category.get("headwear", [])
    }
    shoes_ids = {item.item_id for item in dataset.items_by_category.get("shoes", [])}
    targeted: set[tuple[str, str, str]] = set()

    for request in dataset.regenerate_items:
        if request.category == "headwear" and request.item_id in headwear_ids:
            for pose in poses:
                output_path = overlay_output_path(
                    workspace_root,
                    pose.pose_id,
                    "headwear",
                    request.item_id,
                    overlay_format,
                )
                if not _output_satisfies_regeneration_request(
                    output_path, request.requested_at
                ):
                    targeted.add((pose.pose_id, "headwear", request.item_id))
        elif request.category == "shoes" and request.item_id in shoes_ids:
            for pose in poses:
                output_path = overlay_output_path(
                    workspace_root,
                    pose.pose_id,
                    "shoes",
                    request.item_id,
                    overlay_format,
                )
                if not _output_satisfies_regeneration_request(
                    output_path, request.requested_at
                ):
                    targeted.add((pose.pose_id, "shoes", request.item_id))

    for request in dataset.regenerate_targets:
        if request.pose_id not in pose_ids:
            continue
        if request.type == "pose_item":
            if request.category == "headwear" and request.item_id in headwear_ids:
                output_path = overlay_output_path(
                    workspace_root,
                    request.pose_id,
                    "headwear",
                    request.item_id,
                    overlay_format,
                )
                if not _output_satisfies_regeneration_request(
                    output_path, request.requested_at
                ):
                    targeted.add((request.pose_id, "headwear", request.item_id))
            elif request.category == "shoes" and request.item_id in shoes_ids:
                output_path = overlay_output_path(
                    workspace_root,
                    request.pose_id,
                    "shoes",
                    request.item_id,
                    overlay_format,
                )
                if not _output_satisfies_regeneration_request(
                    output_path, request.requested_at
                ):
                    targeted.add((request.pose_id, "shoes", request.item_id))
        elif request.type == "overlay":
            if request.category == "headwear" and request.item_id in headwear_ids:
                output_path = overlay_output_path(
                    workspace_root,
                    request.pose_id,
                    "headwear",
                    request.item_id,
                    overlay_format,
                )
                if not _output_satisfies_regeneration_request(
                    output_path, request.requested_at
                ):
                    targeted.add((request.pose_id, "headwear", request.item_id))
            elif request.category == "shoes" and request.item_id in shoes_ids:
                output_path = overlay_output_path(
                    workspace_root,
                    request.pose_id,
                    "shoes",
                    request.item_id,
                    overlay_format,
                )
                if not _output_satisfies_regeneration_request(
                    output_path, request.requested_at
                ):
                    targeted.add((request.pose_id, "shoes", request.item_id))

    return targeted


def _write_regeneration_manifest_state(workspace_root: Path, dataset: Dataset) -> None:
    manifest_path = workspace_root / "wardrobe.json"
    payload: dict[str, Any] = {}
    if manifest_path.exists():
        try:
            raw = json.loads(manifest_path.read_text(encoding="utf-8"))
            if isinstance(raw, dict):
                payload = raw
        except Exception:
            payload = {}

    payload["regeneration"] = {
        "items": [
            {
                "category": request.category,
                "item_id": request.item_id,
                "requested_at": request.requested_at,
            }
            for request in dataset.regenerate_items
        ],
        "targets": [
            {
                "type": request.type,
                **({"pose_id": request.pose_id} if request.pose_id is not None else {}),
                **(
                    {"category": request.category}
                    if request.category is not None
                    else {}
                ),
                **({"item_id": request.item_id} if request.item_id is not None else {}),
                **({"top_id": request.top_id} if request.top_id is not None else {}),
                **(
                    {"bottom_id": request.bottom_id}
                    if request.bottom_id is not None
                    else {}
                ),
                "requested_at": request.requested_at,
            }
            for request in dataset.regenerate_targets
        ],
    }
    payload["schema_version"] = 5
    manifest_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")


def _prune_completed_regeneration_requests(
    *,
    dataset: Dataset,
    workspace_root: Path,
    image_format: str,
    overlay_format: str,
    successful_render_keys: set[tuple[str, str, str]],
    successful_overlay_keys: set[tuple[str, str, str]],
) -> None:
    all_pose_ids = {pose.pose_id for pose in dataset.poses}
    all_top_ids = {item.item_id for item in dataset.items_by_category.get("top", [])}
    all_bottom_ids = {
        item.item_id for item in dataset.items_by_category.get("bottom", [])
    }
    all_headwear_ids = {
        item.item_id for item in dataset.items_by_category.get("headwear", [])
    }
    all_shoes_ids = {
        item.item_id for item in dataset.items_by_category.get("shoes", [])
    }

    remaining_item_requests = []
    for request in dataset.regenerate_items:
        target_render_keys: set[tuple[str, str, str]] = set()
        target_overlay_keys: set[tuple[str, str, str]] = set()

        if request.category == "top" and request.item_id in all_top_ids:
            for pose in dataset.poses:
                for bottom in dataset.items_by_category.get("bottom", []):
                    target_render_keys.add(
                        (pose.pose_id, request.item_id, bottom.item_id)
                    )
        elif request.category == "bottom" and request.item_id in all_bottom_ids:
            for pose in dataset.poses:
                for top in dataset.items_by_category.get("top", []):
                    target_render_keys.add((pose.pose_id, top.item_id, request.item_id))
        elif request.category == "headwear" and request.item_id in all_headwear_ids:
            for pose in dataset.poses:
                target_overlay_keys.add((pose.pose_id, "headwear", request.item_id))
        elif request.category == "shoes" and request.item_id in all_shoes_ids:
            for pose in dataset.poses:
                target_overlay_keys.add((pose.pose_id, "shoes", request.item_id))

        completed = False
        if target_render_keys:
            completed = all(
                _output_satisfies_regeneration_request(
                    render_output_path(
                        workspace_root,
                        pose_id,
                        top_id,
                        bottom_id,
                        image_format,
                    ),
                    request.requested_at,
                )
                or (pose_id, top_id, bottom_id) in successful_render_keys
                for pose_id, top_id, bottom_id in target_render_keys
            )
        elif target_overlay_keys:
            completed = all(
                _output_satisfies_regeneration_request(
                    overlay_output_path(
                        workspace_root,
                        pose_id,
                        category,
                        item_id,
                        overlay_format,
                    ),
                    request.requested_at,
                )
                or (pose_id, category, item_id) in successful_overlay_keys
                for pose_id, category, item_id in target_overlay_keys
            )

        if not completed:
            remaining_item_requests.append(request)

    remaining_target_requests = []
    for request in dataset.regenerate_targets:
        if request.type == "pose_item":
            if (
                request.pose_id not in all_pose_ids
                or request.category is None
                or request.item_id is None
            ):
                remaining_target_requests.append(request)
                continue
            target_render_keys: set[tuple[str, str, str]] = set()
            target_overlay_keys: set[tuple[str, str, str]] = set()
            if request.category == "top" and request.item_id in all_top_ids:
                for bottom in dataset.items_by_category.get("bottom", []):
                    target_render_keys.add(
                        (request.pose_id, request.item_id, bottom.item_id)
                    )
            elif request.category == "bottom" and request.item_id in all_bottom_ids:
                for top in dataset.items_by_category.get("top", []):
                    target_render_keys.add(
                        (request.pose_id, top.item_id, request.item_id)
                    )
            elif request.category == "headwear" and request.item_id in all_headwear_ids:
                target_overlay_keys.add((request.pose_id, "headwear", request.item_id))
            elif request.category == "shoes" and request.item_id in all_shoes_ids:
                target_overlay_keys.add((request.pose_id, "shoes", request.item_id))

            completed = False
            if target_render_keys:
                completed = all(
                    _output_satisfies_regeneration_request(
                        render_output_path(
                            workspace_root,
                            pose_id,
                            top_id,
                            bottom_id,
                            image_format,
                        ),
                        request.requested_at,
                    )
                    or (pose_id, top_id, bottom_id) in successful_render_keys
                    for pose_id, top_id, bottom_id in target_render_keys
                )
            elif target_overlay_keys:
                completed = all(
                    _output_satisfies_regeneration_request(
                        overlay_output_path(
                            workspace_root,
                            pose_id,
                            category,
                            item_id,
                            overlay_format,
                        ),
                        request.requested_at,
                    )
                    or (pose_id, category, item_id) in successful_overlay_keys
                    for pose_id, category, item_id in target_overlay_keys
                )
            if not completed:
                remaining_target_requests.append(request)
            continue

        if request.type == "render":
            if (
                request.pose_id not in all_pose_ids
                or request.top_id not in all_top_ids
                or request.bottom_id not in all_bottom_ids
            ):
                remaining_target_requests.append(request)
                continue
            completed = (
                _output_satisfies_regeneration_request(
                    render_output_path(
                        workspace_root,
                        request.pose_id,
                        request.top_id,
                        request.bottom_id,
                        image_format,
                    ),
                    request.requested_at,
                )
                or (
                    request.pose_id,
                    request.top_id,
                    request.bottom_id,
                )
                in successful_render_keys
            )
            if not completed:
                remaining_target_requests.append(request)
            continue

        if request.type == "overlay":
            if (
                request.pose_id not in all_pose_ids
                or request.category not in {"headwear", "shoes"}
                or request.item_id is None
            ):
                remaining_target_requests.append(request)
                continue
            valid_ids = (
                all_headwear_ids if request.category == "headwear" else all_shoes_ids
            )
            if request.item_id not in valid_ids:
                remaining_target_requests.append(request)
                continue
            completed = (
                _output_satisfies_regeneration_request(
                    overlay_output_path(
                        workspace_root,
                        request.pose_id,
                        request.category,
                        request.item_id,
                        overlay_format,
                    ),
                    request.requested_at,
                )
                or (
                    request.pose_id,
                    request.category,
                    request.item_id,
                )
                in successful_overlay_keys
            )
            if not completed:
                remaining_target_requests.append(request)
            continue

        remaining_target_requests.append(request)

    dataset.regenerate_items = remaining_item_requests
    dataset.regenerate_targets = remaining_target_requests
    _write_regeneration_manifest_state(workspace_root, dataset)


def _render_all(
    args: argparse.Namespace,
    config: dict,
    dataset: Dataset,
    workspace_root: Path,
    renderer,
    repo_root: Path | None = None,
) -> None:
    progress_root = repo_root or workspace_root
    images_cfg = config["images"]
    configured_output_size = tuple(images_cfg["output_size"])
    image_format = images_cfg["image_format"]
    overlay_format = images_cfg["overlay_format"]
    input_megapixels = args.input_megapixels
    if input_megapixels is None:
        input_megapixels = images_cfg.get("input_megapixels")
    if input_megapixels is None:
        raise ValueError(
            "Missing required input megapixels. Set images.input_megapixels in config "
            "or pass --input-megapixels."
        )

    quality = config["quality"]
    steps = int(args.steps) if args.steps is not None else int(quality["steps"])
    cfg_scale = float(args.cfg) if args.cfg is not None else float(quality["cfg"])
    sampler = str(args.sampler) if args.sampler is not None else str(quality["sampler"])
    scheduler = str(quality["scheduler"])

    render_cfg = config.get("render") or {}
    prompts = render_cfg["prompts"]
    negative_prompt = str(
        prompts.get("negative_prompt", render_cfg.get("negative_prompt", ""))
    )
    configured_seed = getattr(args, "seed", None)
    if configured_seed is None:
        configured_seed = render_cfg.get("seed")
    seed = None if configured_seed in (None, "") else int(configured_seed)

    poses = dataset.poses
    if args.pose:
        poses = [pose for pose in poses if pose.pose_id == args.pose]
    output_size = resolve_output_size(images_cfg=images_cfg, poses=poses)
    if output_size != configured_output_size:
        print(
            "[render] dynamic output size enabled: "
            f"configured={configured_output_size[0]}x{configured_output_size[1]} "
            f"resolved={output_size[0]}x{output_size[1]}"
        )

    tops = dataset.items_by_category.get("top", [])
    if args.top:
        wanted = slugify(str(args.top))
        tops = [item for item in tops if item.item_id == wanted]
        if not tops:
            raise SystemExit(f"Unknown top item id: {args.top}")

    bottoms = dataset.items_by_category.get("bottom", [])
    if args.bottom:
        wanted = slugify(str(args.bottom))
        bottoms = [item for item in bottoms if item.item_id == wanted]
        if not bottoms:
            raise SystemExit(f"Unknown bottom item id: {args.bottom}")

    targeted_render_keys, forced_bottom_bases = _collect_targeted_render_keys(
        dataset=dataset,
        workspace_root=workspace_root,
        poses=poses,
        tops=tops,
        bottoms=bottoms,
        image_format=image_format,
    )
    targeted_overlay_keys = _collect_targeted_overlay_keys(
        dataset=dataset,
        workspace_root=workspace_root,
        poses=poses,
        overlay_format=overlay_format,
    )
    successful_render_keys: set[tuple[str, str, str]] = set()
    successful_overlay_keys: set[tuple[str, str, str]] = set()
    max_images = args.max_images
    planned_total = _count_planned_render_outputs(
        workspace_root=workspace_root,
        poses=poses,
        tops=tops,
        bottoms=bottoms,
        dataset=dataset,
        image_format=image_format,
        overlay_format=overlay_format,
        force=args.force,
        max_images=max_images,
        targeted_render_keys=targeted_render_keys,
        targeted_overlay_keys=targeted_overlay_keys,
    )
    if planned_total <= 0:
        print("[render] nothing to do (all requested outputs already exist).")
        return

    progress_tracker = ProgressTracker(name="render", total_units=planned_total)
    print(progress_tracker.format_start_line())

    def _emit_render_progress(
        duration_sec: float, label: str, success: bool = True
    ) -> None:
        progress_tracker.record_step(
            duration_sec=duration_sec, label=label, success=success
        )
        print(progress_tracker.format_line(label=label, success=success))

    def _finalize_render_progress() -> None:
        print(progress_tracker.format_finish_line())

    tmp_dir = workspace_root / "_inputs"
    tmp_dir.mkdir(parents=True, exist_ok=True)

    rendered_count = 0

    try:
        base_phase_announced = False
        for pose in poses:
            pose_input = _prepare_input(pose.path, tmp_dir)
            pose_base_input = pose_input

            passes_dir = workspace_root / "_passes" / pose.pose_id
            passes_dir.mkdir(parents=True, exist_ok=True)

            for bottom in bottoms:
                bottom_base_path = passes_dir / f"base_bottom__{bottom.item_id}.png"
                bottom_seed = _resolve_render_seed(
                    seed,
                    f"bottom|{pose.pose_id}|{bottom.item_id}",
                )
                bottom_needs_render = (
                    args.force
                    or (pose.pose_id, bottom.item_id) in forced_bottom_bases
                    or not bottom_base_path.exists()
                )

                for top in tops:
                    if max_images is not None and rendered_count >= max_images:
                        _finalize_render_progress()
                        return
                    render_key = (pose.pose_id, top.item_id, bottom.item_id)
                    targeted_render = render_key in targeted_render_keys
                    output_path = render_output_path(
                        workspace_root,
                        pose.pose_id,
                        top.item_id,
                        bottom.item_id,
                        image_format,
                    )
                    if output_path.exists():
                        if not args.force and not targeted_render:
                            continue

                    if not base_phase_announced:
                        print("[render] phase=base_renders mode=flux")
                        base_phase_announced = True
                    step_started = time.perf_counter()
                    if bottom_needs_render:
                        bottom_prompt = str(
                            prompts.get("base_bottom", prompts["base"])
                        )
                        bottom_negative_prompt = negative_prompt
                        request_bottom = RenderRequest(
                            render_type="bottom_base",
                            pose_path=pose_base_input,
                            image2_path=bottom.path,
                            image3_path=bottom.path,
                            output_path=bottom_base_path,
                            prompt=bottom_prompt,
                            negative_prompt=bottom_negative_prompt,
                            seed=bottom_seed,
                            steps=steps,
                            cfg=cfg_scale,
                            sampler=sampler,
                            scheduler=scheduler,
                            size=output_size,
                            input_megapixels=input_megapixels,
                        )
                        renderer.render(request_bottom)
                        bottom_needs_render = False

                    output_path.parent.mkdir(parents=True, exist_ok=True)
                    top_seed = _resolve_render_seed(
                        seed,
                        f"top|{pose.pose_id}|{top.item_id}|{bottom.item_id}",
                    )
                    top_prompt = str(prompts.get("base_top", prompts["base"]))
                    top_negative_prompt = negative_prompt
                    request_top = RenderRequest(
                        render_type="top_final",
                        pose_path=bottom_base_path,
                        image2_path=top.path,
                        image3_path=top.path,
                        output_path=output_path,
                        prompt=top_prompt,
                        negative_prompt=top_negative_prompt,
                        seed=top_seed,
                        steps=steps,
                        cfg=cfg_scale,
                        sampler=sampler,
                        scheduler=scheduler,
                        size=output_size,
                        input_megapixels=input_megapixels,
                    )
                    renderer.render(request_top)
                    successful_render_keys.add(render_key)
                    _write_render_sidecar(
                        render_meta_output_path(
                            workspace_root,
                            pose.pose_id,
                            top.item_id,
                            bottom.item_id,
                        ),
                        pose.pose_id,
                        top.item_id,
                        bottom.item_id,
                    )
                    rendered_count += 1
                    _emit_render_progress(
                        duration_sec=time.perf_counter() - step_started,
                        label=_render_progress_label(output_path, progress_root),
                        success=True,
                    )

        if max_images is None or rendered_count < max_images:
            pending_overlay_jobs: list[_PendingOverlayJob] = []
            scheduled_overlay_count = 0
            overlay_render_phase_announced = False

            def _announce_overlay_render_phase() -> None:
                nonlocal overlay_render_phase_announced
                if overlay_render_phase_announced:
                    return
                print("[render] phase=overlay_renders mode=flux")
                overlay_render_phase_announced = True

            for pose in poses:
                remaining_overlay_slots = None
                if max_images is not None:
                    remaining_overlay_slots = (
                        max_images - rendered_count - scheduled_overlay_count
                    )
                    if remaining_overlay_slots <= 0:
                        break
                pose_jobs = _render_overlay_images_for_pose(
                    config=config,
                    pose=pose,
                    dataset=dataset,
                    workspace_root=workspace_root,
                    renderer=renderer,
                    tmp_dir=tmp_dir,
                    overlay_format=overlay_format,
                    negative_prompt=negative_prompt,
                    prompts=prompts,
                    seed=seed,
                    quality=quality,
                    output_size=output_size,
                    input_megapixels=input_megapixels,
                    force=args.force,
                    remaining_slots=remaining_overlay_slots,
                    targeted_overlay_keys=targeted_overlay_keys,
                    on_overlay_render_started=_announce_overlay_render_phase,
                )
                pending_overlay_jobs.extend(pose_jobs)
                scheduled_overlay_count += len(pose_jobs)

            if pending_overlay_jobs:
                print("[render] phase=overlay_cutouts mode=dinoground+sam")
            rendered_count = _finalize_overlay_jobs(
                config=config,
                workspace_root=workspace_root,
                progress_root=progress_root,
                jobs=pending_overlay_jobs,
                force=args.force,
                include_overlay_previews=args.include_overlay_previews,
                successful_overlay_keys=successful_overlay_keys,
                on_overlay_done=lambda label, duration_sec: _emit_render_progress(
                    duration_sec=duration_sec,
                    label=label,
                    success=True,
                ),
                rendered_count=rendered_count,
            )

        _finalize_render_progress()
    finally:
        _prune_completed_regeneration_requests(
            dataset=dataset,
            workspace_root=workspace_root,
            image_format=image_format,
            overlay_format=overlay_format,
            successful_render_keys=successful_render_keys,
            successful_overlay_keys=successful_overlay_keys,
        )


def _overlay_base_inputs(
    config: dict,
    pose: Pose,
    workspace_root: Path,
    tmp_dir: Path,
) -> tuple[Path, list[Path]]:
    pose_input = _prepare_input(pose.path, tmp_dir)
    renders_dir = workspace_root / "renders" / pose.pose_id
    base_renders: list[Path] = []
    if renders_dir.exists():
        preferred_ext = str(config["images"]["image_format"]).lower().lstrip(".")
        preferred = sorted(
            [p for p in renders_dir.rglob(f"*.{preferred_ext}") if p.is_file()]
        )
        base_renders = preferred or sorted(
            [
                p
                for p in renders_dir.rglob("*.*")
                if p.is_file() and p.suffix.lower() != ".yaml"
            ]
        )

    return (base_renders[0] if base_renders else pose_input), base_renders


def _overlay_reference_roi(image: Image.Image, category: str) -> Image.Image:
    width, height = image.size
    if category == "headwear":
        box = (0, 0, width, max(1, int(round(height * 0.24))))
    else:
        box = (0, max(0, int(round(height * 0.78))), width, height)
    return image.crop(box)


def _overlay_reference_distance(a: Image.Image, b: Image.Image) -> float:
    a_data = a.tobytes()
    b_data = b.tobytes()
    if not a_data or len(a_data) != len(b_data):
        return float("inf")
    total = 0
    for a_px, b_px in zip(a_data, b_data):
        total += abs(a_px - b_px)
    return float(total) / float(len(a_data))


def _sample_evenly_spaced_paths(paths: list[Path], limit: int) -> list[Path]:
    if len(paths) <= limit:
        return paths

    step_count = limit - 1
    max_index = len(paths) - 1
    sampled_indexes: list[int] = []
    seen: set[int] = set()
    for offset in range(limit):
        index = round(offset * max_index / step_count)
        if index in seen:
            continue
        seen.add(index)
        sampled_indexes.append(index)
    return [paths[index] for index in sampled_indexes]


def _sample_overlay_reference_candidates(base_renders: list[Path]) -> list[Path]:
    return _sample_evenly_spaced_paths(
        base_renders,
        OVERLAY_REPRESENTATIVE_SAMPLE_LIMIT,
    )


def _sample_overlay_preview_candidates(base_renders: list[Path]) -> list[Path]:
    return _sample_evenly_spaced_paths(
        base_renders,
        OVERLAY_PREVIEW_SAMPLE_LIMIT,
    )


def _select_representative_overlay_render(
    base_renders: list[Path], category: str
) -> Path | None:
    if not base_renders:
        return None
    if len(base_renders) == 1:
        return base_renders[0]

    candidate_paths = _sample_overlay_reference_candidates(base_renders)
    prepared: list[tuple[Path, Image.Image]] = []
    target_size = (128, 64 if category == "headwear" else 96)
    for path in candidate_paths:
        try:
            with Image.open(path) as image:
                roi = _overlay_reference_roi(image.convert("L"), category)
                prepared.append(
                    (
                        path,
                        roi.resize(target_size, Image.Resampling.BILINEAR),
                    )
                )
        except Exception:
            continue
    if not prepared:
        return candidate_paths[0]
    if len(prepared) == 1:
        return prepared[0][0]

    best_path = prepared[0][0]
    best_score = float("inf")
    for index, (path, image) in enumerate(prepared):
        total = 0.0
        comparisons = 0
        for other_index, (_, other_image) in enumerate(prepared):
            if index == other_index:
                continue
            total += _overlay_reference_distance(image, other_image)
            comparisons += 1
        score = total / float(comparisons) if comparisons else float("inf")
        if score < best_score or (score == best_score and path.name < best_path.name):
            best_path = path
            best_score = score
    return best_path


def _select_overlay_reference_image(
    *,
    pose_input: Path,
    base_renders: list[Path],
    category: str,
) -> Path:
    if not base_renders:
        return pose_input
    if category == "shoes":
        representative = _select_representative_overlay_render(base_renders, category)
        if representative is not None:
            return representative
    return base_renders[0]



def _build_accessory_prompt(base_prompt: str, item: Item) -> str:
    descriptor_parts = [
        item.color_primary,
        item.material,
        item.subcategory,
        item.name,
    ]
    descriptor = " ".join(
        str(part).strip() for part in descriptor_parts if str(part or "").strip()
    )
    prompt = str(base_prompt).strip()
    exactness = f"Image2 shows the exact {descriptor}. " if descriptor else ""

    if item.category == "headwear":
        shape_lock = (
            "Preserve its exact accessory type, silhouette, material, and color; "
            "do not substitute a different hat style. Place it centered on the "
            "existing head without moving or reshaping the head or body."
        )
        subtype = str(item.subcategory or "").strip().lower()
        if subtype == "beanie":
            shape_lock += " It is a brimless knit beanie, not a cap and not a visor."
        elif subtype == "bucket hat":
            shape_lock += " It is a soft bucket hat, not a baseball cap."
        return " ".join(part for part in (prompt, exactness, shape_lock) if part)

    shape_lock = (
        "Preserve the exact shoe type, silhouette, material, and color from "
        "image2. Put the shoes directly over the existing feet at their original "
        "location and fully cover the feet without moving or shortening the legs."
    )
    return " ".join(part for part in (prompt, exactness, shape_lock) if part)


def _render_overlay_images_for_pose(
    *,
    config: dict,
    pose: Pose,
    dataset: Dataset,
    workspace_root: Path,
    renderer,
    tmp_dir: Path,
    overlay_format: str,
    negative_prompt: str,
    prompts: dict,
    seed: int | None,
    quality: dict,
    output_size: Tuple[int, int],
    input_megapixels: float,
    force: bool,
    remaining_slots: int | None,
    targeted_overlay_keys: set[tuple[str, str, str]] | None = None,
    on_overlay_render_started: Callable[[], None] | None = None,
) -> list[_PendingOverlayJob]:
    targeted_overlay_keys = targeted_overlay_keys or set()

    pose_input, base_renders = _overlay_base_inputs(
        config=config,
        pose=pose,
        workspace_root=workspace_root,
        tmp_dir=tmp_dir,
    )

    passes_dir = workspace_root / "_passes" / pose.pose_id
    passes_dir.mkdir(parents=True, exist_ok=True)
    jobs: list[_PendingOverlayJob] = []

    for category, render_type in [
        ("headwear", "overlay_headwear"),
        ("shoes", "overlay_shoes"),
    ]:
        if remaining_slots is not None and len(jobs) >= remaining_slots:
            return jobs
        for item in dataset.items_by_category.get(category, []):
            if remaining_slots is not None and len(jobs) >= remaining_slots:
                return jobs
            overlay_key = (pose.pose_id, category, item.item_id)
            targeted_overlay = overlay_key in targeted_overlay_keys
            output_path = overlay_output_path(
                workspace_root,
                pose.pose_id,
                category,
                item.item_id,
                overlay_format,
            )
            if output_path.exists():
                if not force and not targeted_overlay:
                    continue
            overlay_render_path = (
                passes_dir / f"overlay_full__{category}__{item.item_id}.png"
            )
            base_for_overlay_generation = _select_overlay_reference_image(
                pose_input=pose_input,
                base_renders=base_renders,
                category=category,
            )
            request_overlay = RenderRequest(
                render_type=render_type,
                pose_path=base_for_overlay_generation,
                image2_path=item.path,
                # FLUX.2 [klein] uses the full-body render as image1 and the
                # accessory crop as image2. This third path is retained in the
                # request type for renderer compatibility and is ignored by
                # the bundled two-reference workflow.
                image3_path=base_for_overlay_generation,
                output_path=overlay_render_path,
                prompt=_build_accessory_prompt(
                    str(prompts.get(render_type, "")), item
                ),
                negative_prompt=negative_prompt,
                seed=_resolve_render_seed(
                    seed,
                    f"overlay|{pose.pose_id}|{category}|{item.item_id}",
                ),
                steps=int(quality["steps"]),
                cfg=float(quality["cfg"]),
                sampler=str(quality["sampler"]),
                scheduler=str(quality["scheduler"]),
                size=output_size,
                input_megapixels=input_megapixels,
            )
            if on_overlay_render_started is not None:
                on_overlay_render_started()
            step_started = time.perf_counter()
            renderer.render(request_overlay)
            jobs.append(
                _PendingOverlayJob(
                    pose=pose,
                    category=category,
                    item=item,
                    base_for_overlay_generation=base_for_overlay_generation,
                    base_renders=base_renders,
                    overlay_render_path=overlay_render_path,
                    output_path=output_path,
                    started_at=step_started,
                )
            )
    return jobs



def _finalize_overlay_jobs(
    *,
    config: dict,
    workspace_root: Path,
    progress_root: Path,
    jobs: list[_PendingOverlayJob],
    force: bool,
    include_overlay_previews: bool,
    successful_overlay_keys: set[tuple[str, str, str]] | None,
    on_overlay_done: Callable[[str, float], None] | None,
    rendered_count: int,
) -> int:
    render_cfg = config.get("render") or {}
    overlay_crop_cfg = render_cfg.get("overlay_crop", {})

    for job in jobs:
        output_path = job.output_path
        output_path.parent.mkdir(parents=True, exist_ok=True)
        build_overlay_band_from_rendered(
            rendered_path=job.overlay_render_path,
            crop=(0.0, 0.0, 1.0, 1.0),
            output_path=output_path,
            category=job.category,
            base_path=job.base_for_overlay_generation,
            dynamic_crop=overlay_crop_cfg,
            pose_neck_y=job.pose.neck_y,
            pose_ankle_y=job.pose.ankle_y,
        )
        _write_overlay_sidecar(
            overlay_meta_output_path(
                workspace_root,
                job.pose.pose_id,
                job.category,
                job.item.item_id,
            ),
            job.pose.pose_id,
            job.category,
            job.item.item_id,
        )

        if include_overlay_previews and job.base_renders:
            overlay_preview_dir = workspace_root / "overlay_previews" / job.pose.pose_id
            overlay_preview_category_dir = overlay_preview_dir / job.category
            overlay_preview_category_dir.mkdir(parents=True, exist_ok=True)
            overlay_img = Image.open(output_path).convert("RGBA")
            for base_path in _sample_overlay_preview_candidates(job.base_renders):
                try:
                    base_img = Image.open(base_path).convert("RGBA")
                except Exception:
                    continue
                if base_img.size != overlay_img.size:
                    base_img = base_img.resize(overlay_img.size, Image.LANCZOS)
                composed = Image.alpha_composite(base_img, overlay_img)
                preview_name = f"{base_path.stem}__{job.item.item_id}.png"
                preview_path = overlay_preview_category_dir / preview_name
                composed.save(preview_path)

        rendered_count += 1
        overlay_key = (job.pose.pose_id, job.category, job.item.item_id)
        if successful_overlay_keys is not None:
            successful_overlay_keys.add(overlay_key)
        if on_overlay_done is not None:
            on_overlay_done(
                _render_progress_label(output_path, progress_root),
                time.perf_counter() - job.started_at,
            )
    return rendered_count


def _render_overlays(
    config: dict,
    pose,
    dataset: Dataset,
    workspace_root: Path,
    progress_root: Path | None,
    renderer,
    tmp_dir: Path,
    overlay_format: str,
    negative_prompt: str,
    prompts: dict,
    seed: int | None,
    quality: dict,
    output_size: Tuple[int, int],
    input_megapixels: float,
    force: bool,
    max_images: int | None,
    rendered_count: int,
    include_overlay_previews: bool,
    targeted_overlay_keys: set[tuple[str, str, str]] | None = None,
    successful_overlay_keys: set[tuple[str, str, str]] | None = None,
    on_overlay_done: Callable[[str, float], None] | None = None,
) -> int:
    progress_root = progress_root or workspace_root
    remaining_slots = None if max_images is None else max_images - rendered_count
    if remaining_slots is not None and remaining_slots <= 0:
        return rendered_count
    jobs = _render_overlay_images_for_pose(
        config=config,
        pose=pose,
        dataset=dataset,
        workspace_root=workspace_root,
        renderer=renderer,
        tmp_dir=tmp_dir,
        overlay_format=overlay_format,
        negative_prompt=negative_prompt,
        prompts=prompts,
        seed=seed,
        quality=quality,
        output_size=output_size,
        input_megapixels=input_megapixels,
        force=force,
        remaining_slots=remaining_slots,
        targeted_overlay_keys=targeted_overlay_keys,
    )
    return _finalize_overlay_jobs(
        config=config,
        workspace_root=workspace_root,
        progress_root=progress_root,
        jobs=jobs,
        force=force,
        include_overlay_previews=include_overlay_previews,
        successful_overlay_keys=successful_overlay_keys,
        on_overlay_done=on_overlay_done,
        rendered_count=rendered_count,
    )


def _prepare_input(
    path: Path,
    tmp_dir: Path,
    crop: Tuple[float, float, float, float] | None = None,
) -> Path:
    if crop is None:
        return path

    image = Image.open(path)
    if crop is not None:
        x, y, w, h = crop
        px0 = max(0, min(image.width - 1, int(round(x * image.width))))
        py0 = max(0, min(image.height - 1, int(round(y * image.height))))
        px1 = max(px0 + 1, min(image.width, int(round((x + w) * image.width))))
        py1 = max(py0 + 1, min(image.height, int(round((y + h) * image.height))))
        image = image.crop((px0, py0, px1, py1))

    stem = slugify(path.stem)
    digest = hashlib.md5(
        f"{path}|{crop}".encode("utf-8"),
        usedforsecurity=False,
    ).hexdigest()[:8]
    suffix = path.suffix.lower() or ".png"
    output_path = tmp_dir / f"{stem}-{digest}{suffix}"
    output_path.parent.mkdir(parents=True, exist_ok=True)
    fmt = {
        ".jpg": "JPEG",
        ".jpeg": "JPEG",
        ".png": "PNG",
        ".webp": "WEBP",
    }.get(suffix, suffix.lstrip(".").upper())

    to_save = image
    if fmt == "JPEG" and to_save.mode not in {"RGB", "L"}:
        to_save = to_save.convert("RGB")
    try:
        to_save.save(output_path, format=fmt)
    except Exception:
        fallback = output_path.with_suffix(".png")
        to_save = (
            image.convert("RGBA")
            if image.mode in {"RGBA", "LA"}
            else image.convert("RGB")
        )
        to_save.save(fallback, format="PNG")
        return fallback
    return output_path


def _validate(args: argparse.Namespace, dataset: Dataset, workspace_root: Path) -> None:
    if not dataset.poses:
        print("Warning: no poses found in workspace")
    for category in CATEGORIES:
        if not dataset.items_by_category.get(category):
            print(f"Warning: no items for category {category}")

    manifest_path = workspace_root / "wardrobe.json"
    if manifest_path.exists():
        try:
            payload = json.loads(manifest_path.read_text(encoding="utf-8"))
            schema = int(payload.get("schema_version", 0))
            if schema not in {4, 5}:
                raise SystemExit(
                    f"Validation failed: workspace manifest schema_version is {schema}, expected 4 or 5."
                )
        except Exception as error:
            print(f"Warning: failed to parse existing wardrobe.json: {error}")

    missing_item_names: list[str] = []
    for category in CATEGORIES:
        for item in dataset.items_by_category.get(category, []):
            if not item.name.strip():
                missing_item_names.append(f"{category}:{item.item_id}")

    if missing_item_names:
        preview = ", ".join(missing_item_names[:12])
        raise SystemExit(
            f"Validation failed: missing required item name for {preview}."
        )


def _write_render_sidecar(
    path: Path,
    pose_id: str,
    top_id: str,
    bottom_id: str,
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "pose_id": pose_id,
        "top_id": top_id,
        "bottom_id": bottom_id,
    }
    _write_structured_sidecar(path, payload)


def _write_overlay_sidecar(
    path: Path, pose_id: str, category: str, item_id: str
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "pose_id": pose_id,
        "category": category,
        "item_id": item_id,
    }
    _write_structured_sidecar(path, payload)


def _write_structured_sidecar(path: Path, payload: dict[str, Any]) -> None:
    if path.suffix.lower() in {".yaml", ".yml"}:
        lines = [
            f"{key}: {json.dumps(value, ensure_ascii=False)}"
            for key, value in payload.items()
        ]
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return
    path.write_text(json.dumps(payload, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
