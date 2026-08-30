from __future__ import annotations

import importlib.util
import json
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import requests

from .config import discover_config_path, resolve_path
from .renderers.comfyui import ComfyUIRenderer


@dataclass(frozen=True)
class DoctorCheck:
    name: str
    ok: bool
    detail: str


def run_doctor(config: dict[str, Any], *, cwd: Path | None = None) -> list[DoctorCheck]:
    base_dir = (cwd or Path.cwd()).resolve()
    checks = [_check_config(config, base_dir), _check_workflow(config, base_dir)]
    checks.extend(_check_ollama(config))
    checks.extend(_check_comfyui(config))
    checks.extend(_check_cutout(config, base_dir))
    return checks


def print_doctor_report(
    checks: list[DoctorCheck], *, explicit_config: str | Path | None = None
) -> bool:
    config_path = discover_config_path(explicit_config)
    source = str(config_path) if config_path else "built-in defaults"
    print(f"Configuration: {source}")
    for check in checks:
        marker = "OK" if check.ok else "FAIL"
        print(f"[{marker}] {check.name}: {check.detail}")
    passed = all(check.ok for check in checks)
    print("Doctor completed successfully." if passed else "Doctor found setup problems.")
    return passed


def _check_config(config: dict[str, Any], base_dir: Path) -> DoctorCheck:
    checkpoint = resolve_path(base_dir, config["cutout"]["sam_checkpoint"])
    return DoctorCheck(
        "Configuration",
        True,
        f"valid; SAM checkpoint resolves to {checkpoint}",
    )


def _check_workflow(config: dict[str, Any], base_dir: Path) -> DoctorCheck:
    workflow_path = resolve_path(base_dir, config["workflow_template"])
    if not workflow_path.is_file():
        return DoctorCheck("FLUX.2 workflow", False, f"not found: {workflow_path}")
    try:
        json.loads(workflow_path.read_text(encoding="utf-8"))
        ComfyUIRenderer(config, workflow_path)
    except (OSError, ValueError, TypeError, json.JSONDecodeError) as exc:
        return DoctorCheck("FLUX.2 workflow", False, f"invalid: {exc}")
    return DoctorCheck("FLUX.2 workflow", True, f"valid: {workflow_path.name}")


def _check_ollama(config: dict[str, Any]) -> list[DoctorCheck]:
    vlm = config["vlm"]
    endpoint = str(vlm["endpoint"]).rstrip("/")
    expected = str(vlm["model"])
    try:
        response = requests.get(f"{endpoint}/api/tags", timeout=10)
        response.raise_for_status()
        payload = response.json()
        names = {
            str(model.get("name") or model.get("model") or "")
            for model in payload.get("models", [])
            if isinstance(model, dict)
        }
    except (requests.RequestException, ValueError, TypeError) as exc:
        return [DoctorCheck("Ollama", False, f"unreachable at {endpoint}: {exc}")]

    installed = expected in names or any(
        name.split(":", 1)[0] == expected.split(":", 1)[0] for name in names
    )
    detail = (
        f"model available: {expected}"
        if installed
        else f"missing {expected}; run: ollama pull {expected}"
    )
    return [DoctorCheck("Ollama", installed, detail)]


def _check_comfyui(config: dict[str, Any]) -> list[DoctorCheck]:
    endpoint = str(config["comfyui"]["endpoint"]).rstrip("/")
    expected = [
        str(config["flux_model"]["unet"]),
        str(config["flux_model"]["clip_name"]),
        str(config["flux_model"]["vae_name"]),
    ]
    try:
        response = requests.get(f"{endpoint}/object_info", timeout=20)
        response.raise_for_status()
        payload = response.json()
        serialized = json.dumps(payload)
    except (requests.RequestException, ValueError, TypeError) as exc:
        return [
            DoctorCheck("ComfyUI", False, f"unreachable at {endpoint}: {exc}")
        ]

    missing = [name for name in expected if name not in serialized]
    detail = (
        "required FLUX.2 [klein] 4B files are available"
        if not missing
        else "missing model files: " + ", ".join(missing)
    )
    return [DoctorCheck("ComfyUI", not missing, detail)]


def _check_cutout(config: dict[str, Any], base_dir: Path) -> list[DoctorCheck]:
    required_modules = ("torch", "transformers", "segment_anything")
    missing_modules = [
        name for name in required_modules if importlib.util.find_spec(name) is None
    ]
    dependency_check = DoctorCheck(
        "Cutout dependencies",
        not missing_modules,
        (
            "PyTorch, Transformers, and Segment Anything are installed"
            if not missing_modules
            else "missing " + ", ".join(missing_modules) + "; run uv sync --extra ml"
        ),
    )

    checkpoint = resolve_path(base_dir, config["cutout"]["sam_checkpoint"])
    checkpoint_check = DoctorCheck(
        "SAM ViT-H checkpoint",
        checkpoint.is_file(),
        str(checkpoint) if checkpoint.is_file() else f"not found: {checkpoint}",
    )

    model_id = str(config["cutout"]["grounding_dino_model"])
    allow_download = bool(config["cutout"].get("allow_download", False))
    cache_root = _hugging_face_cache_root()
    cache_name = "models--" + model_id.replace("/", "--")
    cached = (cache_root / cache_name).is_dir()
    grounding_ready = not missing_modules and (cached or allow_download)
    if cached:
        cache_detail = f"cached: {model_id}"
    elif allow_download:
        cache_detail = f"{model_id}; first download is enabled"
    else:
        cache_detail = (
            f"{model_id} is not cached; set cutout.allow_download: true for the "
            "first run"
        )
    cache_check = DoctorCheck("GroundingDINO", grounding_ready, cache_detail)
    return [dependency_check, checkpoint_check, cache_check]


def _hugging_face_cache_root() -> Path:
    explicit_hub = os.environ.get("HF_HUB_CACHE")
    if explicit_hub:
        return Path(explicit_hub).expanduser()
    hf_home = os.environ.get("HF_HOME")
    if hf_home:
        return Path(hf_home).expanduser() / "hub"
    xdg_cache = os.environ.get("XDG_CACHE_HOME")
    if xdg_cache:
        return Path(xdg_cache).expanduser() / "huggingface" / "hub"
    return Path.home() / ".cache" / "huggingface" / "hub"
