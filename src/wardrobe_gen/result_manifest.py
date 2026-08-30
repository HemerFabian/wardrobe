from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from PIL import Image, ImageOps

from .dataset import (
    ClassificationInfo,
    Dataset,
    Item,
    PendingIntakeItem,
    Pose,
    overlay_meta_output_path,
    overlay_output_path,
    pose_thumbnail_output_path,
    render_meta_output_path,
    render_output_path,
    thumbnail_output_path,
)
from .output_size import resolve_output_size
from .overlay import anchor_from_bbox, anchor_from_region

_CANDIDATE_FORMATS = ["png", "webp", "jpg", "jpeg"]


@dataclass(frozen=True)
class ResultManifest:
    workspace_root: Path
    schema_version: int = 5

    @property
    def path(self) -> Path:
        return self.workspace_root / "wardrobe.json"

    def write(self, dataset: Dataset, config: dict[str, Any]) -> Path:
        payload = build_result_manifest(dataset, self.workspace_root, config)
        self.workspace_root.mkdir(parents=True, exist_ok=True)
        self.path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
        return self.path


def build_result_manifest(
    dataset: Dataset,
    workspace_root: Path,
    config: dict[str, Any],
) -> dict[str, Any]:
    images_cfg = config["images"]
    image_format = str(images_cfg["image_format"])
    overlay_format = str(images_cfg["overlay_format"])
    thumbnail_format = str(images_cfg["thumbnail_format"])
    thumbnail_size = tuple(images_cfg["thumbnail_size"])
    output_size = resolve_output_size(images_cfg=images_cfg, poses=dataset.poses)
    reference_crops = ((config.get("render") or {}).get("reference_crops") or {})

    renders_payload: list[dict[str, Any]] = []
    overlays_payload: list[dict[str, Any]] = []

    render_keys: set[tuple[str, str, str]] = set()
    overlay_keys: set[tuple[str, str, str]] = set()

    for pose in dataset.poses:
        for top in dataset.items_by_category.get("top", []):
            for bottom in dataset.items_by_category.get("bottom", []):
                path = _find_existing_output(
                    render_output_path(
                        workspace_root,
                        pose.pose_id,
                        top.item_id,
                        bottom.item_id,
                        image_format,
                    )
                )
                if not path.exists():
                    continue

                key = (pose.pose_id, top.item_id, bottom.item_id)
                render_keys.add(key)
                rel = _relative_to_workspace(path, workspace_root)
                renders_payload.append(
                    {
                        "pose_id": pose.pose_id,
                        "top_id": top.item_id,
                        "bottom_id": bottom.item_id,
                        "path": rel,
                        "meta_path": _relative_to_workspace(
                            render_meta_output_path(
                                workspace_root,
                                pose.pose_id,
                                top.item_id,
                                bottom.item_id,
                            ),
                            workspace_root,
                        ),
                        "size": list(_safe_image_size(path, fallback=output_size)),
                    }
                )

        for category in ("headwear", "shoes"):
            region = reference_crops.get(category) or (0.0, 0.0, 1.0, 1.0)
            for item in dataset.items_by_category.get(category, []):
                path = _find_existing_output(
                    overlay_output_path(
                        workspace_root,
                        pose.pose_id,
                        category,
                        item.item_id,
                        overlay_format,
                    )
                )
                if not path.exists():
                    continue

                overlay_keys.add((pose.pose_id, category, item.item_id))
                rel = _relative_to_workspace(path, workspace_root)
                anchor_box = _overlay_anchor_box(path, region=region)
                overlays_payload.append(
                    {
                        "pose_id": pose.pose_id,
                        "category": category,
                        "item_id": item.item_id,
                        "path": rel,
                        "meta_path": _relative_to_workspace(
                            overlay_meta_output_path(
                                workspace_root,
                                pose.pose_id,
                                category,
                                item.item_id,
                            ),
                            workspace_root,
                        ),
                        "anchor_box": anchor_box,
                    }
                )

    top_items = dataset.items_by_category.get("top", [])
    bottom_items = dataset.items_by_category.get("bottom", [])

    top_ready = {
        item.item_id: _is_top_render_ready(item, dataset.poses, bottom_items, render_keys)
        for item in top_items
    }
    bottom_ready = {
        item.item_id: _is_bottom_render_ready(item, dataset.poses, top_items, render_keys)
        for item in bottom_items
    }

    overlay_ready: dict[tuple[str, str], bool] = {}
    for category in ("headwear", "shoes"):
        for item in dataset.items_by_category.get(category, []):
            ready = bool(dataset.poses) and all(
                (pose.pose_id, category, item.item_id) in overlay_keys
                for pose in dataset.poses
            )
            overlay_ready[(category, item.item_id)] = ready

    poses_payload = [
        _build_pose_payload(
            pose=pose,
            workspace_root=workspace_root,
            thumbnail_size=thumbnail_size,
            thumbnail_format=thumbnail_format,
            top_items=top_items,
            bottom_items=bottom_items,
            render_keys=render_keys,
        )
        for pose in dataset.poses
    ]

    categories_payload: dict[str, list[dict[str, Any]]] = {}
    for category, items in dataset.items_by_category.items():
        category_payload: list[dict[str, Any]] = []
        for item in items:
            if category == "top":
                render_ready = top_ready.get(item.item_id, False)
            elif category == "bottom":
                render_ready = bottom_ready.get(item.item_id, False)
            elif category in {"headwear", "shoes"}:
                render_ready = overlay_ready.get((category, item.item_id), False)
            else:
                render_ready = item.render_ready

            category_payload.append(
                _build_item_payload(
                    item=item,
                    workspace_root=workspace_root,
                    thumbnail_size=thumbnail_size,
                    thumbnail_format=thumbnail_format,
                    render_ready=render_ready,
                )
            )
        categories_payload[category] = category_payload

    now_iso = datetime.now(timezone.utc).isoformat()
    intake_queue_payload = [
        _build_intake_queue_payload(
            pending=pending,
            workspace_root=workspace_root,
            thumbnail_format=thumbnail_format,
            generated_at=now_iso,
        )
        for pending in dataset.intake_queue
    ]
    regeneration_payload = _build_regeneration_payload(
        dataset=dataset,
        workspace_root=workspace_root,
        image_format=image_format,
        overlay_format=overlay_format,
    )

    payload: dict[str, Any] = {
        "schema_version": 5,
        "generated_at": now_iso,
        "images": {
            "output_size": list(output_size),
            "image_format": image_format,
            "overlay_format": overlay_format,
            "thumbnail_size": list(images_cfg["thumbnail_size"]),
            "thumbnail_format": thumbnail_format,
        },
        "poses": poses_payload,
        "categories": categories_payload,
        "intake_queue": intake_queue_payload,
        "regeneration": regeneration_payload,
        "renders": renders_payload,
        "overlays": overlays_payload,
    }

    return payload


