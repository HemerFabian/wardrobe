from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class RenderRequest:
    render_type: str
    pose_path: Path
    image2_path: Path
    image3_path: Path
    output_path: Path
    prompt: str
    negative_prompt: str
    seed: int
    steps: int
    cfg: float
    sampler: str
    scheduler: str
    size: tuple[int, int]
    input_megapixels: float
