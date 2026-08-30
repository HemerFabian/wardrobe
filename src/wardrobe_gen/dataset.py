from __future__ import annotations

import json
import re
import unicodedata
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable

try:
    import yaml  # type: ignore
except Exception:  # pragma: no cover
    yaml = None

IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp"}
IMAGE_EXTS_ORDERED = (".jpg", ".jpeg", ".png", ".webp")


@dataclass(frozen=True)
class Pose:
    pose_id: str
    name: str
    path: Path
    thumb_path: Path | None = None
    meta_path: Path | None = None
    neck_y: float | None = None
    ankle_y: float | None = None
    render_ready: bool = True


@dataclass(frozen=True)
class ClassificationInfo:
    provider: str
    model: str
    classified_at: str
    prompt_version: str


@dataclass(frozen=True)
class Item:
    item_id: str
    name: str
    category: str
    path: Path
    thumb_path: Path | None = None
    meta_path: Path | None = None
    subcategory: str | None = None
    color_primary: str | None = None
    material: str | None = None
    style_occasion: str | None = None
    pattern_design: str | None = None
    tags: tuple[str, ...] = ()
    classification: ClassificationInfo | None = None
    render_ready: bool = True


@dataclass(frozen=True)
class PendingIntakeItem:
    item_id: str
    path: Path
    thumb_path: Path | None = None
    meta_path: Path | None = None
    created_at: str | None = None


@dataclass(frozen=True)
class RegenerateItemRequest:
    category: str
    item_id: str
    requested_at: str


@dataclass(frozen=True)
class RegenerateTargetRequest:
    type: str
    requested_at: str
    pose_id: str | None = None
    category: str | None = None
    item_id: str | None = None
    top_id: str | None = None
    bottom_id: str | None = None

    @property
    def key(
        self,
    ) -> tuple[str, str | None, str | None, str | None, str | None, str | None]:
        return (
            self.type,
            self.pose_id,
            self.category,
            self.item_id,
            self.top_id,
            self.bottom_id,
        )


@dataclass
class Dataset:
    root: Path
    poses: list[Pose]
    items_by_category: dict[str, list[Item]]
    intake_queue: list[PendingIntakeItem] = field(default_factory=list)
    regenerate_items: list[RegenerateItemRequest] = field(default_factory=list)
    regenerate_targets: list[RegenerateTargetRequest] = field(default_factory=list)
    manifest_schema_version: int | None = None


_slug_pattern = re.compile(r"[^a-z0-9]+")


def slugify(value: str) -> str:
    normalized = unicodedata.normalize("NFKD", value)
    ascii_value = normalized.encode("ascii", "ignore").decode("ascii")
    lowered = ascii_value.lower()
    collapsed = _slug_pattern.sub("-", lowered).strip("-")
    return collapsed or "item"


def _unique_slug(base: str, existing: set[str]) -> str:
    candidate = base
    counter = 2
    while candidate in existing:
        candidate = f"{base}-{counter}"
        counter += 1
    existing.add(candidate)
    return candidate


def _iter_images(path: Path) -> Iterable[Path]:
    if not path.exists():
        return []
    return sorted(
        [
            candidate
            for candidate in path.iterdir()
            if candidate.is_file()
            and not candidate.is_symlink()
            and candidate.suffix.lower() in IMAGE_EXTS
        ]
    )


def _iter_subdirs(path: Path) -> Iterable[Path]:
    if not path.exists():
        return []
    return sorted(
        [
            candidate
            for candidate in path.iterdir()
            if candidate.is_dir() and not candidate.is_symlink()
        ]
    )


def scan_dataset(root: Path, categories: Iterable[str]) -> Dataset:
    if (root / "items").exists() and (root / "poses").exists():
        return _scan_workspace(root, categories)
    return _scan_legacy(root, categories)