def _build_pose_payload(
    *,
    pose: Pose,
    workspace_root: Path,
    thumbnail_size: tuple[int, int],
    thumbnail_format: str,
    top_items: list[Item],
    bottom_items: list[Item],
    render_keys: set[tuple[str, str, str]],
) -> dict[str, Any]:
    required = len(top_items) * len(bottom_items)
    render_ready = required > 0 and all(
        (pose.pose_id, top.item_id, bottom.item_id) in render_keys
        for top in top_items
        for bottom in bottom_items
    )

    pose_path_rel = _relative_to_workspace(pose.path, workspace_root)
    thumb_path = pose.thumb_path
    if thumb_path is None:
        auto_thumb = pose_thumbnail_output_path(
            workspace_root,
            pose.pose_id,
            thumbnail_format,
        )
        thumb_path = _ensure_thumbnail(
            source_path=pose.path,
            output_path=auto_thumb,
            thumbnail_size=thumbnail_size,
            thumbnail_format=thumbnail_format,
        )
    else:
        thumb_path = _ensure_thumbnail(
            source_path=pose.path,
            output_path=thumb_path,
            thumbnail_size=thumbnail_size,
            thumbnail_format=thumbnail_format,
        )

    payload: dict[str, Any] = {
        "id": pose.pose_id,
        "name": pose.name,
        "path": pose_path_rel,
        "render_ready": render_ready,
        "meta_path": _relative_to_workspace(
            pose.meta_path or (workspace_root / "poses" / pose.pose_id / "pose.yaml"),
            workspace_root,
        ),
    }
    if thumb_path is not None:
        payload["thumb_path"] = _relative_to_workspace(thumb_path, workspace_root)
    if pose.neck_y is not None:
        payload["neck_y"] = pose.neck_y
    if pose.ankle_y is not None:
        payload["ankle_y"] = pose.ankle_y
    return payload


