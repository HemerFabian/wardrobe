from __future__ import annotations

import datetime as dt
import os
import tempfile
from pathlib import Path

from PIL import Image

from wardrobe_gen.dataset import (
    Dataset,
    Item,
    Pose,
    RegenerateItemRequest,
    RegenerateTargetRequest,
)
from wardrobe_gen.result_manifest import build_result_manifest


class TestResultManifestThumbnail:
    def test_build_manifest_generates_missing_pose_and_item_thumbnails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            workspace_root = Path(tmp_dir)
            pose_image = workspace_root / "input_pose.png"
            item_image = workspace_root / "input_top.png"

            Image.new("RGB", (120, 200), color=(200, 80, 80)).save(pose_image, format="PNG")
            Image.new("RGB", (90, 90), color=(80, 120, 200)).save(item_image, format="PNG")

            dataset = Dataset(
                root=workspace_root,
                poses=[
                    Pose(
                        pose_id="pose-a",
                        name="Pose A",
                        path=pose_image,
                        thumb_path=None,
                    ),
                ],
                items_by_category={
                    "top": [
                        Item(
                            item_id="top-a",
                            name="Top A",
                            category="top",
                            path=item_image,
                            thumb_path=None,
                        ),
                    ],
                    "bottom": [],
                    "headwear": [],
                    "shoes": [],
                },
            )

            config = {
                "images": {
                    "output_size": [1080, 1920],
                    "image_format": "png",
                    "overlay_format": "png",
                    "thumbnail_size": [64, 64],
                    "thumbnail_format": "jpg",
                },
                "render": {},
            }

            payload = build_result_manifest(dataset, workspace_root, config)

            pose_thumb_path = workspace_root / "poses" / "pose-a" / "thumb.jpg"
            item_thumb_path = workspace_root / "items" / "top" / "top-a" / "thumb.jpg"

            assert pose_thumb_path.exists(), "pose thumbnail should be generated"
            assert item_thumb_path.exists(), "item thumbnail should be generated"
            assert payload["schema_version"] == 5
            assert payload["intake_queue"] == []

            assert payload["poses"][0]["thumb_path"] == "poses/pose-a/thumb.jpg"
            assert payload["categories"]["top"][0]["thumb_path"] == "items/top/top-a/thumb.jpg"
            assert payload["categories"]["top"][0]["name"] == "Top A"
            assert "classification" in payload["categories"]["top"][0]
            assert "color_primary" in payload["categories"]["top"][0]

    def test_build_manifest_carries_regeneration_queue(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            workspace_root = Path(tmp_dir)
            pose_image = workspace_root / "input_pose.png"
            top_image = workspace_root / "input_top.png"
            bottom_image = workspace_root / "input_bottom.png"

            Image.new("RGB", (120, 200), color=(200, 80, 80)).save(pose_image, format="PNG")
            Image.new("RGB", (90, 90), color=(80, 120, 200)).save(top_image, format="PNG")
            Image.new("RGB", (90, 90), color=(80, 160, 120)).save(bottom_image, format="PNG")

            dataset = Dataset(
                root=workspace_root,
                poses=[
                    Pose(
                        pose_id="pose-a",
                        name="Pose A",
                        path=pose_image,
                    ),
                ],
                items_by_category={
                    "top": [
                        Item(
                            item_id="top-a",
                            name="Top A",
                            category="top",
                            path=top_image,
                        ),
                    ],
                    "bottom": [
                        Item(
                            item_id="bottom-a",
                            name="Bottom A",
                            category="bottom",
                            path=bottom_image,
                        ),
                    ],
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
                        type="render",
                        pose_id="pose-a",
                        top_id="top-a",
                        bottom_id="bottom-a",
                        requested_at="2026-03-01T10:05:00Z",
                    )
                ],
            )

            config = {
                "images": {
                    "output_size": [1080, 1920],
                    "image_format": "png",
                    "overlay_format": "png",
                    "thumbnail_size": [64, 64],
                    "thumbnail_format": "jpg",
                },
                "render": {},
            }

            payload = build_result_manifest(dataset, workspace_root, config)

            assert payload["regeneration"]["items"] == [
                {
                    "category": "top",
                    "item_id": "top-a",
                    "requested_at": "2026-03-01T10:00:00Z",
                }
            ]
            assert payload["regeneration"]["targets"] == [
                {
                    "type": "render",
                    "pose_id": "pose-a",
                    "top_id": "top-a",
                    "bottom_id": "bottom-a",
                    "requested_at": "2026-03-01T10:05:00Z",
                }
            ]

    def test_build_manifest_prunes_completed_regeneration_queue(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            workspace_root = Path(tmp_dir)
            pose_image = workspace_root / "input_pose.png"
            top_image = workspace_root / "input_top.png"
            bottom_image = workspace_root / "input_bottom.png"
            render_image = workspace_root / "renders" / "pose-a" / "top-a__bottom-a.webp"
            overlay_image = (
                workspace_root / "overlays" / "pose-a" / "headwear" / "hat-a.webp"
            )

            Image.new("RGB", (120, 200), color=(200, 80, 80)).save(pose_image, format="PNG")
            Image.new("RGB", (90, 90), color=(80, 120, 200)).save(top_image, format="PNG")
            Image.new("RGB", (90, 90), color=(80, 160, 120)).save(bottom_image, format="PNG")
            render_image.parent.mkdir(parents=True, exist_ok=True)
            overlay_image.parent.mkdir(parents=True, exist_ok=True)
            Image.new("RGB", (1080, 1920), color=(10, 20, 30)).save(render_image, format="WEBP")
            Image.new("RGBA", (256, 256), color=(255, 0, 0, 255)).save(
                overlay_image,
                format="WEBP",
            )

            completed_at = dt.datetime(2026, 3, 1, 10, 10, 0, tzinfo=dt.timezone.utc)
            os.utime(render_image, (completed_at.timestamp(), completed_at.timestamp()))
            os.utime(overlay_image, (completed_at.timestamp(), completed_at.timestamp()))

            dataset = Dataset(
                root=workspace_root,
                poses=[
                    Pose(
                        pose_id="pose-a",
                        name="Pose A",
                        path=pose_image,
                    ),
                ],
                items_by_category={
                    "top": [
                        Item(
                            item_id="top-a",
                            name="Top A",
                            category="top",
                            path=top_image,
                        ),
                    ],
                    "bottom": [
                        Item(
                            item_id="bottom-a",
                            name="Bottom A",
                            category="bottom",
                            path=bottom_image,
                        ),
                    ],
                    "headwear": [
                        Item(
                            item_id="hat-a",
                            name="Hat A",
                            category="headwear",
                            path=top_image,
                        ),
                    ],
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
                        type="render",
                        pose_id="pose-a",
                        top_id="top-a",
                        bottom_id="bottom-a",
                        requested_at="2026-03-01T10:05:00Z",
                    ),
                    RegenerateTargetRequest(
                        type="overlay",
                        pose_id="pose-a",
                        category="headwear",
                        item_id="hat-a",
                        requested_at="2026-03-01T10:05:00Z",
                    ),
                ],
            )

            config = {
                "images": {
                    "output_size": [1080, 1920],
                    "image_format": "png",
                    "overlay_format": "png",
                    "thumbnail_size": [64, 64],
                    "thumbnail_format": "jpg",
                },
                "render": {},
            }

            payload = build_result_manifest(dataset, workspace_root, config)

            assert payload["regeneration"] == {"items": [], "targets": []}
