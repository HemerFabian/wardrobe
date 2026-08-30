from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
import sys
import tempfile
from argparse import Namespace
from pathlib import Path
from unittest.mock import patch

import pytest
from PIL import Image

from wardrobe_gen.cli import (
    _build_accessory_prompt,
    _collect_targeted_overlay_keys,
    _collect_targeted_render_keys,
    _count_planned_render_outputs,
    _preserve_generated_at_for_unchanged_manifest,
    _prune_completed_regeneration_requests,
    _render_all,
    _render_overlays,
    _sample_overlay_preview_candidates,
    _sample_overlay_reference_candidates,
    _select_overlay_reference_image,
    _select_representative_overlay_render,
    parse_args,
)
from wardrobe_gen.dataset import (
    Dataset,
    Item,
    Pose,
    RegenerateItemRequest,
    RegenerateTargetRequest,
)


def test_accessory_prompt_locks_beanie_shape_and_position() -> None:
    prompt = _build_accessory_prompt(
        "Add the headwear from image2.",
        Item(
            item_id="gray-beanie",
            name="Gray Beanie",
            category="headwear",
            path=Path("beanie.png"),
            subcategory="beanie",
            color_primary="gray",
            material="knit",
        ),
    )

    assert "brimless knit beanie" in prompt
    assert "not a cap" in prompt
    assert "centered on the existing head" in prompt


def test_overlay_reference_uses_stable_strategy_per_category() -> None:
    pose = Path("pose.png")
    first = Path("first.webp")
    second = Path("second.webp")
    renders = [first, second]

    with patch(
        "wardrobe_gen.cli._select_representative_overlay_render",
        return_value=second,
    ):
        assert (
            _select_overlay_reference_image(
                pose_input=pose,
                base_renders=renders,
                category="headwear",
            )
            == first
        )
        assert (
            _select_overlay_reference_image(
                pose_input=pose,
                base_renders=renders,
                category="shoes",
            )
            == second
        )

    assert (
        _select_overlay_reference_image(
            pose_input=pose,
            base_renders=[],
            category="headwear",
        )
        == pose
    )


def test_preserves_generated_at_when_manifest_content_is_unchanged() -> None:
    with tempfile.TemporaryDirectory() as tmp_dir:
        manifest_path = Path(tmp_dir) / "wardrobe.json"
        manifest_path.write_text(
            json.dumps(
                {
                    "schema_version": 5,
                    "generated_at": "2026-01-01T00:00:00+00:00",
                    "renders": [],
                }
            ),
            encoding="utf-8",
        )
        payload = {
            "schema_version": 5,
            "generated_at": "2026-02-01T00:00:00+00:00",
            "renders": [],
        }

        _preserve_generated_at_for_unchanged_manifest(payload, manifest_path)

        assert payload["generated_at"] == "2026-01-01T00:00:00+00:00"


def test_render_parse_args_rejects_removed_include_overlays_flag() -> None:
    with patch.object(
        sys,
        "argv",
        ["cli.py", "render", "workspace", "--include-overlays"],
    ):
        with pytest.raises(SystemExit):
            parse_args()



def test_count_planned_render_outputs_includes_overlays_by_default() -> None:
    with tempfile.TemporaryDirectory() as tmp_dir:
        workspace_root = Path(tmp_dir)
        pose_path = workspace_root / "pose.png"
        top_path = workspace_root / "top.png"
        bottom_path = workspace_root / "bottom.png"
        hat_path = workspace_root / "hat.png"
        shoes_path = workspace_root / "shoes.png"

        for path in (pose_path, top_path, bottom_path, hat_path, shoes_path):
            path.write_bytes(b"stub")

        dataset = Dataset(
            root=workspace_root,
            poses=[Pose(pose_id="pose-a", name="Pose A", path=pose_path)],
            items_by_category={
                "top": [Item(item_id="top-a", name="Top A", category="top", path=top_path)],
                "bottom": [
                    Item(item_id="bottom-a", name="Bottom A", category="bottom", path=bottom_path)
                ],
                "headwear": [
                    Item(item_id="hat-a", name="Hat A", category="headwear", path=hat_path)
                ],
                "shoes": [
                    Item(item_id="shoes-a", name="Shoes A", category="shoes", path=shoes_path)
                ],
            },
        )

        planned = _count_planned_render_outputs(
            workspace_root=workspace_root,
            poses=dataset.poses,
            tops=dataset.items_by_category["top"],
            bottoms=dataset.items_by_category["bottom"],
            dataset=dataset,
            image_format="png",
            overlay_format="png",
            force=False,
            max_images=None,
        )

        assert planned == 3