def _build_item_payload(
    *,
    item: Item,
    workspace_root: Path,
    thumbnail_size: tuple[int, int],
    thumbnail_format: str,
    render_ready: bool,
) -> dict[str, Any]:
    thumb_path = item.thumb_path
    if thumb_path is None:
        auto_thumb = thumbnail_output_path(
            workspace_root,
            item.category,
            item.item_id,
            thumbnail_format,
        )
        thumb_path = _ensure_thumbnail(
            source_path=item.path,
            output_path=auto_thumb,
            thumbnail_size=thumbnail_size,
            thumbnail_format=thumbnail_format,
        )
    else:
        thumb_path = _ensure_thumbnail(
            source_path=item.path,
            output_path=thumb_path,
            thumbnail_size=thumbnail_size,
            thumbnail_format=thumbnail_format,
        )

    meta_path = item.meta_path or (workspace_root / "items" / item.category / item.item_id / "item.yaml")
    resolved_thumb = thumb_path or thumbnail_output_path(
        workspace_root,
        item.category,
        item.item_id,
        thumbnail_format,
    )

    payload: dict[str, Any] = {
        "id": item.item_id,
        "name": item.name,
        "category": item.category,
        "subcategory": _normalized_or_default(item.subcategory),
        "color_primary": _normalized_or_default(item.color_primary),
        "material": _normalized_or_default(item.material),
        "style_occasion": _normalized_or_default(item.style_occasion),
        "pattern_design": _normalized_or_default(item.pattern_design),
        "path": _relative_to_workspace(item.path, workspace_root),
        "thumb_path": _relative_to_workspace(resolved_thumb, workspace_root),
        "meta_path": _relative_to_workspace(meta_path, workspace_root),
        "render_ready": render_ready,
        "classification": _classification_payload(item.classification),
        "tags": list(item.tags),
    }
    return payload


def _build_intake_queue_payload(
    *,
    pending: PendingIntakeItem,
    workspace_root: Path,
    thumbnail_format: str,
    generated_at: str,
) -> dict[str, Any]:
    thumb_path = pending.thumb_path
    if thumb_path is None:
        thumb_path = workspace_root / "items" / "intake_queue" / pending.item_id / f"thumb.{thumbnail_format}"
    meta_path = pending.meta_path
    if meta_path is None:
        meta_path = workspace_root / "items" / "intake_queue" / pending.item_id / "item.yaml"

    return {
        "id": pending.item_id,
        "path": _relative_to_workspace(pending.path, workspace_root),
        "thumb_path": _relative_to_workspace(thumb_path, workspace_root),
        "meta_path": _relative_to_workspace(meta_path, workspace_root),
        "created_at": pending.created_at or generated_at,
    }


