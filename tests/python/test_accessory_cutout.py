from __future__ import annotations

import json
from pathlib import Path

from PIL import Image, ImageDraw

from wardrobe_gen.accessory_cutout import (
    CutoutResult,
    ItemContext,
    SegmentCandidate,
    _cutout_native_backend_name,
    _select_detector_indexes,
    build_overlay_cutout_from_rendered,
    prompt_candidates,
)
from wardrobe_gen.overlay import build_overlay_band_from_rendered


def test_prompt_candidates_include_vlm_specific_terms() -> None:
    prompts = prompt_candidates(
        ItemContext(
            item_id="gray-beanie",
            category="headwear",
            name="Gray Beanie",
            subcategory="beanie",
            color_primary="gray",
            material="knit",
        )
    )

    assert "beanie" in prompts
    assert "gray beanie" in prompts
    assert "only the beanie" in prompts


def test_native_backend_name_defaults_to_sam_vit_h(monkeypatch) -> None:
    monkeypatch.setenv("WARDROBE_CUTOUT_ENABLE_NATIVE", "1")
    monkeypatch.delenv("WARDROBE_CUTOUT_NATIVE_BACKEND", raising=False)
    assert _cutout_native_backend_name() == "sam_vit_h"

    monkeypatch.setenv("WARDROBE_CUTOUT_NATIVE_BACKEND", "sam_vit_h")
    assert _cutout_native_backend_name() == "sam_vit_h"


def test_select_detector_indexes_prefers_two_separated_shoe_boxes() -> None:
    boxes = [
        [20.0, 210.0, 90.0, 300.0],
        [140.0, 214.0, 212.0, 302.0],
        [70.0, 120.0, 170.0, 200.0],
    ]
    scores = [0.9, 0.8, 0.95]

    indexes = _select_detector_indexes(
        boxes=boxes,
        scores=scores,
        image_size=(240, 320),
        category="shoes",
    )

    assert indexes == [0, 1]


def test_overlay_cutout_isolates_headwear_without_face(tmp_path: Path, monkeypatch) -> None:
    workspace = tmp_path / "workspace"
    output_path = workspace / "overlays" / "pose-1" / "headwear" / "test-hat.png"
    item_dir = workspace / "items" / "headwear" / "test-hat"
    item_dir.mkdir(parents=True, exist_ok=True)
    (item_dir / "item.yaml").write_text(
        json.dumps(
            {
                "id": "test-hat",
                "name": "Black Beanie",
                "category": "headwear",
                "subcategory": "beanie",
                "color_primary": "black",
                "material": "knit",
            }
        ),
        encoding="utf-8",
    )

    size = (240, 320)
    base = Image.new("RGB", size, "white")
    base_draw = ImageDraw.Draw(base)
    base_draw.ellipse((88, 34, 152, 104), fill=(238, 198, 168))
    base_draw.rectangle((110, 104, 130, 154), fill=(238, 198, 168))

    rendered = base.copy()
    rendered_draw = ImageDraw.Draw(rendered)
    rendered_draw.rectangle((80, 18, 160, 62), fill=(34, 34, 34))
    rendered_draw.ellipse((80, 2, 160, 66), fill=(34, 34, 34))

    base_path = workspace / "poses" / "pose-1" / "pose.png"
    rendered_path = workspace / "_passes" / "pose-1" / "overlay_full__headwear__test-hat.png"
    base_path.parent.mkdir(parents=True, exist_ok=True)
    rendered_path.parent.mkdir(parents=True, exist_ok=True)
    base.save(base_path)
    rendered.save(rendered_path)

    mask = Image.new("L", size, 0)
    mask_draw = ImageDraw.Draw(mask)
    mask_draw.rectangle((80, 2, 160, 66), fill=255)
    cutout = rendered.convert("RGBA")
    cutout.putalpha(mask)

    def fake_cutout(**kwargs):
        kwargs["output_path"].parent.mkdir(parents=True, exist_ok=True)
        cutout.save(kwargs["output_path"])
        return CutoutResult(
            anchor=[0.333333, 0.00625, 0.333333, 0.2],
            bbox=(80, 2, 160, 66),
            prompt="beanie",
            score=0.99,
            metrics={},
            mask=mask,
            cutout=cutout,
        )

    monkeypatch.setattr(
        "wardrobe_gen.overlay.build_overlay_cutout_from_rendered",
        fake_cutout,
    )

    build_overlay_band_from_rendered(
        rendered_path=rendered_path,
        crop=(0.0, 0.0, 1.0, 0.2),
        output_path=output_path,
        category="headwear",
        base_path=base_path,
        dynamic_crop={"cutout_mode": "sam_vit_h"},
        pose_neck_y=0.32,
        pose_ankle_y=0.88,
    )

    alpha_bbox = Image.open(output_path).split()[-1].getbbox()
    assert alpha_bbox is not None
    left, top, right, bottom = alpha_bbox
    assert left <= 90
    assert right >= 150
    assert top <= 10
    assert bottom <= 85


