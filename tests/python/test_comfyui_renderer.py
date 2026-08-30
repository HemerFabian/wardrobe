from __future__ import annotations

import json
from pathlib import Path

from wardrobe_gen.config import load_config
from wardrobe_gen.render_types import RenderRequest
from wardrobe_gen.renderers.comfyui import ComfyUIRenderer


def _make_renderer(tmp_path: Path) -> ComfyUIRenderer:
    workflow = {
        "1": {"class_type": "LoadImage", "inputs": {"image": "base.png"}},
        "2": {"class_type": "LoadImage", "inputs": {"image": "final.png"}},
        "3": {
            "class_type": "SaveImage",
            "inputs": {"images": ["2", 0], "filename_prefix": "main"},
        },
        "4": {
            "class_type": "SaveImage",
            "inputs": {"images": ["2", 0], "filename_prefix": "headwear mask"},
        },
        "5": {
            "class_type": "SaveImage",
            "inputs": {"images": ["2", 0], "filename_prefix": "masks/shoes.png"},
        },
    }
    workflow_path = tmp_path / "workflow.json"
    workflow_path.write_text(json.dumps(workflow), encoding="utf-8")

    config = {
        "comfyui": {
            "endpoint": "http://example.invalid",
            "upload_images": False,
            "input_copy_dir": "",
        },
        "workflow_nodes": {
            "load_pose": 1,
            "load_ref1": 2,
            "save": 3,
        },
    }
    return ComfyUIRenderer(config, workflow_path)


def test_build_workflow_preserves_semantic_secondary_prefixes(tmp_path: Path) -> None:
    renderer = _make_renderer(tmp_path)
    request = RenderRequest(
        render_type="overlay",
        pose_path=tmp_path / "base.png",
        image2_path=tmp_path / "final.png",
        image3_path=tmp_path / "unused.png",
        output_path=tmp_path / "result.webp",
        prompt="",
        negative_prompt="",
        seed=1,
        steps=4,
        cfg=1.0,
        sampler="euler",
        scheduler="normal",
        size=(512, 512),
        input_megapixels=1.0,
    )

    workflow = renderer._build_workflow(request)

    assert workflow["3"]["inputs"]["filename_prefix"] == "result"
    assert workflow["4"]["inputs"]["filename_prefix"] == "result__headwear_mask"
    assert workflow["5"]["inputs"]["filename_prefix"] == "result__masks_shoes_png"


def test_additional_output_path_uses_downloaded_filename() -> None:
    output_path = Path("/tmp/result.webp")

    resolved = ComfyUIRenderer._additional_output_path(
        output_path=output_path,
        node_id="17",
        index=1,
        image_info={"filename": "result__headwear_mask_00001_.png"},
    )

    assert resolved == output_path.with_name("result__headwear_mask_00001_.png")


def test_public_config_matches_bundled_workflow_nodes(tmp_path: Path) -> None:
    repo_root = Path(__file__).resolve().parents[2]
    config = load_config(cwd=tmp_path)
    config["comfyui"]["upload_images"] = False
    workflow_path = repo_root / "src/wardrobe_gen/workflows/flux2_klein_4b_edit.json"
    renderer = ComfyUIRenderer(config, workflow_path)
    request = RenderRequest(
        render_type="base",
        pose_path=tmp_path / "pose.png",
        image2_path=tmp_path / "top.png",
        image3_path=tmp_path / "bottom.png",
        output_path=tmp_path / "result.webp",
        prompt="Replace the outfit.",
        negative_prompt="Keep the pose.",
        seed=7,
        steps=4,
        cfg=1.0,
        sampler="euler",
        scheduler="normal",
        size=(512, 512),
        input_megapixels=1.0,
    )

    workflow = renderer._build_workflow(request)

    assert renderer.uses_subgraphs
    assert not renderer.supports_reference_image3()
    assert workflow["76"]["inputs"]["image"] == str(request.pose_path)
    assert workflow["81"]["inputs"]["image"] == str(request.image2_path)
    assert workflow["94"]["inputs"]["filename_prefix"] == "result"

    loaders = {
        node["class_type"]: node["inputs"]
        for node in workflow.values()
        if node.get("class_type") in {"UNETLoader", "CLIPLoader", "VAELoader"}
    }
    assert loaders["UNETLoader"]["unet_name"] == "flux-2-klein-4b-fp8.safetensors"
    assert loaders["CLIPLoader"]["clip_name"] == "qwen_3_4b.safetensors"
    assert loaders["VAELoader"]["vae_name"] == "flux2-vae.safetensors"

    prompt_nodes = [
        node
        for node in workflow.values()
        if node.get("class_type") == "CLIPTextEncode"
    ]
    assert any(node["inputs"].get("text") == request.prompt for node in prompt_nodes)
