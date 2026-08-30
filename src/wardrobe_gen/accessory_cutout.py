from __future__ import annotations

import json
import math
import os
import warnings
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np

try:
    import yaml  # type: ignore
except Exception:  # pragma: no cover
    yaml = None

from PIL import Image, ImageChops, ImageColor, ImageDraw, ImageFilter, ImageStat

from .image_utils import ensure_parent


@dataclass(frozen=True)
class ItemContext:
    item_id: str
    category: str
    name: str
    subcategory: str | None = None
    color_primary: str | None = None
    material: str | None = None
    style_occasion: str | None = None
    pattern_design: str | None = None
    tags: tuple[str, ...] = ()


@dataclass(frozen=True)
class SemanticProfile:
    label: str
    roi_top_ratio: float
    roi_bottom_ratio: float
    seed_percentile: float
    grow_percentile: float
    min_seed_area_px: int
    close_radius: int
    open_radius: int
    max_vertical_ratio: float
    keep_seed_components: int
    keep_final_components: int
    skin_margin_px: int
    strict_only: bool = False


@dataclass(frozen=True)
class SegmentCandidate:
    mask: Image.Image
    confidence: float
    metadata: dict[str, Any]


@dataclass(frozen=True)
class CutoutResult:
    anchor: list[float]
    bbox: tuple[int, int, int, int]
    prompt: str
    score: float
    metrics: dict[str, Any]
    mask: Image.Image
    cutout: Image.Image


_MODEL_CACHE: dict[str, Any] = {}
_MASK_WHITE = 255
_MASK_BLACK = 0


def _pixel_data(image: Image.Image) -> list[Any]:
    width, height = image.size
    access = image.load()
    if access is None:
        return []
    return [access[x, y] for y in range(height) for x in range(width)]


def _channel_data(image: Image.Image) -> list[int]:
    return [int(value) for value in _pixel_data(image)]


def load_model(device: str = "auto") -> Any:
    requested_device = (device or "auto").strip().lower() or "auto"
    backend_name = _cutout_native_backend_name()
    cache_key = f"{backend_name}:{requested_device}"
    if cache_key in _MODEL_CACHE:
        return _MODEL_CACHE[cache_key]

    backend = None
    if backend_name == "sam_vit_h":
        backend = _load_grounded_sam_vit_h_backend(requested_device)

    _MODEL_CACHE[cache_key] = backend
    return backend


def segment(
    image: Image.Image,
    text_prompt: str,
    optional_roi: tuple[int, int, int, int] | None = None,
    *,
    device: str = "auto",
    category: str | None = None,
    detector_image: Image.Image | None = None,
    base_image: Image.Image | None = None,
) -> list[SegmentCandidate]:
    backend = load_model(device=device)
    if backend is None or not isinstance(backend, dict):
        return []

    try:
        kind = str(backend.get("kind") or "")
        if kind != "grounded_sam_vit_h":
            return []
        return _segment_with_grounded_sam_vit_h(
            image=image,
            detector_image=detector_image or image,
            base_image=base_image,
            text_prompt=text_prompt,
            optional_roi=optional_roi,
            backend=backend,
            category=category,
        )
    except Exception as exc:
        raise RuntimeError("GroundingDINO/SAM segmentation failed.") from exc


def postprocess(
    mask: Image.Image,
    *,
    close_radius: int = 1,
    open_radius: int = 0,
    min_area_px: int = 64,
    max_components: int = 2,
) -> Image.Image:
    processed = _binary_mask(mask)
    if close_radius > 0:
        processed = _apply_close(processed, close_radius)
    if open_radius > 0:
        processed = _apply_open(processed, open_radius)
    processed = _fill_holes(processed)
    processed = _keep_top_components(
        processed,
        min_area_px=max(1, int(min_area_px)),
        keep=max(1, int(max_components)),
    )
    return processed


def cutout_png(
    image: Image.Image,
    mask: Image.Image,
    *,
    feather: bool = False,
    feather_px: int = 2,
) -> Image.Image:
    alpha = _binary_mask(mask)
    if feather and feather_px > 0:
        alpha = alpha.filter(ImageFilter.GaussianBlur(radius=float(feather_px)))
    result = image.convert("RGBA")
    result.putalpha(alpha)
    return result


def prompt_candidates(context: ItemContext) -> list[str]:
    category = _normalize_category(context.category)
    subtype = (context.subcategory or "").strip().lower()
    style_occasion = (context.style_occasion or "").strip().lower()
    descriptor = " ".join(
        token for token in (subtype, context.name.lower(), style_occasion) if token
    ).strip()

    base_terms: list[str]
    if category == "headwear":
        base_terms = ["hat"]
        if "beanie" in descriptor:
            base_terms = ["beanie", "knit beanie", "knit cap", "winter hat", "hat"]
        elif "bucket" in descriptor:
            base_terms = ["bucket hat", "sun hat", "hat"]
        elif "cap" in descriptor:
            base_terms = ["baseball cap", "cap", "hat"]
        elif "santa" in descriptor:
            base_terms = ["santa hat", "holiday hat", "hat"]
    else:
        base_terms = ["shoes", "footwear"]
        if any(term in descriptor for term in ("dress", "loafer", "oxford", "derby", "formal")):
            base_terms = [
                "dress shoes",
                "formal shoes",
                "oxfords",
                "loafers",
                "shoes",
                "footwear",
            ]
        elif "slipper" in descriptor:
            base_terms = ["slippers", "slipper", "sandals", "footwear"]
        elif "boot" in descriptor:
            base_terms = ["boots", "boot", "chelsea boots", "footwear"]
        elif "flip" in descriptor:
            base_terms = ["flip-flops", "flip flops", "sandals", "footwear"]
        elif "sandal" in descriptor:
            base_terms = ["sandals", "sandal", "footwear"]
        elif "sneaker" in descriptor:
            base_terms = ["sneakers", "sneaker", "trainer", "running shoe", "shoe"]

    color = _clean_text(context.color_primary)
    material = _clean_text(context.material)
    prompts: list[str] = []
    for term in base_terms:
        prompts.append(term)
        prompts.append(f"only the {term}")
        prompts.append(f"{term} only")
        if color:
            prompts.append(f"{color} {term}")
        if material and material not in term:
            prompts.append(f"{material} {term}")
        if context.subcategory and context.subcategory.lower() not in term.lower():
            prompts.append(f"{context.subcategory} {term}")
    exact_name = _clean_text(context.name)
    if exact_name:
        prompts.append(exact_name)
        prompts.append(f"only the {exact_name}")
    return _dedupe_prompts(prompts)


def _detector_prompt_for_context(context: ItemContext) -> str:
    item_id = context.item_id.strip().lower()
    category = _normalize_category(context.category)
    subtype = (context.subcategory or "").strip().lower()

    if category == "headwear":
        if "beanie" in item_id or "beanie" in subtype:
            return "beanie"
        if "bucket" in item_id or "bucket" in subtype:
            return "bucket hat"
        if "cap" in item_id or "cap" in subtype or "dodgers" in item_id:
            return "baseball cap"
        if "santa" in item_id or "santa" in subtype:
            return "santa hat"
        return "hat"

    if "dress" in item_id or "dress" in subtype:
        return "pair of dress shoes"
    if "flip" in item_id or "flip" in subtype:
        return "pair of flip flops"
    if "slipper" in item_id or "slipper" in subtype:
        return "pair of slippers"
    if "sandal" in item_id or "sandal" in subtype:
        return "pair of sandals"
    if "high-top" in item_id or "high top" in item_id:
        return "pair of high top sneakers"
    if "sneaker" in item_id or "sneaker" in subtype:
        return "pair of sneakers"
    return "pair of shoes"


def build_overlay_cutout_from_rendered(
    rendered_path: Path,
    output_path: Path,
    *,
    category: str | None = None,
    base_path: Path | None = None,
    pose_neck_y: float | None = None,
    pose_ankle_y: float | None = None,
    device: str = "auto",
    feather: bool = False,
    debug_dir: Path | None = None,
) -> CutoutResult | None:
    context, results = evaluate_cutout_variants(
        rendered_path=rendered_path,
        output_path=output_path,
        category=category,
        base_path=base_path,
        pose_neck_y=pose_neck_y,
        pose_ankle_y=pose_ankle_y,
        device=device,
        feather=feather,
    )
    if not results:
        return None

    best = results[0]
    ensure_parent(output_path)
    best.cutout.save(output_path)

    if debug_dir is not None:
        _write_debug_artifacts(
            debug_dir=debug_dir,
            rendered=Image.open(rendered_path).convert("RGBA"),
            result=best,
            context=context,
            rendered_path=rendered_path,
        )

    return best


def evaluate_cutout_variants(
    *,
    rendered_path: Path,
    output_path: Path | None = None,
    category: str | None = None,
    base_path: Path | None = None,
    pose_neck_y: float | None = None,
    pose_ankle_y: float | None = None,
    device: str = "auto",
    feather: bool = False,
) -> tuple[ItemContext, list[CutoutResult]]:
    rendered = Image.open(rendered_path).convert("RGBA")
    base = None
    if base_path is not None and base_path.exists():
        try:
            base = Image.open(base_path).convert("RGBA")
        except Exception:
            base = None
    if base is not None and base.size != rendered.size:
        base = base.resize(rendered.size, Image.LANCZOS)

    resolved_output_path = output_path or _infer_output_like_path(rendered_path, category)
    context = _resolve_item_context(resolved_output_path, category)
    if context is None:
        context = ItemContext(
            item_id=resolved_output_path.stem,
            category=_normalize_category(category),
            name=resolved_output_path.stem.replace("-", " "),
        )

    prompt = _detector_prompt_for_context(context)
    native_candidates = segment(
        rendered,
        prompt,
        None,
        device=device,
        category=context.category,
        detector_image=rendered,
        base_image=base,
    )
    if not native_candidates:
        return context, []

    if _normalize_category(context.category) == "shoes":
        selected_candidates = native_candidates[:2]
        combined_mask = selected_candidates[0].mask
        for native_candidate in selected_candidates[1:]:
            combined_mask = _binary_union(combined_mask, native_candidate.mask)
        native_confidence = sum(float(item.confidence) for item in selected_candidates) / max(
            1, len(selected_candidates)
        )
        detector_score = sum(
            float(item.metadata.get("detector_score", 0.0)) for item in selected_candidates
        ) / max(1, len(selected_candidates))
        sam_iou = sum(float(item.metadata.get("sam_iou", 0.0)) for item in selected_candidates) / max(
            1, len(selected_candidates)
        )
        detected_box = _merged_detected_box(selected_candidates, (0, 0, rendered.size[0], rendered.size[1]))
    else:
        selected_candidates = [native_candidates[0]]
        combined_mask = selected_candidates[0].mask
        native_confidence = float(selected_candidates[0].confidence)
        detector_score = float(selected_candidates[0].metadata.get("detector_score", 0.0))
        sam_iou = float(selected_candidates[0].metadata.get("sam_iou", 0.0))
        detected_box = selected_candidates[0].metadata.get("detected_box")

    final_mask = _binary_mask(combined_mask)
    bbox = final_mask.getbbox()
    if bbox is None:
        return context, []

    area = _mask_area(final_mask)
    width, height = final_mask.size
    metrics = {
        "prompt": prompt,
        "category": _normalize_category(context.category),
        "candidate_source": "grounded_sam_vit_h",
        "fusion_mode": "direct_native_pair" if len(selected_candidates) > 1 else "direct_native",
        "native_confidence": round(native_confidence, 4),
        "detector_score": round(detector_score, 4),
        "sam_iou": round(sam_iou, 4),
        "paired_count": len(selected_candidates),
        "detected_box": detected_box,
        "coverage": area / max(1, width * height),
        "bbox_left_ratio": bbox[0] / max(1, width),
        "bbox_top_ratio": bbox[1] / max(1, height),
        "bbox_width_ratio": (bbox[2] - bbox[0]) / max(1, width),
        "bbox_height_ratio": (bbox[3] - bbox[1]) / max(1, height),
        "bbox_bottom_ratio": bbox[3] / max(1, height),
    }
    result = CutoutResult(
        anchor=_anchor_from_bbox(rendered.size, bbox),
        bbox=bbox,
        prompt=prompt,
        score=float(native_confidence),
        metrics=metrics,
        mask=final_mask,
        cutout=cutout_png(rendered, final_mask, feather=feather),
    )
    results = [result]

    results.sort(key=lambda item: item.score, reverse=True)
    return context, results


