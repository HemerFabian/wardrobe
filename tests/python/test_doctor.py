from __future__ import annotations

import json
from pathlib import Path

from wardrobe_gen.config import load_config
from wardrobe_gen.doctor import run_doctor


class _Response:
    def __init__(self, payload: dict) -> None:
        self._payload = payload

    def raise_for_status(self) -> None:
        return None

    def json(self) -> dict:
        return self._payload


def test_doctor_accepts_available_local_services_and_models(
    tmp_path: Path, monkeypatch
) -> None:
    checkpoint = tmp_path / "sam.pth"
    checkpoint.write_bytes(b"checkpoint")
    config = load_config(cwd=tmp_path)
    config["cutout"]["sam_checkpoint"] = str(checkpoint)
    config["cutout"]["allow_download"] = True

    object_info = {
        "models": [
            "flux-2-klein-4b-fp8.safetensors",
            "qwen_3_4b.safetensors",
            "flux2-vae.safetensors",
        ]
    }

    def fake_get(url: str, timeout: int):
        del timeout
        if url.endswith("/api/tags"):
            return _Response({"models": [{"name": config["vlm"]["model"]}]})
        return _Response(object_info)

    monkeypatch.setattr("wardrobe_gen.doctor.requests.get", fake_get)
    monkeypatch.setattr(
        "wardrobe_gen.doctor.importlib.util.find_spec", lambda name: object()
    )

    checks = run_doctor(config, cwd=tmp_path)

    assert all(check.ok for check in checks), json.dumps(
        [check.__dict__ for check in checks], indent=2
    )


def test_doctor_reports_missing_comfyui_models(tmp_path: Path, monkeypatch) -> None:
    config = load_config(cwd=tmp_path)

    def fake_get(url: str, timeout: int):
        del timeout
        if url.endswith("/api/tags"):
            return _Response({"models": [{"name": config["vlm"]["model"]}]})
        return _Response({"models": []})

    monkeypatch.setattr("wardrobe_gen.doctor.requests.get", fake_get)

    checks = run_doctor(config, cwd=tmp_path)
    comfyui = next(check for check in checks if check.name == "ComfyUI")

    assert not comfyui.ok
    assert "flux-2-klein-4b-fp8.safetensors" in comfyui.detail