def _scan_workspace(root: Path, categories: Iterable[str]) -> Dataset:
    poses_root = root / "poses"
    items_root = root / "items"
    manifest = _load_manifest(root)
    manifest_schema = _manifest_schema_version(manifest)

    poses: list[Pose] = []
    pose_ids: set[str] = set()
    for pose_dir in _iter_subdirs(poses_root):
        pose_meta_path = pose_dir / "pose.yaml"
        pose_meta = _load_structured_data(pose_meta_path)

        pose_path = _find_named_image(pose_dir, "pose") or _first_image_in_dir(pose_dir)
        if pose_path is None:
            continue

        pose_id = _unique_slug(
            slugify(str(pose_meta.get("id") or pose_dir.name)),
            pose_ids,
        )
        pose_name = str(pose_meta.get("name") or _humanize(pose_id))

        thumb_path = _find_named_image(pose_dir, "thumb")
        if thumb_path is None:
            candidate = pose_meta.get("thumb_path")
            if isinstance(candidate, str) and candidate:
                resolved = _resolve_workspace_path(root, candidate)
                if resolved is not None and resolved.exists():
                    thumb_path = resolved

        poses.append(
            Pose(
                pose_id=pose_id,
                name=pose_name,
                path=pose_path,
                thumb_path=thumb_path,
                meta_path=pose_meta_path if pose_meta_path.exists() else None,
                neck_y=_to_optional_float(pose_meta.get("neck_y")),
                ankle_y=_to_optional_float(pose_meta.get("ankle_y")),
                render_ready=bool(pose_meta.get("render_ready", True)),
            )
        )

    items_by_category: dict[str, list[Item]] = {}
    for category in categories:
        category_root = items_root / category
        items: list[Item] = []
        item_ids: set[str] = set()

        for item_dir in _iter_subdirs(category_root):
            item_meta_path = item_dir / "item.yaml"
            item_meta = _load_structured_data(item_meta_path)

            image_path = _find_named_image(item_dir, "image") or _first_image_in_dir(
                item_dir
            )
            if image_path is None:
                continue

            item_id = _unique_slug(
                slugify(str(item_meta.get("id") or item_dir.name)),
                item_ids,
            )
            item_name = str(
                _to_optional_str(item_meta.get("name")) or _humanize(item_id)
            )

            thumb_path = _find_named_image(item_dir, "thumb")
            if thumb_path is None:
                candidate = item_meta.get("thumb_path")
                if isinstance(candidate, str) and candidate:
                    resolved = _resolve_workspace_path(root, candidate)
                    if resolved is not None and resolved.exists():
                        thumb_path = resolved

            raw_tags = item_meta.get("tags")
            tags: tuple[str, ...]
            if isinstance(raw_tags, list):
                tags = tuple(str(tag) for tag in raw_tags)
            else:
                tags = ()

            items.append(
                Item(
                    item_id=item_id,
                    name=item_name,
                    category=category,
                    path=image_path,
                    thumb_path=thumb_path,
                    meta_path=item_meta_path if item_meta_path.exists() else None,
                    subcategory=_to_optional_str(item_meta.get("subcategory")),
                    color_primary=_to_optional_str(
                        item_meta.get("color_primary", item_meta.get("color"))
                    ),
                    material=_to_optional_str(item_meta.get("material")),
                    style_occasion=_to_optional_str(item_meta.get("style_occasion")),
                    pattern_design=_to_optional_str(item_meta.get("pattern_design")),
                    tags=tags,
                    classification=_parse_classification_info(
                        item_meta.get("classification")
                    ),
                    render_ready=bool(item_meta.get("render_ready", True)),
                )
            )
        items_by_category[category] = items

    intake_queue = _parse_intake_queue_from_manifest(manifest, root)
    if not intake_queue:
        intake_queue = _scan_intake_queue_fallback(root)
    regenerate_items, regenerate_targets = _parse_regeneration_from_manifest(manifest)

    return Dataset(
        root=root,
        poses=poses,
        items_by_category=items_by_category,
        intake_queue=intake_queue,
        regenerate_items=regenerate_items,
        regenerate_targets=regenerate_targets,
        manifest_schema_version=manifest_schema,
    )