def _prepare_working_images(
    rendered: Image.Image,
    base: Image.Image | None,
    *,
    max_width: int = 384,
) -> tuple[Image.Image, Image.Image | None, bool]:
    width, height = rendered.size
    if width <= max_width:
        return rendered, base, False

    scale = max_width / float(width)
    resized_size = (max_width, max(1, int(round(height * scale))))
    resized_rendered = rendered.resize(resized_size, Image.LANCZOS)
    resized_base = None
    if base is not None:
        resized_base = base.resize(resized_size, Image.LANCZOS)
    return resized_rendered, resized_base, True


def _project_candidate_to_full_size(
    candidate: CutoutResult,
    *,
    rendered: Image.Image,
    diff_map: list[int],
    context: ItemContext,
    profile: SemanticProfile,
    prompt: str,
    feather: bool,
) -> CutoutResult | None:
    working_width, working_height = candidate.mask.size
    projected_mask = candidate.mask.resize(rendered.size, Image.NEAREST)
    projected_mask = postprocess(
        projected_mask,
        close_radius=1,
        open_radius=0,
        min_area_px=max(64, profile.min_seed_area_px),
        max_components=profile.keep_final_components,
    )
    bbox = projected_mask.getbbox()
    if bbox is None:
        return None

    scale_x = rendered.size[0] / max(1.0, float(working_width))
    scale_y = rendered.size[1] / max(1.0, float(working_height))
    carried_meta = _projected_candidate_meta(candidate.metrics, scale_x=scale_x, scale_y=scale_y)
    metrics = _mask_metrics(
        projected_mask,
        rendered=rendered,
        diff_map=diff_map,
        category=context.category,
        roi_box=(
            0,
            max(0, min(rendered.size[1] - 1, int(round(rendered.size[1] * profile.roi_top_ratio)))),
            rendered.size[0],
            max(1, min(rendered.size[1], int(round(rendered.size[1] * profile.roi_bottom_ratio)))),
        ),
        profile=profile,
        prompt=prompt,
        candidate_meta=carried_meta,
    )
    score = _score_metrics(metrics)
    if score <= -5.0:
        return None

    cutout = cutout_png(rendered, projected_mask, feather=feather)
    return CutoutResult(
        anchor=_anchor_from_bbox(rendered.size, bbox),
        bbox=bbox,
        prompt=prompt,
        score=score,
        metrics=metrics,
        mask=projected_mask,
        cutout=cutout,
    )


def _projected_candidate_meta(
    metrics: dict[str, Any],
    *,
    scale_x: float,
    scale_y: float,
) -> dict[str, Any]:
    carry_keys = (
        "candidate_source",
        "fusion_mode",
        "native_confidence",
        "detector_score",
        "sam_iou",
        "box_variant",
        "paired_count",
        "detected_box",
        "diff_overlap_ratio",
        "diff_support_fill_ratio",
        "underseg_penalty",
        "native_box",
        "roi_box",
        "aggressive_mode",
    )
    projected: dict[str, Any] = {}
    for key in carry_keys:
        if key not in metrics:
            continue
        value = metrics.get(key)
        if key in {"native_box", "roi_box"} and isinstance(value, list):
            projected[key] = _scale_box_values(value, scale_x=scale_x, scale_y=scale_y)
            continue
        projected[key] = value
    return projected


def _scale_box_values(
    values: list[Any],
    *,
    scale_x: float,
    scale_y: float,
) -> list[float]:
    if len(values) < 4:
        return [float(value) for value in values]
    scaled: list[float] = []
    for index, value in enumerate(values[:4]):
        factor = scale_x if index % 2 == 0 else scale_y
        scaled.append(round(float(value) * factor, 4))
    return scaled


