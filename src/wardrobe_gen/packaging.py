from __future__ import annotations

import zipfile
from collections.abc import Iterable, Mapping
from pathlib import Path
from typing import Any

from PIL import Image, ImageOps

from .dataset import Dataset, pose_thumbnail_output_path, thumbnail_output_path


def build_thumbnails(
    dataset: Dataset,
    workspace_root: Path,
    thumbnail_size: tuple[int, int],
    thumbnail_format: str,
) -> None:
    for pose in dataset.poses:
        thumb_path = pose_thumbnail_output_path(
            workspace_root,
            pose.pose_id,
            thumbnail_format,
        )
        if thumb_path.exists():
            continue
        _write_thumbnail(
            source_path=pose.path,
            output_path=thumb_path,
            thumbnail_size=thumbnail_size,
            thumbnail_format=thumbnail_format,
        )

    for category, items in dataset.items_by_category.items():
        for item in items:
            thumb_path = thumbnail_output_path(
                workspace_root,
                category,
                item.item_id,
                thumbnail_format,
            )
            if thumb_path.exists():
                continue
            _write_thumbnail(
                source_path=item.path,
                output_path=thumb_path,
                thumbnail_size=thumbnail_size,
                thumbnail_format=thumbnail_format,
            )


_ZIP_TIMESTAMP = (1980, 1, 1, 0, 0, 0)
_ZIP_FILE_MODE = 0o100644 << 16


def build_zip(
    workspace_root: Path,
    zip_path: Path,
    manifest: Mapping[str, Any],
) -> Path:
    zip_path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        for path in _iter_assets(workspace_root, manifest):
            relative_path = path.relative_to(workspace_root).as_posix()
            info = zipfile.ZipInfo(relative_path, date_time=_ZIP_TIMESTAMP)
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = _ZIP_FILE_MODE
            info.create_system = 3
            zf.writestr(info, path.read_bytes())
    return zip_path


def _iter_assets(
    workspace_root: Path,
    manifest: Mapping[str, Any],
) -> Iterable[Path]:
    assets: set[Path] = set()

    for folder in ["poses", "items"]:
        root = workspace_root / folder
        if root.exists():
            assets.update(path for path in root.rglob("*") if path.is_file())

    for collection_name in ("renders", "overlays"):
        collection = manifest.get(collection_name, [])
        if not isinstance(collection, list):
            raise ValueError(f"Manifest field '{collection_name}' must be a list.")
        for entry in collection:
            if not isinstance(entry, Mapping):
                raise ValueError(
                    f"Manifest field '{collection_name}' contains a non-object entry."
                )
            for field in ("path", "meta_path"):
                relative_path = entry.get(field)
                if relative_path is None:
                    continue
                asset_path = _resolve_manifest_asset(
                    workspace_root,
                    str(relative_path),
                    field=f"{collection_name}.{field}",
                )
                if not asset_path.is_file():
                    raise FileNotFoundError(
                        f"Manifest references missing asset: {relative_path}"
                    )
                assets.add(asset_path)

    manifest_path = workspace_root / "wardrobe.json"
    if manifest_path.exists():
        assets.add(manifest_path)

    yield from sorted(
        assets,
        key=lambda path: path.relative_to(workspace_root).as_posix(),
    )


def _resolve_manifest_asset(workspace_root: Path, value: str, *, field: str) -> Path:
    relative_path = Path(value)
    if relative_path.is_absolute() or ".." in relative_path.parts:
        raise ValueError(f"Manifest field '{field}' contains an unsafe path: {value}")
    return workspace_root / relative_path


def _write_thumbnail(
    source_path: Path,
    output_path: Path,
    thumbnail_size: tuple[int, int],
    thumbnail_format: str,
) -> None:
    image = Image.open(source_path)
    image = image.convert("RGB")
    thumb = ImageOps.contain(image, thumbnail_size)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    fmt_key = thumbnail_format.lower()
    if fmt_key == "jpg":
        fmt = "JPEG"
    elif fmt_key == "jpeg":
        fmt = "JPEG"
    else:
        fmt = thumbnail_format.upper()
    thumb.save(output_path, format=fmt)