def test_collect_targeted_render_keys_expands_bulk_and_granular_targets() -> None:
    with tempfile.TemporaryDirectory() as tmp_dir:
        workspace_root = Path(tmp_dir)
        pose_path = workspace_root / "pose.png"
        top_path = workspace_root / "top.png"
        alt_top_path = workspace_root / "top-2.png"
        bottom_path = workspace_root / "bottom.png"
        alt_bottom_path = workspace_root / "bottom-2.png"

        for path in (pose_path, top_path, alt_top_path, bottom_path, alt_bottom_path):
            path.write_bytes(b"stub")

        poses = [Pose(pose_id="pose-a", name="Pose A", path=pose_path)]
        tops = [
            Item(item_id="top-a", name="Top A", category="top", path=top_path),
            Item(item_id="top-b", name="Top B", category="top", path=alt_top_path),
        ]
        bottoms = [
            Item(item_id="bottom-a", name="Bottom A", category="bottom", path=bottom_path),
            Item(item_id="bottom-b", name="Bottom B", category="bottom", path=alt_bottom_path),
        ]
        dataset = Dataset(
            root=workspace_root,
            poses=poses,
            items_by_category={
                "top": tops,
                "bottom": bottoms,
                "headwear": [],
                "shoes": [],
            },
            regenerate_items=[
                RegenerateItemRequest(
                    category="top",
                    item_id="top-a",
                    requested_at="2026-03-01T10:00:00Z",
                )
            ],
            regenerate_targets=[
                RegenerateTargetRequest(
                    type="pose_item",
                    pose_id="pose-a",
                    category="bottom",
                    item_id="bottom-b",
                    requested_at="2026-03-01T10:01:00Z",
                ),
                RegenerateTargetRequest(
                    type="render",
                    pose_id="pose-a",
                    top_id="top-b",
                    bottom_id="bottom-a",
                    requested_at="2026-03-01T10:02:00Z",
                ),
            ],
        )

        targeted, forced_bottom_bases = _collect_targeted_render_keys(
            dataset=dataset,
            workspace_root=workspace_root,
            poses=poses,
            tops=tops,
            bottoms=bottoms,
            image_format="png",
        )

        assert targeted == {
            ("pose-a", "top-a", "bottom-a"),
            ("pose-a", "top-a", "bottom-b"),
            ("pose-a", "top-a", "bottom-b"),
            ("pose-a", "top-b", "bottom-b"),
            ("pose-a", "top-b", "bottom-a"),
        }
        assert forced_bottom_bases == {
            ("pose-a", "bottom-b"),
            ("pose-a", "bottom-a"),
        }


def test_collect_targeted_overlay_keys_expands_pose_item_and_overlay_targets() -> None:
    with tempfile.TemporaryDirectory() as tmp_dir:
        workspace_root = Path(tmp_dir)
        pose_path = workspace_root / "pose.png"
        hat_path = workspace_root / "hat.png"
        shoes_path = workspace_root / "shoes.png"

        for path in (pose_path, hat_path, shoes_path):
            path.write_bytes(b"stub")

        poses = [Pose(pose_id="pose-a", name="Pose A", path=pose_path)]
        dataset = Dataset(
            root=workspace_root,
            poses=poses,
            items_by_category={
                "top": [],
                "bottom": [],
                "headwear": [
                    Item(item_id="hat-a", name="Hat A", category="headwear", path=hat_path)
                ],
                "shoes": [
                    Item(item_id="shoe-a", name="Shoe A", category="shoes", path=shoes_path)
                ],
            },
            regenerate_targets=[
                RegenerateTargetRequest(
                    type="pose_item",
                    pose_id="pose-a",
                    category="headwear",
                    item_id="hat-a",
                    requested_at="2026-03-01T10:00:00Z",
                ),
                RegenerateTargetRequest(
                    type="overlay",
                    pose_id="pose-a",
                    category="shoes",
                    item_id="shoe-a",
                    requested_at="2026-03-01T10:01:00Z",
                ),
            ],
        )

        targeted = _collect_targeted_overlay_keys(
            dataset=dataset,
            workspace_root=workspace_root,
            poses=poses,
            overlay_format="png",
        )

        assert targeted == {
            ("pose-a", "headwear", "hat-a"),
            ("pose-a", "shoes", "shoe-a"),
        }