def _classification_payload(classification: ClassificationInfo | None) -> dict[str, str]:
    if classification is None:
        now_iso = datetime.now(timezone.utc).isoformat()
        return {
            "provider": "manual",
            "model": "n/a",
            "classified_at": now_iso,
            "prompt_version": "legacy-v2",
        }
    return {
        "provider": classification.provider,
        "model": classification.model,
        "classified_at": classification.classified_at,
        "prompt_version": classification.prompt_version,
    }


def _normalized_or_default(value: str | None, default: str = "unknown") -> str:
    if value is None:
        return default
    normalized = " ".join(value.strip().lower().split())
    return normalized or default


def _safe_image_size(path: Path, fallback: tuple[int, int]) -> tuple[int, int]:
    try:
        with Image.open(path) as image:
            return image.size
    except Exception:
        return fallback


def _ensure_thumbnail(
    *,
    source_path: Path,
    output_path: Path,
    thumbnail_size: tuple[int, int],
    thumbnail_format: str,
) -> Path | None:
    if output_path.exists():
        return output_path

    try:
        with Image.open(source_path) as image:
            converted = image.convert("RGB")
            thumb = ImageOps.contain(converted, thumbnail_size)
            output_path.parent.mkdir(parents=True, exist_ok=True)
            thumb.save(output_path, format=_thumbnail_format_name(thumbnail_format))
        return output_path
    except Exception:
        return None


def _thumbnail_format_name(thumbnail_format: str) -> str:
    fmt_key = thumbnail_format.lower()
    if fmt_key in {"jpg", "jpeg"}:
        return "JPEG"
    return thumbnail_format.upper()


def _find_existing_output(primary: Path) -> Path:
    if primary.exists():
        return primary

    fmt = primary.suffix.lstrip(".").lower()
    candidates = [fmt] + [c for c in _CANDIDATE_FORMATS if c != fmt]
    stem = primary.with_suffix("")
    for candidate in candidates:
        p = stem.with_suffix(f".{candidate}")
        if p.exists():
            return p
    return primary


def _overlay_anchor_box(
    overlay_path: Path,
    region: Any,
) -> list[float]:
    region_tuple = tuple(region)
    try:
        with Image.open(overlay_path) as image:
            rgba = image.convert("RGBA")
            alpha = rgba.split()[-1]
            bbox = alpha.getbbox()
            if bbox:
                return anchor_from_bbox(rgba.size, bbox)
            return anchor_from_region(rgba.size, region_tuple)
    except Exception:
        return anchor_from_region((1, 1), region_tuple)


def _build_regeneration_payload(
    *,
    dataset: Dataset,
    workspace_root: Path,
    image_format: str,
    overlay_format: str,
) -> dict[str, list[dict[str, Any]]]:
    remaining_item_requests = [
        request
        for request in dataset.regenerate_items
        if not _is_item_regeneration_completed(
            request=request,
            dataset=dataset,
            workspace_root=workspace_root,
            image_format=image_format,
            overlay_format=overlay_format,
        )
    ]
    remaining_target_requests = [
        request
        for request in dataset.regenerate_targets
        if not _is_target_regeneration_completed(
            request=request,
            dataset=dataset,
            workspace_root=workspace_root,
            image_format=image_format,
            overlay_format=overlay_format,
        )
    ]
    return {
        "items": [
            {
                "category": request.category,
                "item_id": request.item_id,
                "requested_at": request.requested_at,
            }
            for request in remaining_item_requests
        ],
        "targets": [
            {
                "type": request.type,
                **({"pose_id": request.pose_id} if request.pose_id is not None else {}),
                **({"category": request.category} if request.category is not None else {}),
                **({"item_id": request.item_id} if request.item_id is not None else {}),
                **({"top_id": request.top_id} if request.top_id is not None else {}),
                **({"bottom_id": request.bottom_id} if request.bottom_id is not None else {}),
                "requested_at": request.requested_at,
            }
            for request in remaining_target_requests
        ],
    }


