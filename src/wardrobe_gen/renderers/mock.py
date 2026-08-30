from __future__ import annotations

from pathlib import Path
from typing import Tuple

from PIL import Image, ImageOps

from ..image_utils import ensure_parent, load_image, resize_to_canvas
from ..render_types import RenderRequest


class MockRenderer:
    def __init__(self, config: dict) -> None:
        reference_crops = ((config.get("render") or {}).get("reference_crops") or {})
        self.overlay_reference_crops = {
            "headwear": tuple(reference_crops.get("headwear", [0.0, 0.0, 1.0, 0.25])),
            "shoes": tuple(reference_crops.get("shoes", [0.0, 0.82, 1.0, 0.18])),
        }

    def render(self, request: RenderRequest) -> Path:
        if request.render_type == "base":
            image = self._render_base(request)
        else:
            image = self._render_overlay(request)
        ensure_parent(request.output_path)
        image.save(request.output_path)
        return request.output_path

    def _render_base(self, request: RenderRequest) -> Image.Image:
        pose = load_image(request.pose_path, mode="RGB")
        pose = resize_to_canvas(pose, request.size)
        canvas = pose.copy()

        width, height = request.size
        top_box = self._region_box(width, height, (0.2, 0.18, 0.6, 0.38))
        bottom_box = self._region_box(width, height, (0.2, 0.56, 0.6, 0.38))

        top = load_image(request.image2_path, mode="RGB")
        bottom = load_image(request.image3_path, mode="RGB")

        self._paste_into(canvas, top, top_box)
        self._paste_into(canvas, bottom, bottom_box)
        return canvas

    def _render_overlay(self, request: RenderRequest) -> Image.Image:
        pose = load_image(request.pose_path, mode="RGBA")
        pose = resize_to_canvas(pose, request.size)
        canvas = Image.new("RGBA", pose.size, (0, 0, 0, 0))

        region = self._overlay_region(request)
        region_box = self._region_box(request.size[0], request.size[1], region)
        item = load_image(request.image2_path, mode="RGBA")
        self._paste_into(canvas, item, region_box)
        return canvas

    def _overlay_region(self, request: RenderRequest) -> Tuple[float, float, float, float]:
        if request.render_type == "overlay_headwear":
            return self.overlay_reference_crops["headwear"]
        if request.render_type == "overlay_shoes":
            return self.overlay_reference_crops["shoes"]
        return (0.2, 0.2, 0.6, 0.6)

    @staticmethod
    def _region_box(width: int, height: int, region: Tuple[float, float, float, float]) -> Tuple[int, int, int, int]:
        x, y, w, h = region
        return (
            int(width * x),
            int(height * y),
            max(1, int(width * w)),
            max(1, int(height * h)),
        )

    @staticmethod
    def _paste_into(canvas: Image.Image, item: Image.Image, box: Tuple[int, int, int, int]) -> None:
        x, y, w, h = box
        resized = ImageOps.contain(item, (w, h))
        offset = (x + (w - resized.width) // 2, y + (h - resized.height) // 2)
        if resized.mode == "RGBA":
            canvas.paste(resized, offset, resized)
        else:
            canvas.paste(resized, offset)