def test_collect_targeted_render_keys_skips_outputs_completed_after_request() -> None:
    with tempfile.TemporaryDirectory() as tmp_dir:
        workspace_root = Path(tmp_dir)
        pose_path = workspace_root / "pose.png"
        top_path = workspace_root / "top.png"
        bottom_path = workspace_root / "bottom.png"

        for path in (pose_path, top_path, bottom_path):
            path.write_bytes(b"stub")

        output_path = workspace_root / "renders" / "pose-a" / "top-a__bottom-a.png"
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_bytes(b"newer-output")
        completed_at = dt.datetime(2026, 3, 1, 10, 5, 0, tzinfo=dt.timezone.utc)
        os.utime(output_path, (completed_at.timestamp(), completed_at.timestamp()))

        bottom_base_path = workspace_root / "_passes" / "pose-a" / "base_bottom__bottom-a.png"
        bottom_base_path.parent.mkdir(parents=True, exist_ok=True)
        bottom_base_path.write_bytes(b"newer-base")
        os.utime(bottom_base_path, (completed_at.timestamp(), completed_at.timestamp()))

        request_time = "2026-03-01T10:00:00Z"
        dataset = Dataset(
            root=workspace_root,
            poses=[Pose(pose_id="pose-a", name="Pose A", path=pose_path)],
            items_by_category={
                "top": [Item(item_id="top-a", name="Top A", category="top", path=top_path)],
                "bottom": [
                    Item(item_id="bottom-a", name="Bottom A", category="bottom", path=bottom_path)
                ],
                "headwear": [],
                "shoes": [],
            },
            regenerate_targets=[
                RegenerateTargetRequest(
                    type="render",
                    pose_id="pose-a",
                    top_id="top-a",
                    bottom_id="bottom-a",
                    requested_at=request_time,
                )
            ],
        )

        targeted, forced_bottom_bases = _collect_targeted_render_keys(
            dataset=dataset,
            workspace_root=workspace_root,
            poses=dataset.poses,
            tops=dataset.items_by_category["top"],
            bottoms=dataset.items_by_category["bottom"],
            image_format="png",
        )

        assert targeted == set()
        assert forced_bottom_bases == set()


def test_prune_completed_regeneration_requests_uses_existing_outputs_from_previous_runs() -> None:
    with tempfile.TemporaryDirectory() as tmp_dir:
        workspace_root = Path(tmp_dir)
        pose_path = workspace_root / "pose.png"
        top_path = workspace_root / "top.png"
        bottom_a_path = workspace_root / "bottom-a.png"
        bottom_b_path = workspace_root / "bottom-b.png"

        for path in (pose_path, top_path, bottom_a_path, bottom_b_path):
            path.write_bytes(b"stub")

        request_time = "2026-03-01T10:00:00Z"
        completed_at = dt.datetime(2026, 3, 1, 10, 5, 0, tzinfo=dt.timezone.utc)
        for bottom_id in ("bottom-a", "bottom-b"):
            output_path = workspace_root / "renders" / "pose-a" / f"top-a__{bottom_id}.png"
            output_path.parent.mkdir(parents=True, exist_ok=True)
            output_path.write_bytes(bottom_id.encode("utf-8"))
            os.utime(output_path, (completed_at.timestamp(), completed_at.timestamp()))

        dataset = Dataset(
            root=workspace_root,
            poses=[Pose(pose_id="pose-a", name="Pose A", path=pose_path)],
            items_by_category={
                "top": [Item(item_id="top-a", name="Top A", category="top", path=top_path)],
                "bottom": [
                    Item(item_id="bottom-a", name="Bottom A", category="bottom", path=bottom_a_path),
                    Item(item_id="bottom-b", name="Bottom B", category="bottom", path=bottom_b_path),
                ],
                "headwear": [],
                "shoes": [],
            },
            regenerate_items=[
                RegenerateItemRequest(
                    category="top",
                    item_id="top-a",
                    requested_at=request_time,
                )
            ],
        )

        _prune_completed_regeneration_requests(
            dataset=dataset,
            workspace_root=workspace_root,
            image_format="png",
            overlay_format="png",
            successful_render_keys=set(),
            successful_overlay_keys=set(),
        )

        assert dataset.regenerate_items == []
        assert dataset.regenerate_targets == []


