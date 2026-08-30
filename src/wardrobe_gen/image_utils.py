from __future__ import annotations

from pathlib import Path
from typing import Tuple

from PIL import Image, ImageOps


def load_image(path: Path, mode: str = "RGB") -> Image.Image:
    image = Image.open(path)
    if mode:
        image = image.convert(mode)
    return image


def resize_to_canvas(image: Image.Image, size: Tuple[int, int]) -> Image.Image:
    if image.size == size:
        return image
    contained = ImageOps.contain(image, size)
    canvas = Image.new(image.mode, size, (0, 0, 0))
    offset = ((size[0] - contained.size[0]) // 2, (size[1] - contained.size[1]) // 2)
    canvas.paste(contained, offset)
    return canvas


def ensure_parent(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


def save_image(image: Image.Image, path: Path, image_format: str) -> None:
    ensure_parent(path)
    image.save(path, format=image_format.upper())
