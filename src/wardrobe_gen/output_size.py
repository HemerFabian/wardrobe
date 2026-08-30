from __future__ import annotations

import math
from collections.abc import Mapping, Sequence
from statistics import median
from typing import Any

from PIL import Image

from .dataset import Pose

_DEFAULT_OUTPUT_SIZE = (1080, 1920)
_DEFAULT_SIZE_MULTIPLE = 64


def resolve_output_size(
    images_cfg: Mapping[str, Any],
    poses: Sequence[Pose],
) -> tuple[int, int]:
    configured_size = _normalize_output_size(images_cfg.get("output_size"))
    if configured_size is None:
        configured_size = _DEFAULT_OUTPUT_SIZE

    dynamic_enabled, dynamic_cfg = _resolve_dynamic_cfg(images_cfg.get("dynamic_output_size"))
    if not dynamic_enabled:
        return configured_size

    max_megapixels = _resolve_max_megapixels(
        dynamic_cfg=dynamic_cfg,
        images_cfg=images_cfg,
        configured_size=configured_size,
    )
    aspect_ratio = _resolve_aspect_ratio(
        dynamic_cfg=dynamic_cfg,
        images_cfg=images_cfg,
        poses=poses,
        configured_size=configured_size,
    )
    size_multiple = _resolve_positive_int(
        dynamic_cfg.get("size_multiple"),
        images_cfg.get("output_size_multiple"),
        default=_DEFAULT_SIZE_MULTIPLE,
    )
    min_edge = _resolve_positive_int(
        dynamic_cfg.get("min_edge"),
        images_cfg.get("output_min_edge"),
        default=size_multiple,
    )
    return _solve_size(
        aspect_ratio=aspect_ratio,
        max_pixels=max_megapixels * 1_000_000.0,
        size_multiple=size_multiple,
        min_edge=min_edge,
        fallback=configured_size,
    )


def _resolve_dynamic_cfg(raw: Any) -> tuple[bool, Mapping[str, Any]]:
    if isinstance(raw, Mapping):
        return bool(raw.get("enabled", False)), raw
    return bool(raw), {}


def _resolve_max_megapixels(
    *,
    dynamic_cfg: Mapping[str, Any],
    images_cfg: Mapping[str, Any],
    configured_size: tuple[int, int],
) -> float:
    configured_area_mp = (configured_size[0] * configured_size[1]) / 1_000_000.0
    return _resolve_positive_float(
        dynamic_cfg.get("max_megapixels"),
        images_cfg.get("output_max_megapixels"),
        images_cfg.get("input_megapixels"),
        default=configured_area_mp,
    )


def _resolve_aspect_ratio(
    *,
    dynamic_cfg: Mapping[str, Any],
    images_cfg: Mapping[str, Any],
    poses: Sequence[Pose],
    configured_size: tuple[int, int],
) -> float:
    explicit = _resolve_positive_float(
        dynamic_cfg.get("aspect_ratio"),
        images_cfg.get("output_aspect_ratio"),
        default=-1.0,
    )
    if explicit > 0:
        return explicit

    pose_aspects = _pose_aspects(poses)
    if pose_aspects:
        return float(median(pose_aspects))

    if configured_size[1] <= 0:
        return _DEFAULT_OUTPUT_SIZE[0] / _DEFAULT_OUTPUT_SIZE[1]
    return configured_size[0] / configured_size[1]


def _pose_aspects(poses: Sequence[Pose]) -> list[float]:
    aspects: list[float] = []
    for pose in poses:
        try:
            with Image.open(pose.path) as image:
                if image.height <= 0:
                    continue
                aspects.append(image.width / image.height)
        except Exception:
            continue
    return aspects


def _solve_size(
    *,
    aspect_ratio: float,
    max_pixels: float,
    size_multiple: int,
    min_edge: int,
    fallback: tuple[int, int],
) -> tuple[int, int]:
    if aspect_ratio <= 0 or max_pixels <= 0:
        return fallback

    multiple = max(1, size_multiple)
    min_size = max(1, min_edge)

    ideal_height = math.sqrt(max_pixels / aspect_ratio)
    max_height = max(multiple, int(ideal_height // multiple) * multiple)

    for require_min_edge in (True, False):
        height = max_height
        while height >= multiple:
            width = max(multiple, int(((height * aspect_ratio) // multiple) * multiple))
            pixels = width * height
            if pixels <= max_pixels:
                if not require_min_edge or (width >= min_size and height >= min_size):
                    return width, height
            height -= multiple

    return fallback


def _normalize_output_size(raw: Any) -> tuple[int, int] | None:
    if not isinstance(raw, (list, tuple)) or len(raw) != 2:
        return None
    width = _to_positive_int(raw[0])
    height = _to_positive_int(raw[1])
    if width is None or height is None:
        return None
    return width, height


def _resolve_positive_int(*values: Any, default: int) -> int:
    for value in values:
        candidate = _to_positive_int(value)
        if candidate is not None:
            return candidate
    return default


def _resolve_positive_float(*values: Any, default: float) -> float:
    for value in values:
        candidate = _to_positive_float(value)
        if candidate is not None:
            return candidate
    return default


def _to_positive_int(raw: Any) -> int | None:
    try:
        value = int(raw)
    except Exception:
        return None
    if value <= 0:
        return None
    return value


def _to_positive_float(raw: Any) -> float | None:
    try:
        value = float(raw)
    except Exception:
        return None
    if value <= 0:
        return None
    return value
