from __future__ import annotations

import copy
import json
from pathlib import Path
from typing import Any

try:
    import yaml  # type: ignore
except ImportError:  # pragma: no cover
    yaml = None


class ConfigError(RuntimeError):
    pass


PACKAGE_ROOT = Path(__file__).resolve().parent
DEFAULT_LOCAL_CONFIG = "config.local.yaml"
DEFAULT_WORKFLOW = PACKAGE_ROOT / "workflows" / "flux2_klein_4b_edit.json"

DEFAULT_CONFIG: dict[str, Any] = {
    "workflow_template": str(DEFAULT_WORKFLOW),
    "renderer": "comfyui",
    "flux_model": {
        "unet": "flux-2-klein-4b-fp8.safetensors",
        "clip_name": "qwen_3_4b.safetensors",
        "vae_name": "flux2-vae.safetensors",
    },
    "comfyui": {
        "endpoint": "http://127.0.0.1:8188",
        "timeout_sec": 1800,
        "poll_interval_sec": 2,
        "client_id": "wardrobe-gen",
        "input_copy_dir": "",
        "upload_images": True,
        "output_type": "output",
    },
    "vlm": {
        "provider": "ollama",
        "endpoint": "http://127.0.0.1:11434",
        "model": "qwen3-vl:8b-instruct-q4_K_M",
        "timeout_sec": 600,
        "max_retries": 5,
        "temperature": 0.1,
        "prompt_version": "2026-02-21-v1",
    },
    "classify": {"require_before_render": True},
    "cutout": {
        "sam_checkpoint": "models/sam_vit_h_4b8939.pth",
        "grounding_dino_model": "IDEA-Research/grounding-dino-tiny",
        "allow_download": False,
        "device": "auto",
    },
    "images": {
        "output_size": [1072, 1936],
        "dynamic_output_size": {
            "enabled": True,
            "max_megapixels": 2.0,
            "size_multiple": 64,
            "min_edge": 256,
        },
        "input_megapixels": 2,
        "image_format": "webp",
        "overlay_format": "png",
        "thumbnail_size": [256, 256],
        "thumbnail_format": "jpg",
    },
    "quality": {
        "steps": 4,
        "cfg": 1.0,
        "sampler": "euler",
        "scheduler": "normal",
    },
    "workflow_nodes": {
        "load_pose": 76,
        "load_ref1": 81,
        "positive_prompt": 92,
        "save": 94,
    },
    "render": {
        "prompts": {
            "negative_prompt": (
                "do not change pose, do not change face, do not change background, "
                "no extra items, no artifacts, no watermark"
            ),
            "base": (
                "Replace the top in image1 with the top in image2 and the bottom "
                "in image1 with the bottom in image3."
            ),
            "base_top": (
                "The person from image1 remains the same. Replace only the upper "
                "garment with the garment from image2 as the only visible upper "
                "layer, with realistic fit, seams, cuffs, and folds. Keep lighting "
                "and camera from image1."
            ),
            "base_bottom": (
                "The person from image1 remains the same. Replace only the lower "
                "garment with the garment from image2 as the only visible lower "
                "layer, with realistic fit, seams, hems, and folds. Keep lighting "
                "and camera from image1."
            ),
            "overlay_headwear": (
                "Add only the headwear from image2 onto the head of the person in "
                "image1. Match its shape and placement closely. Keep hair, face, "
                "pose, background, and lighting unchanged."
            ),
            "overlay_shoes": (
                "Place only the shoes from image2 onto the existing feet in image1. "
                "Match their placement and silhouette. Keep legs, pose, ground "
                "contact, background, and lighting unchanged."
            ),
        },
        "overlay_crop": {"enabled": True, "cutout_mode": "sam_vit_h"},
        "reference_crops": {
            "headwear": [0.0, 0.0, 1.0, 0.2],
            "shoes": [0.0, 0.84, 1.0, 0.16],
        },
    },
}


def discover_config_path(
    path: str | Path | None = None, *, cwd: Path | None = None
) -> Path | None:
    if path is not None:
        explicit = Path(path).expanduser()
        if not explicit.is_absolute():
            explicit = (cwd or Path.cwd()) / explicit
        return explicit.resolve()

    candidate = (cwd or Path.cwd()) / DEFAULT_LOCAL_CONFIG
    return candidate.resolve() if candidate.is_file() else None


def load_config(
    path: str | Path | None = None, *, cwd: Path | None = None
) -> dict[str, Any]:
    config_path = discover_config_path(path, cwd=cwd)
    data: dict[str, Any] = {}
    if config_path is not None:
        if not config_path.is_file():
            raise ConfigError(f"Config not found: {config_path}")
        raw = config_path.read_text(encoding="utf-8")
        parsed = yaml.safe_load(raw) if yaml is not None else json.loads(raw)
        if parsed is None:
            parsed = {}
        if not isinstance(parsed, dict):
            raise ConfigError("Config root must be a mapping")
        data = parsed

    merged = _merge_defaults(data, DEFAULT_CONFIG)
    _validate_config(merged)
    return merged


def resolve_path(base_dir: Path, value: str | Path) -> Path:
    value_path = Path(value).expanduser()
    if value_path.is_absolute():
        return value_path
    return (base_dir / value_path).resolve()


def ensure_dir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)


def _merge_defaults(user: dict[str, Any], defaults: dict[str, Any]) -> dict[str, Any]:
    merged = copy.deepcopy(defaults)
    for key, user_value in user.items():
        default_value = merged.get(key)
        if isinstance(default_value, dict) and isinstance(user_value, dict):
            merged[key] = _merge_defaults(user_value, default_value)
        else:
            merged[key] = copy.deepcopy(user_value)
    return merged


def _validate_config(config: dict[str, Any]) -> None:
    images = config.get("images")
    if not isinstance(images, dict):
        raise ConfigError("Missing required images config block.")
    for key in (
        "output_size",
        "image_format",
        "overlay_format",
        "thumbnail_size",
        "thumbnail_format",
    ):
        if key not in images:
            raise ConfigError(f"Missing required images.{key} setting.")

    vlm = config.get("vlm")
    if not isinstance(vlm, dict):
        raise ConfigError("Missing required vlm config block.")
    if str(vlm.get("provider", "")).strip().lower() != "ollama":
        raise ConfigError("Only vlm.provider=ollama is supported in this release.")
    if not str(vlm.get("model", "")).strip():
        raise ConfigError("Missing required vlm.model setting.")

    comfyui = config.get("comfyui")
    if not isinstance(comfyui, dict) or not str(comfyui.get("endpoint", "")).strip():
        raise ConfigError("Missing required comfyui.endpoint setting.")