def test_render_overlays_uses_existing_render_as_primary_reference(monkeypatch) -> None:
    with tempfile.TemporaryDirectory() as tmp_dir:
        workspace_root = Path(tmp_dir)
        tmp_input_dir = workspace_root / "_inputs"
        pose_path = workspace_root / "poses" / "pose-a" / "pose.png"
        hat_path = workspace_root / "items" / "headwear" / "hat-a" / "item.png"
        render_path = workspace_root / "renders" / "pose-a" / "top-a__bottom-a.webp"

        for path in (pose_path, hat_path):
            path.parent.mkdir(parents=True, exist_ok=True)
            Image.new("RGB", (32, 32), "white").save(path)

        render_path.parent.mkdir(parents=True, exist_ok=True)
        Image.new("RGB", (32, 32), "gray").save(render_path)

        dataset = Dataset(
            root=workspace_root,
            poses=[Pose(pose_id="pose-a", name="Pose A", path=pose_path)],
            items_by_category={
                "top": [],
                "bottom": [],
                "headwear": [
                    Item(item_id="hat-a", name="Hat A", category="headwear", path=hat_path)
                ],
                "shoes": [],
            },
        )

        captured: dict[str, Path] = {}

        class FakeRenderer:
            def render(self, request) -> None:
                captured["render_pose_path"] = Path(request.pose_path)
                captured["render_accessory_path"] = Path(request.image2_path)
                captured["render_geometry_path"] = Path(request.image3_path)
                Path(request.output_path).parent.mkdir(parents=True, exist_ok=True)
                Image.new("RGB", (32, 32), "black").save(request.output_path)

        def fake_build_overlay_band_from_rendered(**kwargs):
            captured["overlay_base_path"] = Path(kwargs["base_path"])
            kwargs["output_path"].parent.mkdir(parents=True, exist_ok=True)
            Image.new("RGBA", (32, 32), (0, 0, 0, 0)).save(kwargs["output_path"])
            return [0.0, 0.0, 1.0, 1.0]

        monkeypatch.setattr(
            "wardrobe_gen.cli.build_overlay_band_from_rendered",
            fake_build_overlay_band_from_rendered,
        )

        count = _render_overlays(
            config={
                "images": {"image_format": "webp"},
                "render": {"overlay_crop": {"cutout_mode": "sam_vit_h"}},
            },
            pose=dataset.poses[0],
            dataset=dataset,
            workspace_root=workspace_root,
            progress_root=workspace_root,
            renderer=FakeRenderer(),
            tmp_dir=tmp_input_dir,
            overlay_format="png",
            negative_prompt="",
            prompts={"overlay_headwear": "hat", "overlay_shoes": "shoes"},
            seed=123,
            quality={"steps": 4, "cfg": 1.0, "sampler": "euler", "scheduler": "normal"},
            output_size=(32, 32),
            input_megapixels=1.0,
            force=True,
            max_images=None,
            rendered_count=0,
            include_overlay_previews=False,
        )

        assert count == 1
        assert captured["render_pose_path"] == render_path
        assert captured["render_accessory_path"] == hat_path
        assert captured["render_geometry_path"] == render_path
        assert captured["overlay_base_path"] == render_path