def _is_item_regeneration_completed(
    *,
    request: Any,
    dataset: Dataset,
    workspace_root: Path,
    image_format: str,
    overlay_format: str,
) -> bool:
    pose_ids = [pose.pose_id for pose in dataset.poses]
    top_ids = {item.item_id for item in dataset.items_by_category.get("top", [])}
    bottom_ids = {item.item_id for item in dataset.items_by_category.get("bottom", [])}
    headwear_ids = {
        item.item_id for item in dataset.items_by_category.get("headwear", [])
    }
    shoes_ids = {item.item_id for item in dataset.items_by_category.get("shoes", [])}

    if request.category == "top" and request.item_id in top_ids:
        bottoms = dataset.items_by_category.get("bottom", [])
        return bool(pose_ids and bottoms) and all(
            _render_output_satisfies_request(
                workspace_root=workspace_root,
                pose_id=pose_id,
                top_id=request.item_id,
                bottom_id=bottom.item_id,
                image_format=image_format,
                requested_at=request.requested_at,
            )
            for pose_id in pose_ids
            for bottom in bottoms
        )
    if request.category == "bottom" and request.item_id in bottom_ids:
        tops = dataset.items_by_category.get("top", [])
        return bool(pose_ids and tops) and all(
            _render_output_satisfies_request(
                workspace_root=workspace_root,
                pose_id=pose_id,
                top_id=top.item_id,
                bottom_id=request.item_id,
                image_format=image_format,
                requested_at=request.requested_at,
            )
            for pose_id in pose_ids
            for top in tops
        )
    if request.category == "headwear" and request.item_id in headwear_ids:
        return bool(pose_ids) and all(
            _overlay_output_satisfies_request(
                workspace_root=workspace_root,
                pose_id=pose_id,
                category="headwear",
                item_id=request.item_id,
                overlay_format=overlay_format,
                requested_at=request.requested_at,
            )
            for pose_id in pose_ids
        )
    if request.category == "shoes" and request.item_id in shoes_ids:
        return bool(pose_ids) and all(
            _overlay_output_satisfies_request(
                workspace_root=workspace_root,
                pose_id=pose_id,
                category="shoes",
                item_id=request.item_id,
                overlay_format=overlay_format,
                requested_at=request.requested_at,
            )
            for pose_id in pose_ids
        )
    return False


def _is_target_regeneration_completed(
    *,
    request: Any,
    dataset: Dataset,
    workspace_root: Path,
    image_format: str,
    overlay_format: str,
) -> bool:
    pose_ids = {pose.pose_id for pose in dataset.poses}
    top_ids = {item.item_id for item in dataset.items_by_category.get("top", [])}
    bottom_ids = {item.item_id for item in dataset.items_by_category.get("bottom", [])}
    headwear_ids = {
        item.item_id for item in dataset.items_by_category.get("headwear", [])
    }
    shoes_ids = {item.item_id for item in dataset.items_by_category.get("shoes", [])}

    if request.type == "pose_item":
        if request.pose_id not in pose_ids or request.category is None or request.item_id is None:
            return False
        if request.category == "top" and request.item_id in top_ids:
            bottoms = dataset.items_by_category.get("bottom", [])
            return bool(bottoms) and all(
                _render_output_satisfies_request(
                    workspace_root=workspace_root,
                    pose_id=request.pose_id,
                    top_id=request.item_id,
                    bottom_id=bottom.item_id,
                    image_format=image_format,
                    requested_at=request.requested_at,
                )
                for bottom in bottoms
            )
        if request.category == "bottom" and request.item_id in bottom_ids:
            tops = dataset.items_by_category.get("top", [])
            return bool(tops) and all(
                _render_output_satisfies_request(
                    workspace_root=workspace_root,
                    pose_id=request.pose_id,
                    top_id=top.item_id,
                    bottom_id=request.item_id,
                    image_format=image_format,
                    requested_at=request.requested_at,
                )
                for top in tops
            )
        if request.category == "headwear" and request.item_id in headwear_ids:
            return _overlay_output_satisfies_request(
                workspace_root=workspace_root,
                pose_id=request.pose_id,
                category="headwear",
                item_id=request.item_id,
                overlay_format=overlay_format,
                requested_at=request.requested_at,
            )
        if request.category == "shoes" and request.item_id in shoes_ids:
            return _overlay_output_satisfies_request(
                workspace_root=workspace_root,
                pose_id=request.pose_id,
                category="shoes",
                item_id=request.item_id,
                overlay_format=overlay_format,
                requested_at=request.requested_at,
            )
        return False

    if request.type == "render":
        if (
            request.pose_id not in pose_ids
            or request.top_id not in top_ids
            or request.bottom_id not in bottom_ids
        ):
            return False
        return _render_output_satisfies_request(
            workspace_root=workspace_root,
            pose_id=request.pose_id,
            top_id=request.top_id,
            bottom_id=request.bottom_id,
            image_format=image_format,
            requested_at=request.requested_at,
        )

    if request.type == "overlay":
        if (
            request.pose_id not in pose_ids
            or request.category not in {"headwear", "shoes"}
            or request.item_id is None
        ):
            return False
        valid_ids = headwear_ids if request.category == "headwear" else shoes_ids
        if request.item_id not in valid_ids:
            return False
        return _overlay_output_satisfies_request(
            workspace_root=workspace_root,
            pose_id=request.pose_id,
            category=request.category,
            item_id=request.item_id,
            overlay_format=overlay_format,
            requested_at=request.requested_at,
        )

    return False


