from __future__ import annotations

import tempfile
from pathlib import Path

from PIL import Image

from wardrobe_gen.dataset import Pose
from wardrobe_gen.output_size import resolve_output_size


def test_resolve_output_size_returns_configured_size_when_dynamic_disabled() -> None:
    images_cfg = {
        "output_size": [1080, 1920],
        "dynamic_output_size": {"enabled": False},
    }

    resolved = resolve_output_size(images_cfg=images_cfg, poses=[])

    assert resolved == (1080, 1920)


def test_resolve_output_size_uses_pose_aspect_and_megapixel_cap() -> None:
    with tempfile.TemporaryDirectory() as tmp_dir:
        pose_path = Path(tmp_dir) / "pose.png"
        Image.new("RGB", (1170, 2532), color=(40, 80, 130)).save(pose_path, format="PNG")
        pose = Pose(pose_id="pose-a", name="Pose A", path=pose_path)

        images_cfg = {
            "output_size": [1080, 1920],
            "dynamic_output_size": {
                "enabled": True,
                "max_megapixels": 1.0,
                "size_multiple": 64,
            },
        }

        resolved = resolve_output_size(images_cfg=images_cfg, poses=[pose])

        assert resolved[0] % 64 == 0
        assert resolved[1] % 64 == 0
        assert resolved[0] * resolved[1] <= 1_000_000
        target_aspect = 1170 / 2532
        assert abs((resolved[0] / resolved[1]) - target_aspect) < 0.08


def test_resolve_output_size_uses_explicit_aspect_ratio_without_pose_images() -> None:
    images_cfg = {
        "output_size": [1080, 1920],
        "dynamic_output_size": {
            "enabled": True,
            "max_megapixels": 1.5,
            "aspect_ratio": 1.0,
            "size_multiple": 64,
        },
    }

    resolved = resolve_output_size(images_cfg=images_cfg, poses=[])

    assert resolved[0] == resolved[1]
    assert resolved[0] * resolved[1] <= 1_500_000
