from __future__ import annotations

import os
from pathlib import Path
from typing import Tuple

from .accessory_cutout import build_overlay_cutout_from_rendered


def region_box(size: Tuple[int, int], region: Tuple[float, float, float, float]) -> Tuple[int, int, int, int]:
    width, height = size
    x, y, w, h = region
    return (
        int(width * x),
        int(height * y),
        max(1, int(width * w)),
        max(1, int(height * h)),
    )


def anchor_from_region(size: Tuple[int, int], region: Tuple[float, float, float, float]) -> list[float]:
    x, y, w, h = region
    return [round(x, 6), round(y, 6), round(w, 6), round(h, 6)]


def anchor_from_bbox(size: Tuple[int, int], bbox: Tuple[int, int, int, int]) -> list[float]:
    width, height = size
    left, top, right, bottom = bbox
    anchor = [
        left / width,
        top / height,
        (right - left) / width,
        (bottom - top) / height,
    ]
    return [round(value, 6) for value in anchor]


def build_overlay_band_from_rendered(
    rendered_path: Path,
    crop: Tuple[float, float, float, float],
    output_path: Path,
    *,
    category: str | None = None,
    base_path: Path | None = None,
    dynamic_crop: dict | None = None,
    pose_neck_y: float | None = None,
    pose_ankle_y: float | None = None,
) -> list[float]:
    del crop

    if category not in {"headwear", "shoes"}:
        raise ValueError("Accessory overlay generation only supports headwear and shoes.")

    cutout_cfg = dynamic_crop if isinstance(dynamic_crop, dict) else {}
    cutout_mode = str(cutout_cfg.get("cutout_mode", "")).strip().lower()
    if cutout_mode != "sam_vit_h":
        raise ValueError(
            "Accessory overlays require render.overlay_crop.cutout_mode = sam_vit_h"
        )

    debug_dir = None
    raw_debug_dir = (os.environ.get("WARDROBE_CUTOUT_DEBUG_DIR") or "").strip()
    if raw_debug_dir:
        debug_dir = Path(raw_debug_dir)

    result = build_overlay_cutout_from_rendered(
        rendered_path=rendered_path,
        output_path=output_path,
        category=category,
        base_path=base_path,
        pose_neck_y=pose_neck_y,
        pose_ankle_y=pose_ankle_y,
        device=os.environ.get("WARDROBE_CUTOUT_DEVICE") or "auto",
        feather=False,
        debug_dir=debug_dir,
    )
    if result is None:
        raise RuntimeError(f"Native accessory cutout failed for {category}: {rendered_path}")
    return result.anchor