def _render_output_satisfies_request(
    *,
    workspace_root: Path,
    pose_id: str,
    top_id: str,
    bottom_id: str,
    image_format: str,
    requested_at: str | None,
) -> bool:
    path = _find_existing_output(
        render_output_path(
            workspace_root,
            pose_id,
            top_id,
            bottom_id,
            image_format,
        )
    )
    return _output_satisfies_regeneration_request(path, requested_at)


def _overlay_output_satisfies_request(
    *,
    workspace_root: Path,
    pose_id: str,
    category: str,
    item_id: str,
    overlay_format: str,
    requested_at: str | None,
) -> bool:
    path = _find_existing_output(
        overlay_output_path(
            workspace_root,
            pose_id,
            category,
            item_id,
            overlay_format,
        )
    )
    return _output_satisfies_regeneration_request(path, requested_at)


def _output_satisfies_regeneration_request(path: Path, requested_at: str | None) -> bool:
    if not path.exists():
        return False
    requested_at_dt = _parse_request_timestamp(requested_at)
    if requested_at_dt is None:
        return False
    output_written_at = datetime.fromtimestamp(path.stat().st_mtime, tz=timezone.utc)
    return output_written_at >= requested_at_dt


def _parse_request_timestamp(value: str | None) -> datetime | None:
    if value is None:
        return None
    text = value.strip()
    if not text:
        return None
    if text.endswith("Z"):
        text = f"{text[:-1]}+00:00"
    try:
        parsed = datetime.fromisoformat(text)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def _is_top_render_ready(
    item: Item,
    poses: list[Pose],
    bottoms: list[Item],
    render_keys: set[tuple[str, str, str]],
) -> bool:
    if not poses or not bottoms:
        return False
    return all(
        (pose.pose_id, item.item_id, bottom.item_id) in render_keys
        for pose in poses
        for bottom in bottoms
    )


def _is_bottom_render_ready(
    item: Item,
    poses: list[Pose],
    tops: list[Item],
    render_keys: set[tuple[str, str, str]],
) -> bool:
    if not poses or not tops:
        return False
    return all(
        (pose.pose_id, top.item_id, item.item_id) in render_keys
        for pose in poses
        for top in tops
    )


def _relative_to_workspace(path: Path, workspace_root: Path) -> str:
    try:
        return path.relative_to(workspace_root).as_posix()
    except ValueError:
        return path.as_posix()