def test_select_representative_overlay_render_prefers_median_like_headwear_roi() -> None:
    with tempfile.TemporaryDirectory() as tmp_dir:
        root = Path(tmp_dir)
        paths = [
            root / "a-first.webp",
            root / "b-mid.webp",
            root / "c-late.webp",
        ]
        top_values = [0, 128, 130]
        for path, top_value in zip(paths, top_values):
            image = Image.new("L", (32, 32), color=255)
            for y in range(8):
                for x in range(32):
                    image.putpixel((x, y), top_value)
            image.save(path)

        selected = _select_representative_overlay_render(paths, "headwear")

        assert selected == paths[1]


def test_sample_overlay_reference_candidates_limits_large_render_sets() -> None:
    paths = [Path(f"/tmp/render-{index:03d}.webp") for index in range(200)]

    sampled = _sample_overlay_reference_candidates(paths)

    assert len(sampled) == 48
    assert sampled[0] == paths[0]
    assert sampled[-1] == paths[-1]
    assert len(set(sampled)) == len(sampled)


def test_sample_overlay_preview_candidates_limits_large_render_sets() -> None:
    paths = [Path(f"/tmp/render-{index:03d}.webp") for index in range(200)]

    sampled = _sample_overlay_preview_candidates(paths)

    assert len(sampled) == 5
    assert sampled[0] == paths[0]
    assert sampled[-1] == paths[-1]
    assert len(set(sampled)) == len(sampled)


def test_render_overlays_uses_first_render_for_headwear(monkeypatch) -> None:
    with tempfile.TemporaryDirectory() as tmp_dir:
        workspace_root = Path(tmp_dir)
        tmp_input_dir = workspace_root / "_inputs"
        pose_path = workspace_root / "poses" / "pose-a" / "pose.png"
        hat_path = workspace_root / "items" / "headwear" / "hat-a" / "item.png"
        render_paths = [
            workspace_root / "renders" / "pose-a" / "a-first.webp",
            workspace_root / "renders" / "pose-a" / "b-mid.webp",
            workspace_root / "renders" / "pose-a" / "c-late.webp",
        ]

        for path in (pose_path, hat_path):
            path.parent.mkdir(parents=True, exist_ok=True)
            Image.new("RGB", (32, 32), "white").save(path)

        top_values = [0, 128, 130]
        for path, top_value in zip(render_paths, top_values):
            path.parent.mkdir(parents=True, exist_ok=True)
            image = Image.new("L", (32, 32), color=255)
            for y in range(8):
                for x in range(32):
                    image.putpixel((x, y), top_value)
            image.save(path)

        dataset = Dataset(
            root=workspace_root,
            poses=[Pose(pose_id="pose-a", name="Pose A", path=pose_path)],
            items_by_category={
                "top": [],
                "bottom": [],
                "headwear": [
                    Item(item_id="hat-a", name="Hat A", category="headwear", path=hat_path)
                ],
                "shoes": [],
            },
        )

        captured: dict[str, Path] = {}

        class FakeRenderer:
            def render(self, request) -> None:
                captured["render_pose_path"] = Path(request.pose_path)
                Path(request.output_path).parent.mkdir(parents=True, exist_ok=True)
                Image.new("RGB", (32, 32), "black").save(request.output_path)

        def fake_build_overlay_band_from_rendered(**kwargs):
            captured["overlay_base_path"] = Path(kwargs["base_path"])
            kwargs["output_path"].parent.mkdir(parents=True, exist_ok=True)
            Image.new("RGBA", (32, 32), (0, 0, 0, 0)).save(kwargs["output_path"])
            return [0.0, 0.0, 1.0, 1.0]

        monkeypatch.setattr(
            "wardrobe_gen.cli.build_overlay_band_from_rendered",
            fake_build_overlay_band_from_rendered,
        )

        count = _render_overlays(
            config={
                "images": {"image_format": "webp"},
                "render": {"overlay_crop": {"cutout_mode": "sam_vit_h"}},
            },
            pose=dataset.poses[0],
            dataset=dataset,
            workspace_root=workspace_root,
            progress_root=workspace_root,
            renderer=FakeRenderer(),
            tmp_dir=tmp_input_dir,
            overlay_format="png",
            negative_prompt="",
            prompts={"overlay_headwear": "hat", "overlay_shoes": "shoes"},
            seed=123,
            quality={"steps": 4, "cfg": 1.0, "sampler": "euler", "scheduler": "normal"},
            output_size=(32, 32),
            input_megapixels=1.0,
            force=True,
            max_images=None,
            rendered_count=0,
            include_overlay_previews=False,
        )

        assert count == 1
        assert captured["render_pose_path"] == render_paths[0]
        assert captured["overlay_base_path"] == render_paths[0]


