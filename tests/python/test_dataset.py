from __future__ import annotations

import json
from pathlib import Path

from PIL import Image

from wardrobe_gen.dataset import scan_dataset


def _write_image(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    Image.new("RGB", (4, 4), "white").save(path)


def test_scan_dataset_ignores_intake_paths_outside_workspace(tmp_path: Path) -> None:
    workspace = tmp_path / "workspace"
    (workspace / "items" / "intake_queue").mkdir(parents=True)
    (workspace / "poses").mkdir()
    outside_image = tmp_path / "private.png"
    _write_image(outside_image)
    (workspace / "wardrobe.json").write_text(
        json.dumps(
            {
                "schema_version": 5,
                "intake_queue": [
                    {"id": "unsafe", "path": "../private.png"},
                    {"id": "absolute", "path": str(outside_image)},
                ],
            }
        ),
        encoding="utf-8",
    )

    dataset = scan_dataset(workspace, ["top", "bottom", "headwear", "shoes"])

    assert dataset.intake_queue == []


def test_scan_dataset_ignores_workspace_symlinks_to_external_files(
    tmp_path: Path,
) -> None:
    workspace = tmp_path / "workspace"
    queue_dir = workspace / "items" / "intake_queue"
    queue_dir.mkdir(parents=True)
    (workspace / "poses").mkdir()
    outside_image = tmp_path / "private.png"
    _write_image(outside_image)
    linked_image = queue_dir / "linked" / "image.png"
    linked_image.parent.mkdir()
    linked_image.symlink_to(outside_image)
    (workspace / "wardrobe.json").write_text(
        json.dumps(
            {
                "schema_version": 5,
                "intake_queue": [
                    {
                        "id": "linked",
                        "path": "items/intake_queue/linked/image.png",
                    }
                ],
            }
        ),
        encoding="utf-8",
    )

    dataset = scan_dataset(workspace, ["top", "bottom", "headwear", "shoes"])

    assert dataset.intake_queue == []
