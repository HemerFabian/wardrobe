from __future__ import annotations

import base64
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import requests


class OllamaVLMError(RuntimeError):
    pass


@dataclass(frozen=True)
class OllamaVLMClient:
    endpoint: str
    model: str
    timeout_sec: int
    temperature: float

    def classify(self, image_path: Path, prompt: str) -> dict[str, Any]:
        if not image_path.exists():
            raise OllamaVLMError(f"Image not found: {image_path}")

        encoded_image = base64.b64encode(image_path.read_bytes()).decode("ascii")
        url = f"{self.endpoint.rstrip('/')}/api/chat"
        payload = {
            "model": self.model,
            "stream": False,
            "format": "json",
            "messages": [
                {
                    "role": "user",
                    "content": prompt,
                    "images": [encoded_image],
                }
            ],
            "options": {"temperature": self.temperature},
        }

        try:
            response = requests.post(url, json=payload, timeout=self.timeout_sec)
            response.raise_for_status()
            parsed = response.json()
        except requests.RequestException as error:
            raise OllamaVLMError(f"Ollama request failed: {error}") from error
        except json.JSONDecodeError as error:
            raise OllamaVLMError(f"Ollama returned non-JSON response: {error}") from error

        content = _extract_content(parsed)
        result = _extract_json(content)
        if not isinstance(result, dict):
            raise OllamaVLMError("Ollama response JSON is not an object.")
        return result


def _extract_content(payload: dict[str, Any]) -> str:
    message = payload.get("message")
    if isinstance(message, dict):
        content = message.get("content")
        if isinstance(content, str):
            return content

    raw_response = payload.get("response")
    if isinstance(raw_response, str):
        return raw_response

    raise OllamaVLMError("Ollama response does not include message content.")


def _extract_json(content: str) -> Any:
    stripped = content.strip()
    if not stripped:
        raise OllamaVLMError("Ollama returned empty content.")

    try:
        return json.loads(stripped)
    except json.JSONDecodeError:
        pass

    start = stripped.find("{")
    end = stripped.rfind("}")
    if start == -1 or end == -1 or end < start:
        raise OllamaVLMError("No JSON object found in Ollama response content.")

    try:
        return json.loads(stripped[start : end + 1])
    except json.JSONDecodeError as error:
        raise OllamaVLMError(f"Invalid JSON object in Ollama response: {error}") from error