def test_render_overlays_limits_overlay_previews_to_representative_sample(
    monkeypatch,
) -> None:
    with tempfile.TemporaryDirectory() as tmp_dir:
        workspace_root = Path(tmp_dir)
        tmp_input_dir = workspace_root / "_inputs"
        pose_path = workspace_root / "poses" / "pose-a" / "pose.png"
        hat_path = workspace_root / "items" / "headwear" / "hat-a" / "item.png"
        render_paths = [
            workspace_root / "renders" / "pose-a" / f"render-{index:03d}.webp"
            for index in range(7)
        ]

        for path in (pose_path, hat_path):
            path.parent.mkdir(parents=True, exist_ok=True)
            Image.new("RGB", (32, 32), "white").save(path)

        for index, path in enumerate(render_paths):
            path.parent.mkdir(parents=True, exist_ok=True)
            Image.new("RGB", (32, 32), color=(index, index, index)).save(path)

        dataset = Dataset(
            root=workspace_root,
            poses=[Pose(pose_id="pose-a", name="Pose A", path=pose_path)],
            items_by_category={
                "top": [],
                "bottom": [],
                "headwear": [
                    Item(item_id="hat-a", name="Hat A", category="headwear", path=hat_path)
                ],
                "shoes": [],
            },
        )

        class FakeRenderer:
            def render(self, request) -> None:
                Path(request.output_path).parent.mkdir(parents=True, exist_ok=True)
                Image.new("RGB", (32, 32), "black").save(request.output_path)

        def fake_build_overlay_band_from_rendered(**kwargs):
            kwargs["output_path"].parent.mkdir(parents=True, exist_ok=True)
            Image.new("RGBA", (32, 32), (255, 0, 0, 127)).save(kwargs["output_path"])
            return [0.0, 0.0, 1.0, 1.0]

        monkeypatch.setattr(
            "wardrobe_gen.cli.build_overlay_band_from_rendered",
            fake_build_overlay_band_from_rendered,
        )

        count = _render_overlays(
            config={
                "images": {"image_format": "webp"},
                "render": {"overlay_crop": {"cutout_mode": "sam_vit_h"}},
            },
            pose=dataset.poses[0],
            dataset=dataset,
            workspace_root=workspace_root,
            progress_root=workspace_root,
            renderer=FakeRenderer(),
            tmp_dir=tmp_input_dir,
            overlay_format="png",
            negative_prompt="",
            prompts={"overlay_headwear": "hat", "overlay_shoes": "shoes"},
            seed=123,
            quality={"steps": 4, "cfg": 1.0, "sampler": "euler", "scheduler": "normal"},
            output_size=(32, 32),
            input_megapixels=1.0,
            force=True,
            max_images=None,
            rendered_count=0,
            include_overlay_previews=True,
        )

        preview_dir = workspace_root / "overlay_previews" / "pose-a" / "headwear"
        preview_paths = sorted(preview_dir.glob("*.png"))

        assert count == 1
        assert [path.name for path in preview_paths] == [
            "render-000__hat-a.png",
            "render-002__hat-a.png",
            "render-003__hat-a.png",
            "render-004__hat-a.png",
            "render-006__hat-a.png",
        ]


