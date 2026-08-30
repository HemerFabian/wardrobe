from __future__ import annotations

import hashlib
import json
import os
import tempfile
import zipfile
from pathlib import Path

import pytest

from wardrobe_gen.packaging import build_zip


def _write(path: Path, content: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content)


def _fixture(root: Path) -> dict[str, object]:
    _write(root / "poses/pose-a/pose.png", b"pose")
    _write(root / "poses/pose-a/pose.yaml", b"pose_id: pose-a\n")
    _write(root / "items/top/top-a/image.png", b"top")
    _write(root / "items/top/top-a/item.yaml", b"item_id: top-a\n")
    _write(root / "renders/pose-a/top-a__bottom-a.webp", b"current-render")
    _write(root / "renders/pose-a/top-a__bottom-a.yaml", b"render-meta")
    _write(root / "renders/pose-a/top-a__bottom-a.png", b"stale-render")
    _write(root / "overlays/pose-a/headwear/hat-a.png", b"current-overlay")
    _write(root / "overlays/pose-a/headwear/hat-a.yaml", b"overlay-meta")
    _write(root / "overlays/pose-a/headwear/hat-a.webp", b"stale-overlay")

    manifest: dict[str, object] = {
        "schema_version": 5,
        "renders": [
            {
                "path": "renders/pose-a/top-a__bottom-a.webp",
                "meta_path": "renders/pose-a/top-a__bottom-a.yaml",
            }
        ],
        "overlays": [
            {
                "path": "overlays/pose-a/headwear/hat-a.png",
                "meta_path": "overlays/pose-a/headwear/hat-a.yaml",
            }
        ],
    }
    (root / "wardrobe.json").write_text(json.dumps(manifest), encoding="utf-8")
    return manifest


def test_build_zip_is_deterministic_and_excludes_stale_outputs() -> None:
    with tempfile.TemporaryDirectory() as tmp_dir:
        root = Path(tmp_dir)
        manifest = _fixture(root)
        first_zip = root / "first.zip"
        second_zip = root / "second.zip"

        build_zip(root, first_zip, manifest)
        for path in (root / "poses").rglob("*"):
            if path.is_file():
                os.utime(path, (2_000_000_000, 2_000_000_000))
        build_zip(root, second_zip, manifest)

        assert hashlib.sha256(first_zip.read_bytes()).digest() == hashlib.sha256(
            second_zip.read_bytes()
        ).digest()

        with zipfile.ZipFile(first_zip) as archive:
            names = archive.namelist()
            assert names == sorted(names)
            assert "renders/pose-a/top-a__bottom-a.webp" in names
            assert "renders/pose-a/top-a__bottom-a.png" not in names
            assert "overlays/pose-a/headwear/hat-a.png" in names
            assert "overlays/pose-a/headwear/hat-a.webp" not in names
            assert all(
                info.date_time == (1980, 1, 1, 0, 0, 0)
                for info in archive.infolist()
            )


def test_build_zip_rejects_unsafe_manifest_paths() -> None:
    with tempfile.TemporaryDirectory() as tmp_dir:
        root = Path(tmp_dir)
        (root / "wardrobe.json").write_text("{}", encoding="utf-8")
        manifest = {
            "renders": [{"path": "../private.png"}],
            "overlays": [],
        }

        with pytest.raises(ValueError, match="unsafe path"):
            build_zip(root, root / "pack.zip", manifest)