def _scan_legacy(root: Path, categories: Iterable[str]) -> Dataset:
    poses_dir = root / "poses"
    clothes_dir = root / "clothes"

    pose_ids: set[str] = set()
    poses: list[Pose] = []
    for image_path in _iter_images(poses_dir):
        pose_id = _unique_slug(slugify(image_path.stem), pose_ids)
        poses.append(
            Pose(
                pose_id=pose_id,
                name=_humanize(pose_id),
                path=image_path,
            )
        )

    items_by_category: dict[str, list[Item]] = {}
    for category in categories:
        category_dir = clothes_dir / category
        items: list[Item] = []
        item_ids: set[str] = set()
        for image_path in _iter_images(category_dir):
            item_id = _unique_slug(slugify(image_path.stem), item_ids)
            items.append(
                Item(
                    item_id=item_id,
                    name=_humanize(item_id),
                    category=category,
                    path=image_path,
                )
            )
        items_by_category[category] = items

    return Dataset(root=root, poses=poses, items_by_category=items_by_category)


def render_output_path(
    workspace_root: Path,
    pose_id: str,
    top_id: str,
    bottom_id: str,
    image_format: str,
) -> Path:
    return (
        workspace_root / "renders" / pose_id / f"{top_id}__{bottom_id}.{image_format}"
    )


def overlay_output_path(
    workspace_root: Path,
    pose_id: str,
    category: str,
    item_id: str,
    overlay_format: str,
) -> Path:
    return (
        workspace_root / "overlays" / pose_id / category / f"{item_id}.{overlay_format}"
    )


def thumbnail_output_path(
    workspace_root: Path,
    category: str,
    item_id: str,
    thumbnail_format: str,
) -> Path:
    folder = workspace_root / "items" / category / item_id
    return folder / f"thumb.{thumbnail_format}"


def pose_thumbnail_output_path(
    workspace_root: Path,
    pose_id: str,
    thumbnail_format: str,
) -> Path:
    folder = workspace_root / "poses" / pose_id
    return folder / f"thumb.{thumbnail_format}"


def render_meta_output_path(
    workspace_root: Path,
    pose_id: str,
    top_id: str,
    bottom_id: str,
) -> Path:
    return workspace_root / "renders" / pose_id / f"{top_id}__{bottom_id}.yaml"


def overlay_meta_output_path(
    workspace_root: Path,
    pose_id: str,
    category: str,
    item_id: str,
) -> Path:
    return workspace_root / "overlays" / pose_id / category / f"{item_id}.yaml"


