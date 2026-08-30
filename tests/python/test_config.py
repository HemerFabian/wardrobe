from __future__ import annotations

from pathlib import Path

import pytest

from wardrobe_gen.config import DEFAULT_WORKFLOW, ConfigError, load_config


def test_load_config_uses_built_in_defaults_without_local_file(tmp_path: Path) -> None:
    config = load_config(cwd=tmp_path)

    assert config["renderer"] == "comfyui"
    assert config["workflow_template"] == str(DEFAULT_WORKFLOW)
    assert config["flux_model"] == {
        "unet": "flux-2-klein-4b-fp8.safetensors",
        "clip_name": "qwen_3_4b.safetensors",
        "vae_name": "flux2-vae.safetensors",
    }


def test_load_config_auto_loads_and_deep_merges_local_file(tmp_path: Path) -> None:
    (tmp_path / "config.local.yaml").write_text(
        "comfyui:\n  endpoint: http://127.0.0.1:8000\n",
        encoding="utf-8",
    )

    config = load_config(cwd=tmp_path)

    assert config["comfyui"]["endpoint"] == "http://127.0.0.1:8000"
    assert config["comfyui"]["timeout_sec"] == 1800


def test_explicit_config_wins_over_auto_discovery(tmp_path: Path) -> None:
    (tmp_path / "config.local.yaml").write_text(
        "renderer: mock\n", encoding="utf-8"
    )
    explicit = tmp_path / "alternate.yaml"
    explicit.write_text("renderer: comfyui\n", encoding="utf-8")

    config = load_config(explicit, cwd=tmp_path)

    assert config["renderer"] == "comfyui"


def test_explicit_missing_config_is_an_error(tmp_path: Path) -> None:
    with pytest.raises(ConfigError, match="Config not found"):
        load_config("missing.yaml", cwd=tmp_path)