def build_contact_sheet(
    tiles: list[tuple[str, Image.Image]],
    *,
    columns: int = 2,
    thumb_width: int = 960,
    background: str = "#f3f1ea",
) -> Image.Image:
    if not tiles:
        return Image.new("RGB", (thumb_width, thumb_width // 2), ImageColor.getrgb(background))

    processed: list[tuple[str, Image.Image]] = []
    thumb_height = 0
    for label, tile in tiles:
        scaled = tile.copy()
        scaled.thumbnail((thumb_width, 10_000), Image.LANCZOS)
        if scaled.mode != "RGB":
            bg = Image.new("RGB", scaled.size, ImageColor.getrgb(background))
            bg.paste(scaled, mask=scaled.split()[-1] if "A" in scaled.getbands() else None)
            scaled = bg
        processed.append((label, scaled))
        thumb_height = max(thumb_height, scaled.height)

    caption_height = 28
    cell_width = thumb_width
    cell_height = thumb_height + caption_height + 16
    rows = int(math.ceil(len(processed) / max(1, columns)))
    sheet = Image.new(
        "RGB",
        (cell_width * columns, cell_height * rows),
        ImageColor.getrgb(background),
    )
    draw = ImageDraw.Draw(sheet)
    for index, (label, tile) in enumerate(processed):
        col = index % columns
        row = index // columns
        left = col * cell_width
        top = row * cell_height
        tile_left = left + (cell_width - tile.width) // 2
        tile_top = top + 8
        sheet.paste(tile, (tile_left, tile_top))
        draw.text((left + 8, top + thumb_height + 10), label[:120], fill="#1b1a17")
    return sheet


def overlay_debug_tile(
    rendered: Image.Image,
    mask: Image.Image,
    cutout: Image.Image,
    *,
    title: str,
) -> Image.Image:
    width = max(1, rendered.width // 3)
    height = max(1, rendered.height // 3)
    original = rendered.copy()
    original.thumbnail((width, height), Image.LANCZOS)

    overlay = _preview_overlay(rendered, mask)
    overlay.thumbnail((width, height), Image.LANCZOS)

    cutout_tile = Image.new("RGBA", cutout.size, (242, 238, 227, 255))
    cutout_tile.alpha_composite(cutout)
    cutout_tile.thumbnail((width, height), Image.LANCZOS)

    tile = Image.new("RGB", (width * 3, height + 28), "#f3f1ea")
    tile.paste(original.convert("RGB"), (0, 0))
    tile.paste(overlay.convert("RGB"), (width, 0))
    tile.paste(cutout_tile.convert("RGB"), (width * 2, 0))
    draw = ImageDraw.Draw(tile)
    draw.text((8, height + 8), title[:120], fill="#1b1a17")
    return tile


def _build_candidate(
    rendered: Image.Image,
    base: Image.Image | None,
    *,
    context: ItemContext,
    prompt: str,
    profile: SemanticProfile,
    device: str,
    feather: bool,
    aggressive: bool,
) -> CutoutResult | None:
    width, height = rendered.size
    roi_box = (
        0,
        max(0, min(height - 1, int(round(height * profile.roi_top_ratio)))),
        width,
        max(1, min(height, int(round(height * profile.roi_bottom_ratio)))),
    )
    if roi_box[1] >= roi_box[3]:
        return None

    diff_map = _difference_map(rendered, base)
    seed_mask = _threshold_mask(diff_map, roi_box, profile.seed_percentile)
    grow_mask = _threshold_mask(diff_map, roi_box, profile.grow_percentile)
    seed_components = _connected_components(seed_mask)
    selected_seeds = _select_seed_components(
        seed_components,
        diff_map=diff_map,
        category=context.category,
        roi_box=roi_box,
        profile=profile,
    )
    if not selected_seeds:
        return None

    grown = _grow_from_components(selected_seeds, grow_mask)
    expansion_seeds = selected_seeds
    expansion_grown = grown
    if aggressive and _normalize_category(context.category) == "headwear" and selected_seeds:
        expansion_seeds = [selected_seeds[0]]
        expansion_grown = _grow_from_components(expansion_seeds, grow_mask)
    diff_roi_box = _diff_tight_roi_box(
        diff_map,
        base_roi=roi_box,
        category=context.category,
        profile=profile,
    )
    candidate_masks: list[tuple[Image.Image, tuple[int, int, int, int], dict[str, Any]]] = [
        (
            grown,
            roi_box,
            {
                "candidate_source": "diff-only",
                "fusion_mode": "diff_only",
                "native_confidence": 0.0,
                "aggressive_mode": aggressive,
            },
        )
    ]
    aggressive_seed_box = None
    aggressive_diff: Image.Image | None = None
    if aggressive:
        aggressive_seed_box = _seed_expansion_box(
            seed_components=expansion_seeds,
            roi_box=roi_box,
            category=context.category,
            image_size=rendered.size,
        )
        aggressive_diff = _clip_mask_to_roi(
            _expand_mask(
                expansion_grown,
                12 if _normalize_category(context.category) == "headwear" else 16,
            ),
            aggressive_seed_box or roi_box,
        )
        if aggressive_diff.getbbox() is not None:
            candidate_masks.append(
                (
                    aggressive_diff,
                    roi_box,
                    {
                        "candidate_source": "diff-expanded",
                        "fusion_mode": "diff_expanded",
                        "native_confidence": 0.0,
                        "aggressive_mode": True,
                    },
                )
            )
        if _normalize_category(context.category) == "headwear":
            headwear_box = _headwear_aggressive_box(
                seed_components=expansion_seeds,
                roi_box=roi_box,
                image_size=rendered.size,
            )
            broad_headwear_box = _headwear_aggressive_box(
                seed_components=selected_seeds,
                roi_box=roi_box,
                image_size=rendered.size,
            )
            if broad_headwear_box is not None:
                candidate_masks.append(
                    (
                        _clip_mask_to_roi(_expand_mask(grown, 22), broad_headwear_box),
                        roi_box,
                        {
                            "candidate_source": "headwear-overfill",
                            "fusion_mode": "overfill",
                            "native_confidence": 0.0,
                            "aggressive_mode": True,
                        },
                    )
                )
            if headwear_box is not None:
                cap_box_mask = _box_mask(rendered.size, headwear_box)
                ellipse_mask = _ellipse_mask(rendered.size, headwear_box)
                candidate_masks.append(
                    (
                        cap_box_mask,
                        roi_box,
                        {
                            "candidate_source": "headwear-cap-box",
                            "fusion_mode": "cap_box",
                            "native_confidence": 0.0,
                            "aggressive_mode": True,
                        },
                    )
                )
                candidate_masks.append(
                    (
                        ellipse_mask,
                        roi_box,
                        {
                            "candidate_source": "headwear-halo-ellipse",
                            "fusion_mode": "halo_ellipse",
                            "native_confidence": 0.0,
                            "aggressive_mode": True,
                        },
                    )
                )
                if aggressive_diff is not None:
                    candidate_masks.append(
                        (
                            _binary_union(ellipse_mask, aggressive_diff),
                            roi_box,
                            {
                                "candidate_source": "headwear-halo",
                                "fusion_mode": "halo_union",
                                "native_confidence": 0.0,
                                "aggressive_mode": True,
                            },
                        )
                    )

    seen_roi_keys = {roi_box}
    roi_candidates = [(roi_box, "roi-grounded")]
    if diff_roi_box is not None and diff_roi_box not in seen_roi_keys:
        roi_candidates.append((diff_roi_box, "diff-tight-grounded"))
        seen_roi_keys.add(diff_roi_box)

    max_native_masks = 6 if _normalize_category(context.category) == "shoes" else 3
    for candidate_roi, roi_label in roi_candidates:
        sam_candidates = segment(
            rendered,
            prompt,
            candidate_roi,
            device=device,
            category=context.category,
            detector_image=rendered,
            base_image=base,
        )
        pairable_candidates: list[SegmentCandidate] = []
        seen_detected_boxes: set[tuple[int, int, int, int]] = set()
        if _normalize_category(context.category) == "shoes":
            for sam_candidate in sam_candidates:
                detected_box = sam_candidate.metadata.get("detected_box")
                detected_key = tuple(
                    int(round(float(value))) for value in (detected_box or [])[:4]
                )
                if len(detected_key) == 4 and detected_key in seen_detected_boxes:
                    continue
                if len(detected_key) == 4:
                    seen_detected_boxes.add(detected_key)
                pairable_candidates.append(sam_candidate)
                if len(pairable_candidates) >= 2:
                    break
        used_native_masks = 0
        for sam_candidate in sam_candidates:
            if used_native_masks >= max_native_masks:
                break

            native_box = _offset_box_to_canvas(sam_candidate.metadata.get("box"), candidate_roi)
            detected_box = _offset_box_to_canvas(
                sam_candidate.metadata.get("detected_box"),
                candidate_roi,
            )
            native_confidence = float(sam_candidate.confidence)
            base_meta = {
                "candidate_source": roi_label,
                "native_box": native_box,
                "detected_box": detected_box,
                "native_confidence": native_confidence,
                "detector_score": float(sam_candidate.metadata.get("detector_score", 0.0)),
                "sam_iou": float(sam_candidate.metadata.get("sam_iou", 0.0)),
                "box_variant": str(sam_candidate.metadata.get("box_variant", "original")),
                "roi_box": list(candidate_roi),
                "aggressive_mode": aggressive,
            }

            raw_variants = [
                ("intersection", _binary_intersection(grown, sam_candidate.mask)),
                ("sam_only_clipped", _clip_mask_to_roi(sam_candidate.mask, candidate_roi)),
                (
                    "seed_supported_union",
                    _clip_mask_to_roi(
                        _binary_union(
                            grown,
                            _binary_intersection(
                                sam_candidate.mask,
                                _expand_mask(
                                    grown,
                                    6 if _normalize_category(context.category) == "headwear" else 8,
                                ),
                            ),
                        ),
                        candidate_roi,
                    ),
                ),
                (
                    "union",
                    _clip_mask_to_roi(_binary_union(grown, sam_candidate.mask), candidate_roi),
                ),
            ]
            if aggressive:
                raw_variants.append(
                    (
                        "aggressive_union",
                        _clip_mask_to_roi(
                            _binary_union(
                                _expand_mask(
                                    grown,
                                    10
                                    if _normalize_category(context.category) == "headwear"
                                    else 16,
                                ),
                                _expand_mask(
                                    sam_candidate.mask,
                                    5
                                    if _normalize_category(context.category) == "headwear"
                                    else 8,
                                ),
                            ),
                            _intersect_roi_boxes(candidate_roi, aggressive_seed_box) or candidate_roi,
                        ),
                    )
                )
            for fusion_mode, raw_mask in raw_variants:
                if raw_mask.getbbox() is None:
                    continue
                variant_meta = dict(base_meta)
                variant_meta["fusion_mode"] = fusion_mode
                if variant_meta["box_variant"] != "original":
                    variant_meta["candidate_source"] = "expanded-box"
                candidate_masks.append((raw_mask, candidate_roi, variant_meta))
            used_native_masks += 1
        if roi_label == "roi-grounded" and len(pairable_candidates) >= 2:
            pair_mask = _binary_union(pairable_candidates[0].mask, pairable_candidates[1].mask)
            pair_bbox = pair_mask.getbbox()
            if pair_bbox is not None:
                pair_confidence = (
                    float(pairable_candidates[0].confidence)
                    + float(pairable_candidates[1].confidence)
                ) / 2.0
                pair_meta = {
                    "candidate_source": "fused",
                    "native_box": [float(value) for value in pair_bbox],
                    "detected_box": _merged_detected_box(pairable_candidates, candidate_roi),
                    "native_confidence": pair_confidence,
                    "detector_score": (
                        float(pairable_candidates[0].metadata.get("detector_score", 0.0))
                        + float(pairable_candidates[1].metadata.get("detector_score", 0.0))
                    )
                    / 2.0,
                    "sam_iou": (
                        float(pairable_candidates[0].metadata.get("sam_iou", 0.0))
                        + float(pairable_candidates[1].metadata.get("sam_iou", 0.0))
                    )
                    / 2.0,
                    "box_variant": "paired",
                    "roi_box": list(candidate_roi),
                    "paired_count": 2,
                }
                paired_variants = [
                    ("intersection", _binary_intersection(grown, pair_mask)),
                    ("sam_only_clipped", _clip_mask_to_roi(pair_mask, candidate_roi)),
                    (
                        "seed_supported_union",
                        _clip_mask_to_roi(
                            _binary_union(
                                grown,
                                _binary_intersection(
                                    pair_mask,
                                    _expand_mask(
                                        grown,
                                        8,
                                    ),
                                ),
                            ),
                            candidate_roi,
                        ),
                    ),
                    (
                        "union",
                        _clip_mask_to_roi(_binary_union(grown, pair_mask), candidate_roi),
                    ),
                ]
                for fusion_mode, raw_mask in paired_variants:
                    if raw_mask.getbbox() is None:
                        continue
                    variant_meta = dict(pair_meta)
                    variant_meta["fusion_mode"] = fusion_mode
                    candidate_masks.append((raw_mask, candidate_roi, variant_meta))

    best_result: CutoutResult | None = None
    best_aggressive_headwear_result: CutoutResult | None = None
    for raw_mask, candidate_roi, candidate_meta in candidate_masks:
        result = _finalize_candidate_variant(
            rendered=rendered,
            raw_mask=raw_mask,
            context=context,
            prompt=prompt,
            profile=profile,
            seed_components=selected_seeds,
            roi_box=candidate_roi,
            diff_map=diff_map,
            diff_support_mask=grown,
            feather=feather,
            candidate_meta=candidate_meta,
        )
        if result is None:
            continue
        if aggressive and _normalize_category(context.category) == "headwear":
            source = str(result.metrics.get("candidate_source") or "")
            coverage = float(result.metrics.get("coverage", 0.0))
            bbox_bottom = float(result.metrics.get("bbox_bottom_ratio", 0.0))
            if (
                source != "diff-only"
                and coverage >= 0.010
                and bbox_bottom <= 0.28
                and (
                    best_aggressive_headwear_result is None
                    or result.score > best_aggressive_headwear_result.score
                )
            ):
                best_aggressive_headwear_result = result
        if best_result is None or result.score > best_result.score:
            best_result = result
    if (
        aggressive
        and _normalize_category(context.category) == "headwear"
        and best_result is not None
        and best_aggressive_headwear_result is not None
        and str(best_result.metrics.get("candidate_source") or "") == "diff-only"
    ):
        best_coverage = float(best_result.metrics.get("coverage", 0.0))
        alt_coverage = float(best_aggressive_headwear_result.metrics.get("coverage", 0.0))
        if (
            best_aggressive_headwear_result.score >= best_result.score - 2.2
            or alt_coverage >= max(0.012, best_coverage * 1.45)
        ):
            return best_aggressive_headwear_result
    if (
        aggressive
        and _normalize_category(context.category) == "headwear"
        and best_result is not None
        and str(best_result.metrics.get("candidate_source") or "") in {"diff-only", "diff-expanded"}
    ):
        best_coverage = float(best_result.metrics.get("coverage", 0.0))
        best_bbox_width = float(best_result.metrics.get("bbox_width_ratio", 0.0))
        if (
            str(best_result.metrics.get("candidate_source") or "") != "diff-only"
            and best_coverage >= 0.012
            and best_bbox_width >= 0.16
        ):
            return best_result
        promoted_box = _headwear_aggressive_box(
            seed_components=selected_seeds,
            roi_box=roi_box,
            image_size=rendered.size,
        )
        promoted_raw = _clip_mask_to_roi(
            _expand_mask(grown, 20),
            promoted_box or roi_box,
        )
        promoted = _finalize_candidate_variant(
            rendered=rendered,
            raw_mask=promoted_raw,
            context=context,
            prompt=best_result.prompt,
            profile=profile,
            seed_components=selected_seeds,
            roi_box=roi_box,
            diff_map=diff_map,
            diff_support_mask=grown,
            feather=feather,
            candidate_meta={
                "candidate_source": "headwear-promoted",
                "fusion_mode": "forced_promote",
                "native_confidence": 0.0,
                "aggressive_mode": True,
            },
        )
        if promoted is not None:
            promoted_coverage = float(promoted.metrics.get("coverage", 0.0))
            if (
                promoted.score >= best_result.score - 2.8
                or promoted_coverage >= max(0.012, best_coverage * 1.55)
            ):
                return promoted
    return best_result


def _finalize_candidate_variant(
    *,
    rendered: Image.Image,
    raw_mask: Image.Image,
    context: ItemContext,
    prompt: str,
    profile: SemanticProfile,
    seed_components: list[dict[str, Any]],
    roi_box: tuple[int, int, int, int],
    diff_map: list[int],
    diff_support_mask: Image.Image,
    feather: bool,
    candidate_meta: dict[str, Any],
) -> CutoutResult | None:
    clipped = _clip_mask_to_roi(raw_mask, roi_box)
    clipped = _apply_vertical_guardrail(
        clipped,
        category=context.category,
        profile=profile,
        seed_components=seed_components,
        candidate_meta=candidate_meta,
    )
    clipped = _subtract_forbidden_regions(
        rendered,
        clipped,
        category=context.category,
        profile=profile,
        roi_box=roi_box,
        candidate_meta=candidate_meta,
    )
    clipped = _tighten_headwear_to_detection(clipped, context.category, candidate_meta)
    clipped = _tighten_shoes_to_detection(clipped, context.category, candidate_meta)
    final_mask = postprocess(
        clipped,
        close_radius=profile.close_radius,
        open_radius=profile.open_radius,
        min_area_px=max(48, profile.min_seed_area_px // 2),
        max_components=(
            1
            if _normalize_category(context.category) == "headwear"
            and bool(candidate_meta.get("aggressive_mode", False))
            and str(candidate_meta.get("candidate_source") or "") in {"diff-only", "diff-expanded"}
            else profile.keep_final_components
        ),
    )
    expand_radius = _native_expand_radius(context.category, candidate_meta)
    if expand_radius > 0:
        final_mask = _expand_mask(final_mask, expand_radius)
        final_mask = _clip_mask_to_roi(final_mask, roi_box)
        final_mask = _subtract_forbidden_regions(
            rendered,
            final_mask,
            category=context.category,
            profile=profile,
            roi_box=roi_box,
        )
        final_mask = postprocess(
            final_mask,
            close_radius=max(1, profile.close_radius - 1),
            open_radius=0,
            min_area_px=max(48, profile.min_seed_area_px // 2),
            max_components=(
                1
                if _normalize_category(context.category) == "headwear"
                and bool(candidate_meta.get("aggressive_mode", False))
                and str(candidate_meta.get("candidate_source") or "") in {"diff-only", "diff-expanded"}
                else profile.keep_final_components
            ),
        )
    bbox = final_mask.getbbox()
    if bbox is None:
        return None

    metrics = _mask_metrics(
        final_mask,
        rendered=rendered,
        diff_map=diff_map,
        category=context.category,
        roi_box=roi_box,
        profile=profile,
        prompt=prompt,
        diff_support_mask=diff_support_mask,
        candidate_meta=candidate_meta,
    )
    if _reject_candidate(metrics):
        return None

    score = _score_metrics(metrics)
    if score <= -5.0:
        return None
    metrics["score"] = round(score, 4)

    cutout = cutout_png(rendered, final_mask, feather=feather)
    return CutoutResult(
        anchor=_anchor_from_bbox(rendered.size, bbox),
        bbox=bbox,
        prompt=prompt,
        score=score,
        metrics=metrics,
        mask=final_mask,
        cutout=cutout,
    )


def _native_expand_radius(category: str, candidate_meta: dict[str, Any]) -> int:
    if float(candidate_meta.get("native_confidence", 0.0)) <= 0.0:
        return 0
    normalized_category = _normalize_category(category)
    fusion_mode = str(candidate_meta.get("fusion_mode") or "")
    box_variant = str(candidate_meta.get("box_variant") or "")
    aggressive_mode = bool(candidate_meta.get("aggressive_mode", False))
    radius = 4 if aggressive_mode and normalized_category == "headwear" else 2
    if normalized_category == "shoes":
        radius = 3 if aggressive_mode else 1
    if fusion_mode == "intersection":
        radius += 2 if aggressive_mode else 1
    elif fusion_mode in {"union", "aggressive_union"}:
        radius += 1
    if box_variant == "expanded":
        radius += 2 if aggressive_mode else 1
    return min(8 if aggressive_mode else 4, radius)


def _tighten_headwear_to_detection(
    mask: Image.Image,
    category: str,
    candidate_meta: dict[str, Any],
) -> Image.Image:
    if _normalize_category(category) != "headwear":
        return mask
    if float(candidate_meta.get("native_confidence", 0.0)) <= 0.0:
        return mask

    source_box = candidate_meta.get("detected_box") or candidate_meta.get("native_box")
    if not isinstance(source_box, list) or len(source_box) < 4:
        return mask

    width, height = mask.size
    left, top, right, bottom = [float(value) for value in source_box[:4]]
    box_width = max(1.0, right - left)
    box_height = max(1.0, bottom - top)
    aggressive_mode = bool(candidate_meta.get("aggressive_mode", False))
    tightened_box = (
        max(0, int(math.floor(left - box_width * (0.14 if aggressive_mode else 0.08)))),
        max(0, int(math.floor(top - box_height * (0.08 if aggressive_mode else 0.04)))),
        min(width, int(math.ceil(right + box_width * (0.14 if aggressive_mode else 0.08)))),
        min(height, int(math.ceil(bottom + box_height * (0.22 if aggressive_mode else 0.14)))),
    )
    return _clip_mask_to_roi(mask, tightened_box)


def _tighten_shoes_to_detection(
    mask: Image.Image,
    category: str,
    candidate_meta: dict[str, Any],
) -> Image.Image:
    if _normalize_category(category) != "shoes":
        return mask
    if float(candidate_meta.get("native_confidence", 0.0)) <= 0.0:
        return mask

    source_box = candidate_meta.get("detected_box") or candidate_meta.get("native_box")
    if not isinstance(source_box, list) or len(source_box) < 4:
        return mask

    width, height = mask.size
    left, top, right, bottom = [float(value) for value in source_box[:4]]
    box_width = max(1.0, right - left)
    box_height = max(1.0, bottom - top)
    aggressive_mode = bool(candidate_meta.get("aggressive_mode", False))
    top_offset_ratio = (
        0.08 if aggressive_mode and int(candidate_meta.get("paired_count", 0) or 0) >= 2
        else (0.12 if int(candidate_meta.get("paired_count", 0) or 0) >= 2 else 0.04)
    )
    tightened_box = (
        max(0, int(math.floor(left - box_width * (0.14 if aggressive_mode else 0.08)))),
        max(0, int(math.floor(top + box_height * top_offset_ratio))),
        min(width, int(math.ceil(right + box_width * (0.14 if aggressive_mode else 0.08)))),
        min(height, int(math.ceil(bottom + box_height * (0.26 if aggressive_mode else 0.18)))),
    )
    return _clip_mask_to_roi(mask, tightened_box)


def _diff_tight_roi_box(
    diff_map: list[int],
    *,
    base_roi: tuple[int, int, int, int],
    category: str,
    profile: SemanticProfile,
) -> tuple[int, int, int, int] | None:
    if not diff_map:
        return None

    width = base_roi[2] - base_roi[0]
    height = max(1, base_roi[3] - base_roi[1])
    strong_percentile = min(99.8, profile.seed_percentile + 0.35)
    strong_mask = _threshold_mask(diff_map, base_roi, strong_percentile)
    components = _connected_components(strong_mask)
    selected = _select_seed_components(
        components,
        diff_map=diff_map,
        category=category,
        roi_box=base_roi,
        profile=profile,
    )
    if not selected:
        return None

    left = min(int(component["bbox"][0]) for component in selected)
    top = min(int(component["bbox"][1]) for component in selected)
    right = max(int(component["bbox"][2]) for component in selected)
    bottom = max(int(component["bbox"][3]) for component in selected)
    margin_x = max(12, width // (8 if _normalize_category(category) == "headwear" else 10))
    margin_y = max(10, height // (6 if _normalize_category(category) == "headwear" else 8))
    if _normalize_category(category) == "headwear":
        margin_y = max(8, margin_y // 2)
    else:
        top = max(base_roi[1], top - max(6, margin_y // 2))
    candidate = (
        max(base_roi[0], left - margin_x),
        max(base_roi[1], top - margin_y),
        min(base_roi[2], right + margin_x),
        min(base_roi[3], bottom + margin_y),
    )
    if candidate[2] - candidate[0] < 20 or candidate[3] - candidate[1] < 20:
        return None
    return candidate if candidate != base_roi else None


def _seed_expansion_box(
    *,
    seed_components: list[dict[str, Any]],
    roi_box: tuple[int, int, int, int],
    category: str,
    image_size: tuple[int, int],
) -> tuple[int, int, int, int] | None:
    if not seed_components:
        return None

    width, height = image_size
    left = min(int(component["bbox"][0]) for component in seed_components)
    top = min(int(component["bbox"][1]) for component in seed_components)
    right = max(int(component["bbox"][2]) for component in seed_components)
    bottom = max(int(component["bbox"][3]) for component in seed_components)
    span_w = max(1, right - left)
    span_h = max(1, bottom - top)
    normalized_category = _normalize_category(category)

    if normalized_category == "headwear":
        margin_left = max(30, int(round(span_w * 0.38)))
        margin_right = margin_left
        margin_top = max(18, int(round(span_h * 0.32)))
        margin_bottom = max(14, int(round(span_h * 0.38)))
    else:
        margin_left = max(20, int(round(span_w * 0.16)))
        margin_right = margin_left
        margin_top = max(6, int(round(span_h * 0.06)))
        margin_bottom = max(18, int(round(span_h * 0.22)))

    candidate = (
        max(roi_box[0], max(0, left - margin_left)),
        max(roi_box[1], max(0, top - margin_top)),
        min(roi_box[2], min(width, right + margin_right)),
        min(roi_box[3], min(height, bottom + margin_bottom)),
    )
    if candidate[2] - candidate[0] < 20 or candidate[3] - candidate[1] < 20:
        return None
    return candidate


def _headwear_aggressive_box(
    *,
    seed_components: list[dict[str, Any]],
    roi_box: tuple[int, int, int, int],
    image_size: tuple[int, int],
) -> tuple[int, int, int, int] | None:
    if not seed_components:
        return None

    width, height = image_size
    roi_height = max(1, roi_box[3] - roi_box[1])
    left = min(int(component["bbox"][0]) for component in seed_components)
    top = min(int(component["bbox"][1]) for component in seed_components)
    right = max(int(component["bbox"][2]) for component in seed_components)
    bottom = max(int(component["bbox"][3]) for component in seed_components)
    span_w = max(1, right - left)
    span_h = max(1, bottom - top)
    margin_x = max(34, int(round(span_w * 0.85)))
    margin_top = max(18, int(round(span_h * 0.55)))
    margin_bottom = max(28, int(round(span_h * 1.25)))
    candidate = (
        max(roi_box[0], max(0, left - margin_x)),
        max(roi_box[1], max(0, top - margin_top)),
        min(roi_box[2], min(width, right + margin_x)),
        min(
            roi_box[3],
            min(height, max(bottom + margin_bottom, top + max(44, int(round(roi_height * 0.34))))),
        ),
    )
    if candidate[2] - candidate[0] < 20 or candidate[3] - candidate[1] < 20:
        return None
    return candidate


def _intersect_roi_boxes(
    first: tuple[int, int, int, int],
    second: tuple[int, int, int, int] | None,
) -> tuple[int, int, int, int] | None:
    if second is None:
        return None
    candidate = (
        max(first[0], second[0]),
        max(first[1], second[1]),
        min(first[2], second[2]),
        min(first[3], second[3]),
    )
    if candidate[2] - candidate[0] < 4 or candidate[3] - candidate[1] < 4:
        return None
    return candidate


def _box_mask(
    size: tuple[int, int],
    box: tuple[int, int, int, int],
) -> Image.Image:
    mask = Image.new("L", size, _MASK_BLACK)
    left, top, right, bottom = box
    mask.paste(_MASK_WHITE, (left, top, right, bottom))
    return mask


def _ellipse_mask(
    size: tuple[int, int],
    box: tuple[int, int, int, int],
) -> Image.Image:
    mask = Image.new("L", size, _MASK_BLACK)
    draw = ImageDraw.Draw(mask)
    left, top, right, bottom = box
    draw.ellipse((left, top, right, bottom), fill=_MASK_WHITE)
    return mask


def _region_mask(
    size: tuple[int, int],
    roi_box: tuple[int, int, int, int],
) -> Image.Image:
    mask = Image.new("L", size, _MASK_BLACK)
    left, top, right, bottom = roi_box
    mask.paste(_MASK_WHITE, (left, top, right, bottom))
    return mask


def _clip_mask_to_roi(mask: Image.Image, roi_box: tuple[int, int, int, int]) -> Image.Image:
    return _binary_intersection(mask, _region_mask(mask.size, roi_box))


def _offset_box_to_canvas(
    box: Any,
    roi_box: tuple[int, int, int, int],
) -> list[float] | None:
    if not isinstance(box, list) or len(box) < 4:
        return None
    offset_x = float(roi_box[0])
    offset_y = float(roi_box[1])
    return [
        round(float(box[0]) + offset_x, 4),
        round(float(box[1]) + offset_y, 4),
        round(float(box[2]) + offset_x, 4),
        round(float(box[3]) + offset_y, 4),
    ]


def _merged_detected_box(
    candidates: list[SegmentCandidate],
    roi_box: tuple[int, int, int, int],
) -> list[float] | None:
    boxes = [
        _offset_box_to_canvas(candidate.metadata.get("detected_box"), roi_box)
        for candidate in candidates
    ]
    valid = [box for box in boxes if isinstance(box, list) and len(box) >= 4]
    if not valid:
        return None
    return [
        round(min(float(box[0]) for box in valid), 4),
        round(min(float(box[1]) for box in valid), 4),
        round(max(float(box[2]) for box in valid), 4),
        round(max(float(box[3]) for box in valid), 4),
    ]


def _profile_for_prompt(
    context: ItemContext,
    *,
    prompt: str,
    pose_neck_y: float | None,
    pose_ankle_y: float | None,
    image_size: tuple[int, int],
) -> SemanticProfile:
    category = _normalize_category(context.category)
    prompt_lc = prompt.lower()

    if category == "headwear":
        roi_bottom = 0.50
        if pose_neck_y is not None:
            roi_bottom = max(0.40, min(0.55, float(pose_neck_y) + 0.08))
        max_vertical = 0.11
        if "cap" in prompt_lc:
            roi_bottom = min(roi_bottom, 0.44)
            max_vertical = 0.09
        elif "beanie" in prompt_lc or "knit" in prompt_lc:
            roi_bottom = min(0.52, roi_bottom + 0.02)
            max_vertical = 0.10
        elif "bucket" in prompt_lc or "santa" in prompt_lc:
            max_vertical = 0.12
        strict_only = "only" in prompt_lc
        return SemanticProfile(
            label="headwear",
            roi_top_ratio=0.0,
            roi_bottom_ratio=roi_bottom,
            seed_percentile=99.2,
            grow_percentile=96.5 if strict_only else 95.7,
            min_seed_area_px=max(120, image_size[0] // 7),
            close_radius=2,
            open_radius=1,
            max_vertical_ratio=max_vertical,
            keep_seed_components=3,
            keep_final_components=2,
            skin_margin_px=7 if strict_only else 5,
            strict_only=strict_only,
        )

    roi_top = 0.60
    if pose_ankle_y is not None:
        roi_top = max(0.52, min(0.82, float(pose_ankle_y) - 0.18))
    max_vertical = 0.17
    seed_percentile = 98.9
    grow_percentile = 94.8
    if "boot" in prompt_lc:
        roi_top = max(0.50, roi_top - 0.04)
        max_vertical = 0.22
        seed_percentile = 98.6
    elif "slipper" in prompt_lc or "flip" in prompt_lc or "sandal" in prompt_lc:
        roi_top = min(0.78, roi_top + 0.03)
        max_vertical = 0.12
        seed_percentile = 97.6
        grow_percentile = 92.4
    strict_only = "only" in prompt_lc
    if strict_only:
        grow_percentile += 1.0
    return SemanticProfile(
        label="shoes",
        roi_top_ratio=roi_top,
        roi_bottom_ratio=1.0,
        seed_percentile=seed_percentile,
        grow_percentile=grow_percentile,
        min_seed_area_px=max(140, image_size[0] // 8),
        close_radius=2,
        open_radius=1,
        max_vertical_ratio=max_vertical,
        keep_seed_components=2,
        keep_final_components=2,
        skin_margin_px=6 if strict_only else 4,
        strict_only=strict_only,
    )


def _difference_map(rendered: Image.Image, base: Image.Image | None) -> list[int]:
    if base is not None:
        if base.size != rendered.size:
            base = base.resize(rendered.size, Image.BILINEAR)
        diff_rgb = ImageChops.difference(rendered.convert("RGB"), base.convert("RGB"))
        gray = diff_rgb.convert("L").filter(ImageFilter.GaussianBlur(radius=0.9))
        values = _channel_data(gray)
        boosted: list[int] = []
        rgb_stats = ImageStat.Stat(diff_rgb)
        baseline = sum(float(v) for v in rgb_stats.mean) / 3.0
        for value in values:
            adjusted = max(0.0, float(value) - (baseline * 0.45))
            boosted.append(int(max(0.0, min(255.0, adjusted * 1.8))))
        return boosted

    return _background_distance_map(rendered)


def _background_distance_map(image: Image.Image) -> list[int]:
    rgb = image.convert("RGB")
    width, height = rgb.size
    pixels = _pixel_data(rgb)
    border: list[tuple[int, int, int]] = []
    margin_x = max(8, width // 18)
    margin_y = max(8, height // 18)
    for y in range(height):
        row = y * width
        for x in range(width):
            if x < margin_x or x >= width - margin_x or y < margin_y or y >= height - margin_y:
                border.append(pixels[row + x])
    if not border:
        border = pixels[: min(len(pixels), 1024)]

    ref_r = _median([value[0] for value in border])
    ref_g = _median([value[1] for value in border])
    ref_b = _median([value[2] for value in border])

    distances: list[int] = []
    for r, g, b in pixels:
        delta = abs(r - ref_r) + abs(g - ref_g) + abs(b - ref_b)
        distances.append(min(255, int(round(delta / 3.0))))
    return distances


def _threshold_mask(
    diff_map: list[int],
    roi_box: tuple[int, int, int, int],
    percentile: float,
) -> Image.Image:
    left, top, right, bottom = roi_box
    width = right - left
    if width <= 0 or bottom <= top:
        return Image.new("L", (right, bottom), _MASK_BLACK)

    full_width = right
    full_height = max(bottom, 1)
    if len(diff_map) >= full_width * full_height:
        pass

    values: list[int] = []
    image_width = right
    image_height = len(diff_map) // max(1, image_width)
    if image_height <= 0:
        return Image.new("L", (full_width, full_height), _MASK_BLACK)

    for y in range(top, min(bottom, image_height)):
        row = y * image_width
        values.extend(diff_map[row + left : row + min(right, image_width)])
    if not values:
        return Image.new("L", (image_width, image_height), _MASK_BLACK)

    threshold = max(12.0, _percentile(values, percentile))
    if percentile >= 98.5:
        threshold = max(threshold, 28.0)
    else:
        threshold = max(threshold, 18.0)

    out = Image.new("L", (image_width, image_height), _MASK_BLACK)
    out_data = [_MASK_BLACK] * (image_width * image_height)
    for y in range(top, min(bottom, image_height)):
        row = y * image_width
        for x in range(left, min(right, image_width)):
            if diff_map[row + x] >= threshold:
                out_data[row + x] = _MASK_WHITE
    out.putdata(out_data)
    return out


def _select_seed_components(
    components: list[dict[str, Any]],
    *,
    diff_map: list[int],
    category: str,
    roi_box: tuple[int, int, int, int],
    profile: SemanticProfile,
) -> list[dict[str, Any]]:
    if not components:
        return []

    left, top, right, bottom = roi_box
    width = right
    height = len(diff_map) // max(1, width)
    category_lc = _normalize_category(category)

    scored: list[tuple[float, dict[str, Any]]] = []
    for component in components:
        area = int(component["area"])
        if area < profile.min_seed_area_px:
            continue
        bbox = component["bbox"]
        centroid_x, centroid_y = component["centroid"]
        bbox_left, bbox_top, bbox_right, bbox_bottom = bbox
        bbox_area = max(1, (bbox_right - bbox_left) * (bbox_bottom - bbox_top))
        compactness = area / bbox_area
        mean_strength = _component_mean(component, diff_map, width)
        if category_lc == "headwear":
            zone_target = (top + bottom) / 2.2
            y_distance = abs(centroid_y - zone_target) / max(1.0, bottom - top)
            x_distance = abs(centroid_x - (width / 2.0)) / max(1.0, width / 2.0)
            score = (mean_strength / 255.0) * 6.0 + compactness * 3.0 - y_distance * 4.0 - x_distance * 1.4
            if bbox_bottom > bottom:
                score -= 4.0
        else:
            zone_target = max(top, height * 0.90)
            y_distance = abs(centroid_y - zone_target) / max(1.0, height - top)
            bottom_gap = max(0.0, height - bbox_bottom) / max(1.0, height - top)
            width_ratio = (bbox_right - bbox_left) / max(1.0, width)
            floor_bonus = 1.0 - bottom_gap
            width_weight = 4.0 if profile.max_vertical_ratio <= 0.12 else 3.0
            score = (
                (mean_strength / 255.0) * 3.2
                + compactness * 1.4
                + floor_bonus * 4.8
                + width_ratio * width_weight
                - y_distance * 1.6
            )
            if bbox_top < top:
                score -= 3.5
            if bbox_bottom < int(height * 0.82):
                score -= 2.5
        scored.append((score, component))

    if not scored:
        return []

    scored.sort(key=lambda item: item[0], reverse=True)
    if category_lc == "headwear":
        selected = [scored[0][1]]
        seed_bbox = scored[0][1]["bbox"]
        for _, component in scored[1:]:
            if len(selected) >= profile.keep_seed_components:
                break
            if _bbox_distance(seed_bbox, component["bbox"]) <= 48:
                selected.append(component)
        return selected

    mid_x = width / 2.0
    left_best = None
    right_best = None
    for _, component in scored:
        centroid_x, _ = component["centroid"]
        if centroid_x < mid_x and left_best is None:
            left_best = component
        if centroid_x >= mid_x and right_best is None:
            right_best = component
        if left_best is not None and right_best is not None:
            break
    selected_components = [component for component in (left_best, right_best) if component is not None]
    if not selected_components:
        selected_components = [scored[0][1]]
    if len(selected_components) == 1:
        primary = selected_components[0]
        primary_cx, _ = primary["centroid"]
        for _, component in scored:
            if component is primary:
                continue
            component_cx, _ = component["centroid"]
            if (
                _bbox_distance(primary["bbox"], component["bbox"]) >= 20
                or abs(component_cx - primary_cx) >= width * 0.08
            ):
                selected_components.append(component)
                break
    return selected_components[: profile.keep_seed_components]


def _grow_from_components(
    components: list[dict[str, Any]],
    grow_mask: Image.Image,
) -> Image.Image:
    allowed = [1 if value else 0 for value in _channel_data(grow_mask)]
    width, height = grow_mask.size
    visited = bytearray(width * height)
    stack: list[int] = []
    for component in components:
        for index in component["pixels"]:
            if 0 <= index < len(allowed):
                stack.append(index)

    output = [_MASK_BLACK] * (width * height)
    while stack:
        current = stack.pop()
        if current < 0 or current >= len(allowed):
            continue
        if visited[current]:
            continue
        visited[current] = 1
        if not allowed[current]:
            continue
        output[current] = _MASK_WHITE
        x = current % width
        y = current // width
        for next_index in _neighbors8(current, x, y, width, height):
            if not visited[next_index]:
                stack.append(next_index)

    mask = Image.new("L", (width, height), _MASK_BLACK)
    mask.putdata(output)
    return mask


def _apply_vertical_guardrail(
    mask: Image.Image,
    *,
    category: str,
    profile: SemanticProfile,
    seed_components: list[dict[str, Any]],
    candidate_meta: dict[str, Any] | None = None,
) -> Image.Image:
    bbox = mask.getbbox()
    if bbox is None:
        return mask

    width, height = mask.size
    left, top, right, bottom = bbox
    max_height_px = max(12, int(round(profile.max_vertical_ratio * height)))
    aggressive_mode = bool((candidate_meta or {}).get("aggressive_mode", False))
    fusion_mode = str((candidate_meta or {}).get("fusion_mode") or "")
    seed_top = min(component["bbox"][1] for component in seed_components)

    top_limit = top
    bottom_limit = bottom
    if _normalize_category(category) == "headwear":
        if aggressive_mode:
            max_height_px = int(round(max_height_px * 1.9))
            if fusion_mode in {"cap_box", "halo_ellipse", "halo_union"}:
                max_height_px = int(round(max_height_px * 1.35))
        bottom_limit = min(bottom, seed_top + max_height_px)
    else:
        top_limit = max(top, bottom - max_height_px)

    clipped = Image.new("L", (width, height), _MASK_BLACK)
    region = mask.crop((left, top_limit, right, bottom_limit))
    clipped.paste(region, (left, top_limit))
    return clipped


def _subtract_forbidden_regions(
    rendered: Image.Image,
    mask: Image.Image,
    *,
    category: str,
    profile: SemanticProfile,
    roi_box: tuple[int, int, int, int],
    candidate_meta: dict[str, Any] | None = None,
) -> Image.Image:
    normalized_category = _normalize_category(category)
    aggressive_mode = bool((candidate_meta or {}).get("aggressive_mode", False))
    candidate_source = str((candidate_meta or {}).get("candidate_source") or "")
    if (
        normalized_category == "headwear"
        and aggressive_mode
        and candidate_source in {
            "headwear-promoted",
            "headwear-overfill",
            "headwear-cap-box",
            "headwear-halo-ellipse",
            "headwear-halo",
        }
    ):
        forbidden = Image.new("L", rendered.size, _MASK_BLACK)
    else:
        forbidden = _skin_mask(rendered, roi_box=roi_box, margin_px=profile.skin_margin_px)
    normalized_category = _normalize_category(category)
    width, height = rendered.size
    if normalized_category == "headwear":
        face_band_top = max(0, min(height, int(round(profile.roi_bottom_ratio * height)) - 6))
        if aggressive_mode and candidate_source.startswith("headwear-"):
            face_band_top = max(0, min(height, int(round(height * 0.62))))
        if face_band_top < height:
            face_band = Image.new("L", (width, height), _MASK_BLACK)
            face_band.paste(_MASK_WHITE, (0, face_band_top, width, height))
            forbidden = _binary_union(forbidden, face_band)
    if normalized_category == "shoes":
        top = max(0, min(height, int(round(profile.roi_top_ratio * height))))
        cap = Image.new("L", (width, height), _MASK_BLACK)
        cap.paste(_MASK_WHITE, (0, 0, width, top))
        forbidden = _binary_union(forbidden, cap)
    return _binary_subtract(mask, forbidden)


def _mask_metrics(
    mask: Image.Image,
    *,
    rendered: Image.Image,
    diff_map: list[int],
    category: str,
    roi_box: tuple[int, int, int, int],
    profile: SemanticProfile,
    prompt: str,
    diff_support_mask: Image.Image | None = None,
    candidate_meta: dict[str, Any] | None = None,
) -> dict[str, Any]:
    bbox = mask.getbbox()
    if bbox is None:
        return {
            "score": -999.0,
            "prompt": prompt,
            "category": _normalize_category(category),
        }

    width, height = mask.size
    left, top, right, bottom = bbox
    area = sum(1 for value in _channel_data(mask) if value)
    bbox_area = max(1, (right - left) * (bottom - top))
    centroid_x, centroid_y = _mask_centroid(mask)
    strength = _mask_mean(mask, diff_map)
    forbidden_overlap = 0
    if _normalize_category(category) in {"headwear", "shoes"}:
        skin = _skin_mask(
            rendered,
            roi_box=roi_box,
            margin_px=0,
        )
        forbidden_overlap = _overlap_area(mask, skin)

    diff_overlap = 0
    diff_support_area = 0
    underseg_penalty = 0.0
    if diff_support_mask is not None:
        diff_overlap = _overlap_area(mask, diff_support_mask)
        diff_support_area = _mask_area(diff_support_mask)
        if diff_support_area > 0:
            ratio = area / max(1, diff_support_area)
            underseg_penalty = max(0.0, min(1.0, 0.58 - ratio))

    metrics = {
        "prompt": prompt,
        "category": _normalize_category(category),
        "area": area,
        "coverage": area / max(1, width * height),
        "bbox_width_ratio": (right - left) / max(1, width),
        "bbox_height_ratio": (bottom - top) / max(1, height),
        "bbox_top_ratio": top / max(1, height),
        "bbox_bottom_ratio": bottom / max(1, height),
        "compactness": area / bbox_area,
        "centroid_x_ratio": centroid_x / max(1.0, width),
        "centroid_y_ratio": centroid_y / max(1.0, height),
        "mean_strength": strength,
        "forbidden_overlap_ratio": forbidden_overlap / max(1, area),
        "diff_overlap_ratio": diff_overlap / max(1, area),
        "diff_support_fill_ratio": diff_overlap / max(1, diff_support_area),
        "underseg_penalty": underseg_penalty,
        "roi_top_ratio": profile.roi_top_ratio,
        "roi_bottom_ratio": profile.roi_bottom_ratio,
    }
    if candidate_meta:
        for key, value in candidate_meta.items():
            metrics[key] = value
    return metrics


def _score_metrics(metrics: dict[str, Any]) -> float:
    coverage = float(metrics.get("coverage", 0.0))
    compactness = float(metrics.get("compactness", 0.0))
    bbox_width = float(metrics.get("bbox_width_ratio", 0.0))
    centroid_y = float(metrics.get("centroid_y_ratio", 0.0))
    centroid_x = float(metrics.get("centroid_x_ratio", 0.5))
    mean_strength = float(metrics.get("mean_strength", 0.0))
    bbox_height = float(metrics.get("bbox_height_ratio", 0.0))
    bbox_bottom = float(metrics.get("bbox_bottom_ratio", 0.0))
    forbidden = float(metrics.get("forbidden_overlap_ratio", 0.0))
    diff_overlap = float(metrics.get("diff_overlap_ratio", 0.0))
    diff_fill = float(metrics.get("diff_support_fill_ratio", 0.0))
    underseg_penalty = float(metrics.get("underseg_penalty", 0.0))
    native_confidence = float(metrics.get("native_confidence", 0.0))
    category = str(metrics.get("category", ""))
    candidate_source = str(metrics.get("candidate_source", ""))
    fusion_mode = str(metrics.get("fusion_mode", ""))
    box_variant = str(metrics.get("box_variant", ""))
    paired_count = int(metrics.get("paired_count", 0) or 0)
    aggressive_mode = bool(metrics.get("aggressive_mode", False))

    score = (mean_strength / 255.0) * (4.2 if aggressive_mode else 4.6) + compactness * (
        3.0 if aggressive_mode else 3.5
    )
    score += diff_overlap * 4.0
    score += diff_fill * (3.0 if aggressive_mode else 2.6)
    score += native_confidence * (3.3 if aggressive_mode else 2.5)
    score -= underseg_penalty * (8.0 if aggressive_mode else 6.5)
    if category == "headwear":
        score += max(-3.0, 2.2 - abs(centroid_y - 0.09) * 18.0)
        score += max(-1.5, 1.2 - abs(centroid_x - 0.50) * 5.0)
        score -= max(0.0, bbox_height - (0.18 if aggressive_mode else 0.14)) * (
            10.0 if aggressive_mode else 18.0
        )
        if aggressive_mode and candidate_source in {
            "headwear-promoted",
            "headwear-overfill",
            "headwear-cap-box",
            "headwear-halo-ellipse",
            "headwear-halo",
        }:
            score -= forbidden * 4.0
        else:
            score -= forbidden * (8.0 if aggressive_mode else 14.0)
        min_coverage = 0.0035 if aggressive_mode else 0.0025
        if coverage < min_coverage:
            score -= (min_coverage - coverage) * (1800.0 if aggressive_mode else 1400.0)
        if aggressive_mode and 0.005 <= coverage <= 0.024:
            score += 0.85
        if aggressive_mode and 0.018 <= coverage <= 0.06:
            score += 1.25
        if coverage > (0.09 if aggressive_mode else 0.04):
            score -= (coverage - (0.09 if aggressive_mode else 0.04)) * (
                20.0 if aggressive_mode else 42.0
            )
        if bbox_width > (0.72 if aggressive_mode else 0.48):
            score -= (bbox_width - (0.72 if aggressive_mode else 0.48)) * (
                9.0 if aggressive_mode else 16.0
            )
        if fusion_mode == "sam_only_clipped":
            score += 0.05 if aggressive_mode else 0.18
        elif fusion_mode == "seed_supported_union":
            score += 0.5 if aggressive_mode else 0.26
            if box_variant == "expanded":
                score += 1.65 if aggressive_mode else 1.35
        elif fusion_mode == "union":
            score += 0.8 if aggressive_mode else 0.34
        elif fusion_mode == "aggressive_union":
            score += 1.15 if aggressive_mode else 0.2
        elif fusion_mode == "intersection":
            score -= 0.35 if aggressive_mode else 0.08
        elif fusion_mode == "diff_expanded":
            score += 0.35 if aggressive_mode else -1.2
            if aggressive_mode:
                score += 0.75
        elif fusion_mode == "cap_box":
            score += 2.0 if aggressive_mode else 0.2
        elif fusion_mode == "halo_ellipse":
            score += 2.2 if aggressive_mode else 0.2
        elif fusion_mode == "halo_union":
            score += 2.6 if aggressive_mode else 0.3
        elif fusion_mode == "overfill":
            score += 3.2 if aggressive_mode else 0.4
        elif fusion_mode == "forced_promote":
            score += 3.6 if aggressive_mode else 0.4
        if aggressive_mode and fusion_mode == "diff_expanded" and 0.15 <= bbox_bottom <= 0.24:
            score += 0.9
        if aggressive_mode and candidate_source in {
            "headwear-promoted",
            "headwear-overfill",
            "headwear-cap-box",
            "headwear-halo-ellipse",
            "headwear-halo",
        }:
            score += 1.25
            if 0.13 <= bbox_bottom <= 0.24:
                score += 0.8
        if (
            fusion_mode == "union"
            and box_variant == "expanded"
            and coverage > (0.028 if aggressive_mode else 0.015)
            and diff_overlap < (0.22 if aggressive_mode else 0.45)
        ):
            score -= ((0.22 if aggressive_mode else 0.45) - diff_overlap) * (
                5.0 if aggressive_mode else 10.0
            )
            score -= (coverage - (0.028 if aggressive_mode else 0.015)) * (
                8.0 if aggressive_mode else 28.0
            )
    else:
        score += max(-3.0, 2.0 - abs(centroid_y - 0.90) * 10.0)
        score += max(-2.0, 2.4 - abs(bbox_bottom - 0.965) * 18.0)
        score -= max(0.0, bbox_height - (0.28 if aggressive_mode else 0.24)) * (
            10.0 if aggressive_mode else 16.0
        )
        if bbox_bottom < (0.88 if aggressive_mode else 0.90):
            score -= ((0.88 if aggressive_mode else 0.90) - bbox_bottom) * (
                16.0 if aggressive_mode else 24.0
            )
        min_bbox_height = 0.10 if aggressive_mode else 0.08
        if bbox_height < min_bbox_height:
            score -= (min_bbox_height - bbox_height) * (56.0 if aggressive_mode else 40.0)
        min_coverage = 0.006 if aggressive_mode else 0.0045
        if coverage < min_coverage:
            score -= (min_coverage - coverage) * (1100.0 if aggressive_mode else 800.0)
        if aggressive_mode and 0.01 <= coverage <= 0.04:
            score += 1.0
        if coverage > (0.11 if aggressive_mode else 0.08):
            score -= (coverage - (0.11 if aggressive_mode else 0.08)) * (
                16.0 if aggressive_mode else 30.0
            )
        if fusion_mode == "sam_only_clipped":
            score += 0.0 if aggressive_mode else 0.10
        elif fusion_mode == "seed_supported_union":
            score += 0.5 if aggressive_mode else 0.14
        elif fusion_mode == "union":
            score += 0.9 if aggressive_mode else 0.18
        elif fusion_mode == "aggressive_union":
            score += 1.25 if aggressive_mode else 0.25
        elif fusion_mode == "diff_expanded":
            score += 0.25 if aggressive_mode else -1.0
        if (
            aggressive_mode
            and candidate_source != "diff-expanded"
            and native_confidence >= 0.42
            and fusion_mode in {"seed_supported_union", "union", "aggressive_union"}
        ):
            score += 0.8 + min(0.9, native_confidence * 1.1)
            if paired_count >= 2:
                score += 0.55
        if (
            aggressive_mode
            and candidate_source == "diff-expanded"
            and compactness < 0.31
            and forbidden > 0.00015
        ):
            score -= 0.8
        if paired_count >= 2:
            score += 2.6
    if candidate_source == "diff-expanded":
        score += 0.1 if aggressive_mode else -0.4
    if candidate_source == "diff-only" and native_confidence <= 0.0:
        score -= (
            0.7 if category == "headwear" else 0.45
        ) if aggressive_mode else (0.45 if category == "headwear" else 0.2)
    return score


def _reject_candidate(metrics: dict[str, Any]) -> bool:
    category = str(metrics.get("category", ""))
    aggressive_mode = bool(metrics.get("aggressive_mode", False))
    candidate_source = str(metrics.get("candidate_source", ""))
    forbidden_limit = 0.16
    if (
        aggressive_mode
        and category == "headwear"
        and candidate_source in {
            "headwear-promoted",
            "headwear-overfill",
            "headwear-cap-box",
            "headwear-halo-ellipse",
            "headwear-halo",
        }
    ):
        forbidden_limit = 0.28
    if float(metrics.get("forbidden_overlap_ratio", 0.0)) >= forbidden_limit:
        return True
    if category == "headwear" and (
        float(metrics.get("bbox_width_ratio", 0.0)) >= (0.92 if aggressive_mode else 0.65)
        or (
            float(metrics.get("coverage", 0.0)) >= (0.14 if aggressive_mode else 0.055)
            and float(metrics.get("diff_overlap_ratio", 0.0)) <= (0.04 if aggressive_mode else 0.08)
        )
    ):
        return True
    if (
        category == "headwear"
        and float(metrics.get("diff_overlap_ratio", 0.0)) <= 0.01
        and float(
        metrics.get("native_confidence", 0.0)
        ) > 0.0
    ):
        return True
    if float(metrics.get("underseg_penalty", 0.0)) >= (0.9 if aggressive_mode else 0.72):
        return True
    return False


def _write_debug_artifacts(
    *,
    debug_dir: Path,
    rendered: Image.Image,
    result: CutoutResult,
    context: ItemContext,
    rendered_path: Path,
) -> None:
    debug_dir.mkdir(parents=True, exist_ok=True)
    prefix = f"{context.category}__{context.item_id}"
    mask_path = debug_dir / f"{prefix}__mask.png"
    cutout_path = debug_dir / f"{prefix}__cutout.png"
    preview_path = debug_dir / f"{prefix}__overlay.png"
    metrics_path = debug_dir / f"{prefix}__metrics.json"

    result.mask.save(mask_path)
    result.cutout.save(cutout_path)
    _preview_overlay(rendered, result.mask).save(preview_path)
    metrics_path.write_text(
        json.dumps(
            {
                "item_id": context.item_id,
                "category": context.category,
                "source_image": str(rendered_path),
                "prompt": result.prompt,
                "score": result.score,
                "bbox": list(result.bbox),
                "metrics": result.metrics,
            },
            indent=2,
        ),
        encoding="utf-8",
    )


def _preview_overlay(rendered: Image.Image, mask: Image.Image) -> Image.Image:
    base = rendered.convert("RGBA")
    tint = Image.new("RGBA", rendered.size, (208, 67, 43, 96))
    overlay = Image.new("RGBA", rendered.size, (0, 0, 0, 0))
    overlay.paste(tint, mask=mask)
    return Image.alpha_composite(base, overlay)


def _resolve_item_context(output_path: Path, category: str | None) -> ItemContext | None:
    category_lc = _normalize_category(category)
    overlays_root = None
    for parent in output_path.parents:
        if parent.name == "overlays":
            overlays_root = parent
            break
    if overlays_root is None:
        return None

    workspace_root = overlays_root.parent
    item_dir = workspace_root / "items" / category_lc / output_path.stem
    item_meta_path = item_dir / "item.yaml"
    payload = _load_structured_data(item_meta_path)
    if not payload:
        return ItemContext(
            item_id=output_path.stem,
            category=category_lc,
            name=output_path.stem.replace("-", " "),
        )

    raw_tags = payload.get("tags")
    tags: tuple[str, ...] = ()
    if isinstance(raw_tags, list):
        tags = tuple(str(value) for value in raw_tags if str(value).strip())
    return ItemContext(
        item_id=str(payload.get("id") or output_path.stem),
        category=category_lc or str(payload.get("category") or ""),
        name=str(payload.get("name") or output_path.stem.replace("-", " ")),
        subcategory=_optional_str(payload.get("subcategory")),
        color_primary=_optional_str(payload.get("color_primary", payload.get("color"))),
        material=_optional_str(payload.get("material")),
        style_occasion=_optional_str(payload.get("style_occasion")),
        pattern_design=_optional_str(payload.get("pattern_design")),
        tags=tags,
    )


def _cutout_native_enabled() -> bool:
    raw = os.environ.get("WARDROBE_CUTOUT_ENABLE_NATIVE", "").strip().lower()
    if raw:
        return raw in {"1", "true", "yes", "on"}
    return "PYTEST_CURRENT_TEST" not in os.environ


def _cutout_allow_download() -> bool:
    raw = os.environ.get("WARDROBE_CUTOUT_ALLOW_DOWNLOAD", "").strip().lower()
    if raw:
        return raw in {"1", "true", "yes", "on"}
    return False


def _cutout_native_backend_name() -> str:
    if not _cutout_native_enabled():
        return "none"

    raw = os.environ.get("WARDROBE_CUTOUT_NATIVE_BACKEND", "").strip().lower()
    if raw in {"", "auto", "sam_vit_h", "sam-vit-h", "gdino_sam_vit_h", "grounded_sam_vit_h"}:
        return "sam_vit_h"
    if raw in {"off", "none", "disabled", "heuristic"}:
        return "none"
    return "sam_vit_h"


def _load_grounded_sam_vit_h_backend(requested_device: str) -> Any:
    try:
        import importlib

        torch = importlib.import_module("torch")
        transformers = importlib.import_module("transformers")
        segment_anything = importlib.import_module("segment_anything")

        auto_processor_cls = getattr(transformers, "AutoProcessor")
        auto_detector_cls = getattr(transformers, "AutoModelForZeroShotObjectDetection")
        predictor_cls = getattr(segment_anything, "SamPredictor")
        model_registry = getattr(segment_anything, "sam_model_registry")

        resolved_device = _resolve_native_device(requested_device, torch_module=torch)
        local_files_only = not _cutout_allow_download()
        gdino_model_id = "IDEA-Research/grounding-dino-tiny"
        checkpoint_path = (
            os.environ.get("WARDROBE_SAM_VIT_H_CHECKPOINT")
            or os.environ.get("SAM_VIT_H_CHECKPOINT")
            or ""
        ).strip()
        if not checkpoint_path:
            for candidate in (
                Path.cwd() / "models" / "sam_vit_h_4b8939.pth",
            ):
                if candidate.exists():
                    checkpoint_path = str(candidate)
                    break
        if not checkpoint_path:
            raise FileNotFoundError(
                "SAM ViT-H checkpoint not found. Set "
                "WARDROBE_SAM_VIT_H_CHECKPOINT or place "
                "sam_vit_h_4b8939.pth under models/."
            )

        gdino_processor = auto_processor_cls.from_pretrained(
            gdino_model_id,
            local_files_only=local_files_only,
            use_fast=False,
        )
        gdino_model = auto_detector_cls.from_pretrained(
            gdino_model_id,
            local_files_only=local_files_only,
        ).to(resolved_device)
        sam_model = model_registry["vit_h"](checkpoint=checkpoint_path)
        sam_model.to(device=resolved_device)
        predictor = predictor_cls(sam_model)

        if hasattr(gdino_model, "eval"):
            gdino_model.eval()

        return {
            "kind": "grounded_sam_vit_h",
            "device": resolved_device,
            "gdino_processor": gdino_processor,
            "gdino_model": gdino_model,
            "predictor": predictor,
            "checkpoint": checkpoint_path,
            "box_threshold": 0.20,
            "text_threshold": 0.20,
            "max_boxes": 4,
        }
    except Exception as exc:
        raise RuntimeError(
            "Unable to initialize the GroundingDINO/SAM backend. "
            "Install the 'ml' extra and verify the model files."
        ) from exc


def _resolve_native_device(requested_device: str, *, torch_module: Any) -> str:
    if requested_device in {"cuda", "cpu"}:
        if requested_device == "cuda" and not bool(torch_module.cuda.is_available()):
            return "cpu"
        return requested_device
    return "cuda" if bool(torch_module.cuda.is_available()) else "cpu"


def _move_batch_to_device(batch: Any, *, device: str) -> dict[str, Any]:
    moved: dict[str, Any] = {}
    for key, value in dict(batch).items():
        if hasattr(value, "to"):
            try:
                moved[key] = value.to(device)
                continue
            except Exception:
                pass
        moved[key] = value
    return moved


def _grounded_dino_prompt(text_prompt: str) -> str:
    words = [
        token
        for token in text_prompt.replace("-", " ").split()
        if token.strip().lower() not in {"only", "the"}
    ]
    if not words:
        words = [text_prompt.strip()]
    normalized = " ".join(words).strip().lower()
    if not normalized:
        normalized = "item"
    if not normalized.endswith("."):
        normalized = f"{normalized}."
    return normalized


def _segment_with_grounded_sam_vit_h(
    *,
    image: Image.Image,
    detector_image: Image.Image,
    base_image: Image.Image | None,
    text_prompt: str,
    optional_roi: tuple[int, int, int, int] | None,
    backend: dict[str, Any],
    category: str | None,
) -> list[SegmentCandidate]:
    gdino_processor = backend.get("gdino_processor")
    gdino_model = backend.get("gdino_model")
    predictor = backend.get("predictor")
    device = str(backend.get("device") or "cpu")
    if any(part is None for part in (gdino_processor, gdino_model, predictor)):
        return []

    normalized_category = _normalize_category(category)
    segment_source = image
    if normalized_category == "shoes" and base_image is not None:
        try:
            segment_source = ImageChops.difference(
                image.convert("RGBA"),
                base_image.convert("RGBA"),
            )
        except Exception:
            segment_source = image

    crop_detector = detector_image
    crop_segment = segment_source
    roi = optional_roi
    offset_x = 0
    offset_y = 0
    if roi is not None:
        left, top, right, bottom = roi
        crop_detector = detector_image.crop((left, top, right, bottom))
        crop_segment = segment_source.crop((left, top, right, bottom))
        offset_x = left
        offset_y = top

    target = crop_detector.convert("RGB")
    gdino_inputs = gdino_processor(
        images=target,
        text=_grounded_dino_prompt(text_prompt),
        return_tensors="pt",
    )
    gdino_inputs = _move_batch_to_device(gdino_inputs, device=device)
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        with __import__("torch").inference_mode():
            gdino_outputs = gdino_model(**gdino_inputs)

    detections = gdino_processor.post_process_grounded_object_detection(
        gdino_outputs,
        gdino_inputs.get("input_ids"),
        threshold=float(backend.get("box_threshold", 0.20)),
        text_threshold=float(backend.get("text_threshold", 0.20)),
        target_sizes=[target.size[::-1]],
    )
    if not detections:
        return []

    detection = detections[0]
    boxes = _tensor_like_to_box_list(detection.get("boxes"))
    scores = _tensor_like_to_score_list(detection.get("scores"))
    text_labels = [str(value) for value in (detection.get("text_labels") or [])]
    selected_indexes = _select_detector_indexes(
        boxes=boxes,
        scores=scores,
        image_size=target.size,
        category=normalized_category,
    )
    if not selected_indexes:
        return []

    predictor.set_image(np.array(crop_segment.convert("RGB")))
    candidates: list[SegmentCandidate] = []
    for index in selected_indexes:
        detected_box = boxes[index]
        detector_score = scores[index] if index < len(scores) else 0.0
        label = text_labels[index] if index < len(text_labels) else text_prompt
        masks, mask_scores, _ = predictor.predict(
            box=np.array(detected_box, dtype=np.float32),
            multimask_output=True,
        )
        if not len(mask_scores):
            continue
        best_index = int(np.argmax(mask_scores))
        mask = Image.fromarray(
            (np.asarray(masks[best_index], dtype=np.uint8) > 0).astype(np.uint8) * 255,
            mode="L",
        )
        if roi is not None:
            expanded = Image.new("L", image.size, _MASK_BLACK)
            expanded.paste(mask, (offset_x, offset_y))
            mask = expanded

        sam_score = float(mask_scores[best_index])
        confidence = (float(detector_score) * 0.65) + (sam_score * 0.35)
        candidates.append(
            SegmentCandidate(
                mask=mask,
                confidence=confidence,
                metadata={
                    "source": "grounded_sam_vit_h",
                    "label": str(label),
                    "box": [round(float(value), 4) for value in detected_box],
                    "detected_box": [round(float(value), 4) for value in detected_box],
                    "box_variant": "original",
                    "detector_score": float(detector_score),
                    "sam_iou": sam_score,
                },
            )
        )

    candidates.sort(key=lambda item: item.confidence, reverse=True)
    return candidates
def _select_detector_indexes(
    *,
    boxes: list[list[float]],
    scores: list[float],
    image_size: tuple[int, int],
    category: str | None,
) -> list[int]:
    if not boxes:
        return []

    normalized_category = _normalize_category(category)
    width, height = image_size
    indexed = list(range(len(boxes)))
    indexed.sort(key=lambda idx: scores[idx] if idx < len(scores) else 0.0, reverse=True)

    if normalized_category != "shoes":
        return indexed[:1]

    selected: list[int] = []
    centers: list[float] = []
    min_sep = width * 0.14
    for index in indexed:
        box = boxes[index]
        left, top, right, bottom = [float(value) for value in box[:4]]
        area = max(0.0, right - left) * max(0.0, bottom - top)
        center_x = (left + right) * 0.5
        center_y = (top + bottom) * 0.5
        if center_y < height * 0.68:
            continue
        if area < (width * height * 0.0015):
            continue
        if any(abs(center_x - other) < min_sep for other in centers):
            continue
        selected.append(index)
        centers.append(center_x)
        if len(selected) >= 2:
            break

    if selected:
        return selected
    return indexed[:1]
def _infer_output_like_path(rendered_path: Path, category: str | None) -> Path:
    category_lc = _normalize_category(category)
    name = rendered_path.stem
    if name.startswith("overlay_full__"):
        parts = name.split("__", 2)
        if len(parts) == 3:
            category_lc = category_lc or _normalize_category(parts[1])
            item_id = parts[2]
            try:
                passes_index = rendered_path.parts.index("_passes")
                workspace_root = Path(*rendered_path.parts[:passes_index])
                pose_id = rendered_path.parent.name
                return workspace_root / "overlays" / pose_id / category_lc / f"{item_id}.png"
            except ValueError:
                return rendered_path.with_name(f"{item_id}.png")
    return rendered_path


def _load_structured_data(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    raw = path.read_text(encoding="utf-8")
    try:
        if yaml is not None:
            payload = yaml.safe_load(raw)
        else:
            payload = json.loads(raw)
    except Exception:
        try:
            payload = json.loads(raw)
        except Exception:
            return {}
    return payload if isinstance(payload, dict) else {}


def _optional_str(value: Any) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    return text or None


def _normalize_category(value: str | None) -> str:
    text = (value or "").strip().lower()
    if text == "hat":
        return "headwear"
    if text == "shoe":
        return "shoes"
    return text


def _clean_text(value: str | None) -> str:
    if not value:
        return ""
    return " ".join(str(value).strip().split())


def _anchor_from_bbox(
    size: tuple[int, int],
    bbox: tuple[int, int, int, int],
) -> list[float]:
    width, height = size
    left, top, right, bottom = bbox
    anchor = [
        left / max(1, width),
        top / max(1, height),
        (right - left) / max(1, width),
        (bottom - top) / max(1, height),
    ]
    return [round(value, 6) for value in anchor]


def _dedupe_prompts(values: list[str]) -> list[str]:
    seen: set[str] = set()
    prompts: list[str] = []
    for value in values:
        text = _clean_text(value)
        if not text:
            continue
        key = text.lower()
        if key in seen:
            continue
        seen.add(key)
        prompts.append(text)
    return prompts
def _tensor_like_to_score_list(value: Any) -> list[float]:
    if value is None:
        return []
    if isinstance(value, list):
        return [float(item) for item in value]
    if isinstance(value, tuple):
        return [float(item) for item in value]
    detach = getattr(value, "detach", None)
    if callable(detach):
        try:
            tensor = detach()
            cpu = getattr(tensor, "cpu", None)
            if callable(cpu):
                tensor = cpu()
            tolist = getattr(tensor, "tolist", None)
            if callable(tolist):
                data = tolist()
                if isinstance(data, list):
                    flat: list[float] = []
                    for item in data:
                        if isinstance(item, list):
                            flat.extend(float(v) for v in item)
                        else:
                            flat.append(float(item))
                    return flat
        except Exception:
            return []
    return []


def _tensor_like_to_box_list(value: Any) -> list[list[float]]:
    if value is None:
        return []
    if isinstance(value, list):
        if value and isinstance(value[0], (list, tuple)):
            return [[float(v) for v in item[:4]] for item in value]
        return []
    if isinstance(value, tuple):
        if value and isinstance(value[0], (list, tuple)):
            return [[float(v) for v in item[:4]] for item in value]
        return []
    detach = getattr(value, "detach", None)
    if callable(detach):
        try:
            tensor = detach()
            cpu = getattr(tensor, "cpu", None)
            if callable(cpu):
                tensor = cpu()
            tolist = getattr(tensor, "tolist", None)
            if callable(tolist):
                data = tolist()
                if isinstance(data, list):
                    return _tensor_like_to_box_list(data)
        except Exception:
            return []
    return []
def _binary_mask(mask: Image.Image) -> Image.Image:
    if mask.mode != "L":
        mask = mask.convert("L")
    values = [_MASK_WHITE if value >= 128 else _MASK_BLACK for value in _channel_data(mask)]
    binary = Image.new("L", mask.size, _MASK_BLACK)
    binary.putdata(values)
    return binary


def _expand_mask(mask: Image.Image, radius: int) -> Image.Image:
    size = max(3, radius * 2 + 1)
    if size % 2 == 0:
        size += 1
    return _binary_mask(mask.filter(ImageFilter.MaxFilter(size=size)))


def _apply_close(mask: Image.Image, radius: int) -> Image.Image:
    size = max(3, radius * 2 + 1)
    if size % 2 == 0:
        size += 1
    return _binary_mask(mask.filter(ImageFilter.MaxFilter(size=size)).filter(ImageFilter.MinFilter(size=size)))


def _apply_open(mask: Image.Image, radius: int) -> Image.Image:
    size = max(3, radius * 2 + 1)
    if size % 2 == 0:
        size += 1
    return _binary_mask(mask.filter(ImageFilter.MinFilter(size=size)).filter(ImageFilter.MaxFilter(size=size)))


def _fill_holes(mask: Image.Image) -> Image.Image:
    binary = [1 if value else 0 for value in _channel_data(_binary_mask(mask))]
    width, height = mask.size
    visited = bytearray(width * height)
    stack: list[int] = []
    for x in range(width):
        stack.append(x)
        stack.append((height - 1) * width + x)
    for y in range(height):
        stack.append(y * width)
        stack.append(y * width + (width - 1))

    while stack:
        current = stack.pop()
        if current < 0 or current >= width * height:
            continue
        if visited[current]:
            continue
        visited[current] = 1
        if binary[current]:
            continue
        x = current % width
        y = current // width
        for next_index in _neighbors4(current, x, y, width, height):
            if not visited[next_index]:
                stack.append(next_index)

    filled = []
    for index, value in enumerate(binary):
        if value or not visited[index]:
            filled.append(_MASK_WHITE)
        else:
            filled.append(_MASK_BLACK)
    out = Image.new("L", mask.size, _MASK_BLACK)
    out.putdata(filled)
    return out


def _keep_top_components(mask: Image.Image, *, min_area_px: int, keep: int) -> Image.Image:
    components = _connected_components(mask)
    if not components:
        return Image.new("L", mask.size, _MASK_BLACK)
    selected = [component for component in components if int(component["area"]) >= min_area_px][:keep]
    if not selected:
        return Image.new("L", mask.size, _MASK_BLACK)
    width, height = mask.size
    out_data = [_MASK_BLACK] * (width * height)
    for component in selected:
        for index in component["pixels"]:
            out_data[index] = _MASK_WHITE
    out = Image.new("L", mask.size, _MASK_BLACK)
    out.putdata(out_data)
    return out


def _connected_components(mask: Image.Image) -> list[dict[str, Any]]:
    binary = [1 if value else 0 for value in _channel_data(_binary_mask(mask))]
    width, height = mask.size
    visited = bytearray(width * height)
    components: list[dict[str, Any]] = []
    for index, value in enumerate(binary):
        if not value or visited[index]:
            continue
        stack = [index]
        visited[index] = 1
        pixels: list[int] = []
        min_x = width
        min_y = height
        max_x = 0
        max_y = 0
        sum_x = 0
        sum_y = 0
        while stack:
            current = stack.pop()
            pixels.append(current)
            x = current % width
            y = current // width
            min_x = min(min_x, x)
            min_y = min(min_y, y)
            max_x = max(max_x, x)
            max_y = max(max_y, y)
            sum_x += x
            sum_y += y
            for next_index in _neighbors4(current, x, y, width, height):
                if binary[next_index] and not visited[next_index]:
                    visited[next_index] = 1
                    stack.append(next_index)
        area = len(pixels)
        components.append(
            {
                "area": area,
                "pixels": pixels,
                "bbox": (min_x, min_y, max_x + 1, max_y + 1),
                "centroid": (sum_x / max(1, area), sum_y / max(1, area)),
            }
        )
    components.sort(key=lambda component: int(component["area"]), reverse=True)
    return components


def _neighbors4(index: int, x: int, y: int, width: int, height: int) -> list[int]:
    neighbors: list[int] = []
    if x > 0:
        neighbors.append(index - 1)
    if x + 1 < width:
        neighbors.append(index + 1)
    if y > 0:
        neighbors.append(index - width)
    if y + 1 < height:
        neighbors.append(index + width)
    return neighbors


def _neighbors8(index: int, x: int, y: int, width: int, height: int) -> list[int]:
    neighbors = _neighbors4(index, x, y, width, height)
    if x > 0 and y > 0:
        neighbors.append(index - width - 1)
    if x + 1 < width and y > 0:
        neighbors.append(index - width + 1)
    if x > 0 and y + 1 < height:
        neighbors.append(index + width - 1)
    if x + 1 < width and y + 1 < height:
        neighbors.append(index + width + 1)
    return neighbors


def _component_mean(component: dict[str, Any], diff_map: list[int], width: int) -> float:
    pixels = component["pixels"]
    if not pixels:
        return 0.0
    total = 0
    for index in pixels:
        total += diff_map[index]
    return total / len(pixels)


def _mask_mean(mask: Image.Image, diff_map: list[int]) -> float:
    values = [diff_map[index] for index, flag in enumerate(_channel_data(mask)) if flag]
    if not values:
        return 0.0
    return sum(values) / len(values)


def _mask_area(mask: Image.Image) -> int:
    return sum(1 for value in _channel_data(mask) if value)


def _mask_centroid(mask: Image.Image) -> tuple[float, float]:
    width, _ = mask.size
    total = 0
    sum_x = 0
    sum_y = 0
    for index, value in enumerate(_channel_data(mask)):
        if not value:
            continue
        total += 1
        sum_x += index % width
        sum_y += index // width
    if total <= 0:
        return (0.0, 0.0)
    return (sum_x / total, sum_y / total)


def _skin_mask(
    image: Image.Image,
    *,
    roi_box: tuple[int, int, int, int],
    margin_px: int,
) -> Image.Image:
    rgb = image.convert("RGB")
    ycbcr = rgb.convert("YCbCr")
    width, height = rgb.size
    left, top, right, bottom = roi_box
    out = [_MASK_BLACK] * (width * height)
    for index, (y, cb, cr) in enumerate(_pixel_data(ycbcr)):
        x = index % width
        row = index // width
        if not (left <= x < right and top <= row < bottom):
            continue
        if 70 <= y <= 255 and 77 <= cb <= 127 and 133 <= cr <= 173:
            out[index] = _MASK_WHITE
    mask = Image.new("L", (width, height), _MASK_BLACK)
    mask.putdata(out)
    if margin_px > 0:
        size = max(3, margin_px * 2 + 1)
        if size % 2 == 0:
            size += 1
        mask = _binary_mask(mask.filter(ImageFilter.MaxFilter(size=size)))
    return mask


def _binary_union(mask_a: Image.Image, mask_b: Image.Image) -> Image.Image:
    width, height = mask_a.size
    values_a = _channel_data(mask_a)
    values_b = _channel_data(mask_b)
    out = Image.new("L", (width, height), _MASK_BLACK)
    out.putdata(
        [
            _MASK_WHITE if (a or b) else _MASK_BLACK
            for a, b in zip(values_a, values_b)
        ]
    )
    return out


def _binary_intersection(mask_a: Image.Image, mask_b: Image.Image) -> Image.Image:
    width, height = mask_a.size
    values_a = _channel_data(mask_a)
    values_b = _channel_data(mask_b)
    out = Image.new("L", (width, height), _MASK_BLACK)
    out.putdata(
        [
            _MASK_WHITE if (a and b) else _MASK_BLACK
            for a, b in zip(values_a, values_b)
        ]
    )
    return out


def _binary_subtract(mask_a: Image.Image, mask_b: Image.Image) -> Image.Image:
    width, height = mask_a.size
    values_a = _channel_data(mask_a)
    values_b = _channel_data(mask_b)
    out = Image.new("L", (width, height), _MASK_BLACK)
    out.putdata(
        [
            _MASK_WHITE if (a and not b) else _MASK_BLACK
            for a, b in zip(values_a, values_b)
        ]
    )
    return out


def _bbox_distance(
    bbox_a: tuple[int, int, int, int],
    bbox_b: tuple[int, int, int, int],
) -> int:
    left_a, top_a, right_a, bottom_a = bbox_a
    left_b, top_b, right_b, bottom_b = bbox_b
    dx = max(0, max(left_a, left_b) - min(right_a, right_b))
    dy = max(0, max(top_a, top_b) - min(bottom_a, bottom_b))
    return max(dx, dy)


def _percentile(values: list[int], percentile: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    pct = max(0.0, min(100.0, float(percentile))) / 100.0
    if pct <= 0.0:
        return float(ordered[0])
    if pct >= 1.0:
        return float(ordered[-1])
    pos = (len(ordered) - 1) * pct
    lo = int(pos)
    hi = min(len(ordered) - 1, lo + 1)
    if lo == hi:
        return float(ordered[lo])
    weight = pos - lo
    return float(ordered[lo] * (1.0 - weight) + ordered[hi] * weight)


def _median(values: list[int]) -> int:
    if not values:
        return 0
    ordered = sorted(values)
    mid = len(ordered) // 2
    if len(ordered) % 2:
        return int(ordered[mid])
    return int(round((ordered[mid - 1] + ordered[mid]) / 2.0))


def _overlap_area(mask_a: Image.Image, mask_b: Image.Image) -> int:
    values_a = _channel_data(mask_a)
    values_b = _channel_data(mask_b)
    return sum(1 for a, b in zip(values_a, values_b) if a and b)