def _load_structured_data(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    raw = path.read_text(encoding="utf-8").strip()
    if not raw:
        return {}

    if yaml is not None:
        data = yaml.safe_load(raw)
        if isinstance(data, dict):
            return data

    try:
        data = json.loads(raw)
        if isinstance(data, dict):
            return data
    except Exception:
        pass

    return {}


def _load_manifest(root: Path) -> dict[str, Any]:
    manifest_path = root / "wardrobe.json"
    if not manifest_path.exists():
        return {}
    try:
        data = json.loads(manifest_path.read_text(encoding="utf-8"))
    except Exception:
        return {}
    if isinstance(data, dict):
        return data
    return {}


def _manifest_schema_version(manifest: dict[str, Any]) -> int | None:
    raw = manifest.get("schema_version")
    if raw is None:
        return None
    try:
        return int(raw)
    except Exception:
        return None


def _parse_classification_info(value: Any) -> ClassificationInfo | None:
    if not isinstance(value, dict):
        return None
    provider = _to_optional_str(value.get("provider"))
    model = _to_optional_str(value.get("model"))
    classified_at = _to_optional_str(value.get("classified_at"))
    prompt_version = _to_optional_str(value.get("prompt_version"))
    if not provider or not model or not classified_at or not prompt_version:
        return None
    return ClassificationInfo(
        provider=provider,
        model=model,
        classified_at=classified_at,
        prompt_version=prompt_version,
    )


def _parse_intake_queue_from_manifest(
    manifest: dict[str, Any],
    root: Path,
) -> list[PendingIntakeItem]:
    raw_queue = manifest.get("intake_queue")
    if not isinstance(raw_queue, list):
        return []

    queue: list[PendingIntakeItem] = []
    seen_ids: set[str] = set()
    for index, entry in enumerate(raw_queue):
        if not isinstance(entry, dict):
            continue

        raw_id = _to_optional_str(entry.get("id")) or f"pending-{index + 1}"
        item_id = _unique_slug(slugify(raw_id), seen_ids)

        raw_path = _to_optional_str(entry.get("path"))
        if not raw_path:
            continue
        image_path = _resolve_workspace_path(root, raw_path)
        if image_path is None:
            continue
        if not image_path.exists() or not image_path.is_file():
            continue

        raw_thumb = _to_optional_str(entry.get("thumb_path"))
        thumb_path = _resolve_workspace_path(root, raw_thumb) if raw_thumb else None

        raw_meta = _to_optional_str(entry.get("meta_path"))
        meta_path = _resolve_workspace_path(root, raw_meta) if raw_meta else None

        queue.append(
            PendingIntakeItem(
                item_id=item_id,
                path=image_path,
                thumb_path=thumb_path,
                meta_path=meta_path,
                created_at=_to_optional_str(entry.get("created_at")),
            )
        )

    return queue


def _scan_intake_queue_fallback(root: Path) -> list[PendingIntakeItem]:
    queue_root = root / "items" / "intake_queue"
    if not queue_root.exists():
        return []

    queue: list[PendingIntakeItem] = []
    seen_ids: set[str] = set()
    for item_dir in _iter_subdirs(queue_root):
        image_path = _find_named_image(item_dir, "image") or _first_image_in_dir(
            item_dir
        )
        if image_path is None:
            continue

        item_id = _unique_slug(slugify(item_dir.name), seen_ids)
        meta_path = item_dir / "item.yaml"
        meta = _load_structured_data(meta_path)
        thumb = _find_named_image(item_dir, "thumb")
        created_at = _to_optional_str(meta.get("created_at"))

        queue.append(
            PendingIntakeItem(
                item_id=item_id,
                path=image_path,
                thumb_path=thumb,
                meta_path=meta_path if meta_path.exists() else None,
                created_at=created_at,
            )
        )
    return queue


def _parse_regeneration_from_manifest(
    manifest: dict[str, Any],
) -> tuple[list[RegenerateItemRequest], list[RegenerateTargetRequest]]:
    raw = manifest.get("regeneration")
    if not isinstance(raw, dict):
        return [], []

    items_by_key: dict[tuple[str, str], RegenerateItemRequest] = {}
    raw_items = raw.get("items")
    if isinstance(raw_items, list):
        for entry in raw_items:
            if not isinstance(entry, dict):
                continue
            category = _to_optional_str(entry.get("category"))
            item_id = _to_optional_str(entry.get("item_id"))
            if category not in {"top", "bottom", "headwear", "shoes"} or not item_id:
                continue
            items_by_key[(category, item_id)] = RegenerateItemRequest(
                category=category,
                item_id=item_id,
                requested_at=(_to_optional_str(entry.get("requested_at")) or ""),
            )

    targets_by_key: dict[
        tuple[str, str | None, str | None, str | None, str | None, str | None],
        RegenerateTargetRequest,
    ] = {}
    raw_targets = raw.get("targets")
    if isinstance(raw_targets, list):
        for entry in raw_targets:
            if not isinstance(entry, dict):
                continue
            request = _parse_regeneration_target_entry(entry)
            if request is None:
                continue
            targets_by_key[request.key] = request

    raw_outfits = raw.get("outfits")
    if isinstance(raw_outfits, list):
        for entry in raw_outfits:
            if not isinstance(entry, dict):
                continue
            pose_id = _to_optional_str(entry.get("pose_id"))
            top_id = _to_optional_str(entry.get("top_id"))
            bottom_id = _to_optional_str(entry.get("bottom_id"))
            if not pose_id or not top_id or not bottom_id:
                continue
            requested_at = _to_optional_str(entry.get("requested_at")) or ""
            render_request = RegenerateTargetRequest(
                type="render",
                pose_id=pose_id,
                top_id=top_id,
                bottom_id=bottom_id,
                requested_at=requested_at,
            )
            targets_by_key[render_request.key] = render_request

            headwear_id = _to_optional_str(entry.get("headwear_id"))
            if headwear_id:
                overlay_request = RegenerateTargetRequest(
                    type="overlay",
                    pose_id=pose_id,
                    category="headwear",
                    item_id=headwear_id,
                    requested_at=requested_at,
                )
                targets_by_key[overlay_request.key] = overlay_request

            shoes_id = _to_optional_str(entry.get("shoes_id"))
            if shoes_id:
                overlay_request = RegenerateTargetRequest(
                    type="overlay",
                    pose_id=pose_id,
                    category="shoes",
                    item_id=shoes_id,
                    requested_at=requested_at,
                )
                targets_by_key[overlay_request.key] = overlay_request

    return list(items_by_key.values()), list(targets_by_key.values())


def _parse_regeneration_target_entry(
    entry: dict[str, Any],
) -> RegenerateTargetRequest | None:
    request_type = _to_optional_str(entry.get("type"))
    requested_at = _to_optional_str(entry.get("requested_at")) or ""
    if request_type == "pose_item":
        pose_id = _to_optional_str(entry.get("pose_id"))
        category = _to_optional_str(entry.get("category"))
        item_id = _to_optional_str(entry.get("item_id"))
        if (
            not pose_id
            or category not in {"top", "bottom", "headwear", "shoes"}
            or not item_id
        ):
            return None
        return RegenerateTargetRequest(
            type=request_type,
            pose_id=pose_id,
            category=category,
            item_id=item_id,
            requested_at=requested_at,
        )
    if request_type == "render":
        pose_id = _to_optional_str(entry.get("pose_id"))
        top_id = _to_optional_str(entry.get("top_id"))
        bottom_id = _to_optional_str(entry.get("bottom_id"))
        if not pose_id or not top_id or not bottom_id:
            return None
        return RegenerateTargetRequest(
            type=request_type,
            pose_id=pose_id,
            top_id=top_id,
            bottom_id=bottom_id,
            requested_at=requested_at,
        )
    if request_type == "overlay":
        pose_id = _to_optional_str(entry.get("pose_id"))
        category = _to_optional_str(entry.get("category"))
        item_id = _to_optional_str(entry.get("item_id"))
        if not pose_id or category not in {"headwear", "shoes"} or not item_id:
            return None
        return RegenerateTargetRequest(
            type=request_type,
            pose_id=pose_id,
            category=category,
            item_id=item_id,
            requested_at=requested_at,
        )
    return None


def _resolve_workspace_path(root: Path, raw_path: str) -> Path | None:
    normalized = raw_path.strip().replace("\\", "/")
    if not normalized:
        return None
    relative_path = Path(normalized)
    if relative_path.is_absolute() or ".." in relative_path.parts:
        return None

    resolved_root = root.resolve()
    try:
        candidate = (resolved_root / relative_path).resolve()
        candidate.relative_to(resolved_root)
    except (OSError, RuntimeError, ValueError):
        return None
    return candidate


def _find_named_image(root: Path, stem: str) -> Path | None:
    for ext in IMAGE_EXTS_ORDERED:
        candidate = root / f"{stem}{ext}"
        if candidate.exists() and candidate.is_file() and not candidate.is_symlink():
            return candidate
    return None


def _first_image_in_dir(path: Path) -> Path | None:
    for image_path in _iter_images(path):
        return image_path
    return None


def _to_optional_str(value: Any) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    return text or None


def _to_optional_float(value: Any) -> float | None:
    if value is None:
        return None
    try:
        return float(value)
    except Exception:
        return None


def _humanize(value: str) -> str:
    words = [part for part in value.replace("-", " ").split(" ") if part]
    return " ".join(word[:1].upper() + word[1:] for word in words)