def test_render_all_batches_overlay_flux_before_cutouts(monkeypatch, capsys) -> None:
    with tempfile.TemporaryDirectory() as tmp_dir:
        workspace_root = Path(tmp_dir)
        pose_paths = [
            workspace_root / "poses" / "pose-a" / "pose.png",
            workspace_root / "poses" / "pose-b" / "pose.png",
        ]
        top_path = workspace_root / "items" / "top" / "top-a" / "item.png"
        bottom_path = workspace_root / "items" / "bottom" / "bottom-a" / "item.png"
        hat_path = workspace_root / "items" / "headwear" / "hat-a" / "item.png"

        for path in [*pose_paths, top_path, bottom_path, hat_path]:
            path.parent.mkdir(parents=True, exist_ok=True)
            Image.new("RGB", (32, 32), "white").save(path)

        dataset = Dataset(
            root=workspace_root,
            poses=[
                Pose(pose_id="pose-a", name="Pose A", path=pose_paths[0]),
                Pose(pose_id="pose-b", name="Pose B", path=pose_paths[1]),
            ],
            items_by_category={
                "top": [Item(item_id="top-a", name="Top A", category="top", path=top_path)],
                "bottom": [
                    Item(item_id="bottom-a", name="Bottom A", category="bottom", path=bottom_path)
                ],
                "headwear": [
                    Item(item_id="hat-a", name="Hat A", category="headwear", path=hat_path)
                ],
                "shoes": [],
            },
        )

        events: list[str] = []

        class FakeRenderer:
            def render(self, request) -> None:
                events.append(str(request.render_type))
                Path(request.output_path).parent.mkdir(parents=True, exist_ok=True)
                Image.new("RGB", (32, 32), "black").save(request.output_path)

        def fake_build_overlay_band_from_rendered(**kwargs):
            events.append(f"cutout:{kwargs['category']}")
            kwargs["output_path"].parent.mkdir(parents=True, exist_ok=True)
            Image.new("RGBA", (32, 32), (0, 0, 0, 0)).save(kwargs["output_path"])
            return [0.0, 0.0, 1.0, 1.0]

        monkeypatch.setattr(
            "wardrobe_gen.cli.build_overlay_band_from_rendered",
            fake_build_overlay_band_from_rendered,
        )

        _render_all(
            Namespace(
                input_megapixels=None,
                steps=None,
                cfg=None,
                sampler=None,
                pose=None,
                top=None,
                bottom=None,
                force=False,
                max_images=None,
                include_overlay_previews=False,
            ),
            {
                "images": {
                    "output_size": [32, 32],
                    "image_format": "png",
                    "overlay_format": "png",
                    "input_megapixels": 1.0,
                },
                "quality": {
                        "steps": 4,
                        "cfg": 1.0,
                        "sampler": "euler",
                        "scheduler": "normal",
                    },
                "render": {
                    "prompts": {
                        "base": "base",
                        "base_top": "top",
                        "base_bottom": "bottom",
                        "overlay_headwear": "hat",
                        "overlay_shoes": "shoes",
                    },
                    "negative_prompt": "",
                    "seed": 123,
                    "overlay_crop": {"cutout_mode": "sam_vit_h"},
                },
            },
            dataset,
            workspace_root,
            FakeRenderer(),
            repo_root=workspace_root.parent,
        )

        first_overlay = events.index("overlay_headwear")
        first_cutout = events.index("cutout:headwear")

        assert all(event in {"bottom_base", "top_final"} for event in events[:first_overlay])
        assert all(event == "overlay_headwear" for event in events[first_overlay:first_cutout])
        assert all(event == "cutout:headwear" for event in events[first_cutout:])

        output = capsys.readouterr().out
        assert "phase=base_renders mode=flux" in output
        assert "phase=overlay_renders mode=flux" in output
        assert "phase=overlay_cutouts mode=dinoground+sam" in output
        assert f"{workspace_root.name}/renders/pose-a/top-a__bottom-a.png" in output