def test_overlay_cutout_isolates_shoes_without_legs(tmp_path: Path, monkeypatch) -> None:
    workspace = tmp_path / "workspace"
    output_path = workspace / "overlays" / "pose-1" / "shoes" / "test-shoes.png"
    item_dir = workspace / "items" / "shoes" / "test-shoes"
    item_dir.mkdir(parents=True, exist_ok=True)
    (item_dir / "item.yaml").write_text(
        json.dumps(
            {
                "id": "test-shoes",
                "name": "Black Sneakers",
                "category": "shoes",
                "subcategory": "sneaker",
                "color_primary": "black",
                "material": "fabric",
            }
        ),
        encoding="utf-8",
    )

    size = (240, 320)
    base = Image.new("RGB", size, "white")
    base_draw = ImageDraw.Draw(base)
    base_draw.rectangle((92, 150, 112, 286), fill=(210, 180, 150))
    base_draw.rectangle((128, 150, 148, 286), fill=(210, 180, 150))

    rendered = base.copy()
    rendered_draw = ImageDraw.Draw(rendered)
    rendered_draw.rectangle((76, 256, 116, 302), fill=(20, 20, 20))
    rendered_draw.rectangle((124, 256, 164, 302), fill=(20, 20, 20))
    rendered_draw.rectangle((70, 302, 118, 314), fill=(20, 20, 20))
    rendered_draw.rectangle((122, 302, 170, 314), fill=(20, 20, 20))

    base_path = workspace / "poses" / "pose-1" / "pose.png"
    rendered_path = workspace / "_passes" / "pose-1" / "overlay_full__shoes__test-shoes.png"
    base_path.parent.mkdir(parents=True, exist_ok=True)
    rendered_path.parent.mkdir(parents=True, exist_ok=True)
    base.save(base_path)
    rendered.save(rendered_path)

    mask = Image.new("L", size, 0)
    mask_draw = ImageDraw.Draw(mask)
    mask_draw.rectangle((70, 256, 170, 314), fill=255)
    cutout = rendered.convert("RGBA")
    cutout.putalpha(mask)

    def fake_cutout(**kwargs):
        kwargs["output_path"].parent.mkdir(parents=True, exist_ok=True)
        cutout.save(kwargs["output_path"])
        return CutoutResult(
            anchor=[0.291667, 0.8, 0.416667, 0.18125],
            bbox=(70, 256, 170, 314),
            prompt="pair of sneakers",
            score=0.98,
            metrics={},
            mask=mask,
            cutout=cutout,
        )

    monkeypatch.setattr(
        "wardrobe_gen.overlay.build_overlay_cutout_from_rendered",
        fake_cutout,
    )

    build_overlay_band_from_rendered(
        rendered_path=rendered_path,
        crop=(0.0, 0.84, 1.0, 0.16),
        output_path=output_path,
        category="shoes",
        base_path=base_path,
        dynamic_crop={"cutout_mode": "sam_vit_h"},
        pose_neck_y=0.32,
        pose_ankle_y=0.90,
    )

    alpha_bbox = Image.open(output_path).split()[-1].getbbox()
    assert alpha_bbox is not None
    left, top, right, bottom = alpha_bbox
    assert left <= 80
    assert right >= 160
    assert top >= 246
    assert bottom >= 310


def test_direct_native_cutout_records_result_metrics(tmp_path: Path, monkeypatch) -> None:
    workspace = tmp_path / "workspace"
    output_path = workspace / "overlays" / "pose-1" / "shoes" / "test-shoes.png"
    item_dir = workspace / "items" / "shoes" / "test-shoes"
    item_dir.mkdir(parents=True, exist_ok=True)
    (item_dir / "item.yaml").write_text(
        json.dumps(
            {
                "id": "test-shoes",
                "name": "Black Sneakers",
                "category": "shoes",
                "subcategory": "sneaker",
                "color_primary": "black",
                "material": "fabric",
            }
        ),
        encoding="utf-8",
    )

    size = (240, 320)
    base = Image.new("RGB", size, "white")
    base_draw = ImageDraw.Draw(base)
    base_draw.rectangle((92, 150, 112, 286), fill=(210, 180, 150))
    base_draw.rectangle((128, 150, 148, 286), fill=(210, 180, 150))

    rendered = base.copy()
    rendered_draw = ImageDraw.Draw(rendered)
    rendered_draw.rectangle((76, 256, 116, 302), fill=(20, 20, 20))
    rendered_draw.rectangle((124, 256, 164, 302), fill=(20, 20, 20))
    rendered_draw.rectangle((70, 302, 118, 314), fill=(20, 20, 20))
    rendered_draw.rectangle((122, 302, 170, 314), fill=(20, 20, 20))

    base_path = workspace / "poses" / "pose-1" / "pose.png"
    rendered_path = workspace / "_passes" / "pose-1" / "overlay_full__shoes__test-shoes.png"
    base_path.parent.mkdir(parents=True, exist_ok=True)
    rendered_path.parent.mkdir(parents=True, exist_ok=True)
    base.save(base_path)
    rendered.save(rendered_path)

    mask = Image.new("L", size, 0)
    draw = ImageDraw.Draw(mask)
    draw.rectangle((70, 256, 170, 314), fill=255)

    def fake_segment(*args, **kwargs):
        return [
            SegmentCandidate(
                mask=mask,
                confidence=0.98,
                metadata={
                    "source": "grounded_sam_vit_h",
                    "detector_score": 0.91,
                    "sam_iou": 0.96,
                    "detected_box": [70.0, 256.0, 170.0, 314.0],
                },
            )
        ]

    monkeypatch.setattr("wardrobe_gen.accessory_cutout.segment", fake_segment)

    result = build_overlay_cutout_from_rendered(
        rendered_path=rendered_path,
        output_path=output_path,
        category="shoes",
        base_path=base_path,
        device="auto",
    )

    assert result is not None
    assert result.metrics.get("candidate_source") == "grounded_sam_vit_h"
    assert result.metrics.get("fusion_mode") in {"direct_native", "direct_native_pair"}