def test_render_all_uses_random_seeds_when_no_seed_is_configured(monkeypatch) -> None:
    with tempfile.TemporaryDirectory() as tmp_dir:
        workspace_root = Path(tmp_dir)
        pose_path = workspace_root / "poses" / "pose-a" / "pose.png"
        top_path = workspace_root / "items" / "top" / "top-a" / "item.png"
        bottom_path = workspace_root / "items" / "bottom" / "bottom-a" / "item.png"

        for path in (pose_path, top_path, bottom_path):
            path.parent.mkdir(parents=True, exist_ok=True)
            Image.new("RGB", (32, 32), "white").save(path)

        dataset = Dataset(
            root=workspace_root,
            poses=[Pose(pose_id="pose-a", name="Pose A", path=pose_path)],
            items_by_category={
                "top": [Item(item_id="top-a", name="Top A", category="top", path=top_path)],
                "bottom": [
                    Item(item_id="bottom-a", name="Bottom A", category="bottom", path=bottom_path)
                ],
                "headwear": [],
                "shoes": [],
            },
        )

        seeds = iter([111, 222])
        monkeypatch.setattr("wardrobe_gen.cli.random.randrange", lambda upper: next(seeds))

        captured: list[tuple[str, int]] = []

        class FakeRenderer:
            def render(self, request) -> None:
                captured.append((str(request.render_type), int(request.seed)))
                Path(request.output_path).parent.mkdir(parents=True, exist_ok=True)
                Image.new("RGB", (32, 32), "black").save(request.output_path)

        _render_all(
            Namespace(
                input_megapixels=None,
                seed=None,
                steps=None,
                cfg=None,
                sampler=None,
                pose=None,
                top=None,
                bottom=None,
                force=False,
                max_images=None,
                include_overlay_previews=False,
            ),
            {
                "images": {
                    "output_size": [32, 32],
                    "image_format": "png",
                    "overlay_format": "png",
                    "input_megapixels": 1.0,
                },
                "quality": {
                        "steps": 4,
                        "cfg": 1.0,
                        "sampler": "euler",
                        "scheduler": "normal",
                    },
                "render": {
                    "prompts": {
                        "base": "base",
                        "base_top": "top",
                        "base_bottom": "bottom",
                    },
                    "negative_prompt": "",
                },
            },
            dataset,
            workspace_root,
            FakeRenderer(),
        )

        assert captured == [("bottom_base", 111), ("top_final", 222)]


def test_render_all_uses_derived_seeds_when_seed_is_configured() -> None:
    with tempfile.TemporaryDirectory() as tmp_dir:
        workspace_root = Path(tmp_dir)
        pose_path = workspace_root / "poses" / "pose-a" / "pose.png"
        top_path = workspace_root / "items" / "top" / "top-a" / "item.png"
        bottom_path = workspace_root / "items" / "bottom" / "bottom-a" / "item.png"

        for path in (pose_path, top_path, bottom_path):
            path.parent.mkdir(parents=True, exist_ok=True)
            Image.new("RGB", (32, 32), "white").save(path)

        dataset = Dataset(
            root=workspace_root,
            poses=[Pose(pose_id="pose-a", name="Pose A", path=pose_path)],
            items_by_category={
                "top": [Item(item_id="top-a", name="Top A", category="top", path=top_path)],
                "bottom": [
                    Item(item_id="bottom-a", name="Bottom A", category="bottom", path=bottom_path)
                ],
                "headwear": [],
                "shoes": [],
            },
        )

        captured: list[tuple[str, int]] = []

        class FakeRenderer:
            def render(self, request) -> None:
                captured.append((str(request.render_type), int(request.seed)))
                Path(request.output_path).parent.mkdir(parents=True, exist_ok=True)
                Image.new("RGB", (32, 32), "black").save(request.output_path)

        def hash32(text: str) -> int:
            return int.from_bytes(hashlib.md5(text.encode("utf-8")).digest()[:4], "little")

        _render_all(
            Namespace(
                input_megapixels=None,
                seed=None,
                steps=None,
                cfg=None,
                sampler=None,
                pose=None,
                top=None,
                bottom=None,
                force=False,
                max_images=None,
                include_overlay_previews=False,
            ),
            {
                "images": {
                    "output_size": [32, 32],
                    "image_format": "png",
                    "overlay_format": "png",
                    "input_megapixels": 1.0,
                },
                "quality": {
                        "steps": 4,
                        "cfg": 1.0,
                        "sampler": "euler",
                        "scheduler": "normal",
                    },
                "render": {
                    "prompts": {
                        "base": "base",
                        "base_top": "top",
                        "base_bottom": "bottom",
                    },
                    "negative_prompt": "",
                    "seed": 123,
                },
            },
            dataset,
            workspace_root,
            FakeRenderer(),
        )

        assert captured == [
            ("bottom_base", (123 + hash32("bottom|pose-a|bottom-a")) % (2**31)),
            ("top_final", (123 + hash32("top|pose-a|top-a|bottom-a")) % (2**31)),
        ]
