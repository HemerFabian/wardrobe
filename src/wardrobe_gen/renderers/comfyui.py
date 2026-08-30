from __future__ import annotations

import copy
import io
import json
import time
from pathlib import Path
from typing import Any, Optional

import requests
from PIL import Image

from ..image_utils import ensure_parent
from ..render_types import RenderRequest


class ComfyUIError(RuntimeError):
    pass


class ComfyUIRenderer:
    def __init__(self, config: dict, workflow_path: Path) -> None:
        self.config = config
        self.endpoint = config["comfyui"]["endpoint"].rstrip("/")
        self.timeout_sec = int(config["comfyui"].get("timeout_sec", 900))
        self.poll_interval_sec = float(config["comfyui"].get("poll_interval_sec", 2))
        self.client_id = str(config["comfyui"].get("client_id", "wardrobe-gen"))
        self.input_copy_dir = config["comfyui"].get("input_copy_dir")
        self.upload_images = bool(config["comfyui"].get("upload_images", True))
        self.output_type = config["comfyui"].get("output_type", "output")
        self.nodes = config["workflow_nodes"]
        self.session = requests.Session()
        raw_template = json.loads(workflow_path.read_text(encoding="utf-8"))
        self.raw_template = raw_template
        self.subgraphs = self._extract_subgraphs(raw_template)
        self.uses_subgraphs = bool(self.subgraphs)
        self._supports_ref_image3 = self._detect_reference_image3_support(raw_template)
        self.template = (
            self._normalize_workflow(raw_template)
            if not self.uses_subgraphs
            else raw_template
        )

    def supports_reference_image3(self) -> bool:
        return self._supports_ref_image3

    def _detect_reference_image3_support(self, workflow: dict[str, Any]) -> bool:
        names_to_match = {
            "image3",
            "image_2",
            "reference_image3",
            "reference_image_3",
        }

        def _has_image3_input(nodes: list[dict[str, Any]]) -> bool:
            for node in nodes:
                inputs = node.get("inputs") or []
                if not isinstance(inputs, list):
                    continue
                for input_entry in inputs:
                    if not isinstance(input_entry, dict):
                        continue
                    name = str(input_entry.get("name") or "").strip().lower()
                    if name in names_to_match:
                        return True
            return False

        top_nodes = workflow.get("nodes") or []
        if isinstance(top_nodes, list) and _has_image3_input(top_nodes):
            return True

        definitions = workflow.get("definitions") or {}
        raw_subgraphs = definitions.get("subgraphs") or []
        if isinstance(raw_subgraphs, dict):
            subgraph_items = raw_subgraphs.values()
        elif isinstance(raw_subgraphs, list):
            subgraph_items = raw_subgraphs
        else:
            subgraph_items = []

        for subgraph in subgraph_items:
            if not isinstance(subgraph, dict):
                continue
            inputs = subgraph.get("inputs") or []
            if isinstance(inputs, list):
                for entry in inputs:
                    if not isinstance(entry, dict):
                        continue
                    name = str(entry.get("name") or "").strip().lower()
                    if name in names_to_match:
                        return True
            nodes = subgraph.get("nodes") or []
            if isinstance(nodes, list) and _has_image3_input(nodes):
                return True
        return False

    def _normalize_workflow(self, workflow: dict[str, Any]) -> dict[str, Any]:
        if "nodes" in workflow and "links" in workflow:
            return self._convert_workflow(workflow)
        return workflow

    def _extract_subgraphs(self, workflow: dict[str, Any]) -> dict[str, Any]:
        definitions = workflow.get("definitions") or {}
        raw = definitions.get("subgraphs") or []
        if isinstance(raw, dict):
            return {str(key): value for key, value in raw.items()}
        if isinstance(raw, list):
            return {
                str(item.get("id")): item
                for item in raw
                if isinstance(item, dict) and item.get("id")
            }
        return {}

    def _convert_workflow(self, workflow: dict[str, Any]) -> dict[str, Any]:
        skip_types = {"Note", "MarkdownNote"}

        # Build raw top-level link map (list-based links).
        raw_link_map: dict[int, tuple[str, int]] = {}
        for link in workflow.get("links", []):
            if isinstance(link, list) and len(link) >= 3:
                raw_link_map[int(link[0])] = (str(link[1]), int(link[2]))

        # Expand subgraph nodes into regular prompt nodes, capturing output redirects.
        max_node_id = 0
        for node in workflow.get("nodes", []):
            try:
                max_node_id = max(max_node_id, int(node.get("id")))
            except (TypeError, ValueError):
                continue
        next_node_id = max_node_id + 1

        expanded_prompt: dict[str, Any] = {}
        output_redirect: dict[tuple[str, int], tuple[str, int]] = {}
        for node in workflow.get("nodes", []):
            node_type = node.get("type")
            if node_type in skip_types:
                continue
            if isinstance(node_type, str) and node_type in self.subgraphs:
                node_id = str(node.get("id"))
                sub_prompt, outputs, next_node_id = self._expand_subgraph_instance(
                    node, self.subgraphs[node_type], raw_link_map, next_node_id
                )
                expanded_prompt.update(sub_prompt)
                for out_slot, mapping in outputs.items():
                    output_redirect[(node_id, int(out_slot))] = mapping

        # Build final link map, rewriting origins that came from expanded subgraphs.
        link_map: dict[int, tuple[str, int]] = {}
        for link in workflow.get("links", []):
            if not (isinstance(link, list) and len(link) >= 3):
                continue
            link_id = int(link[0])
            from_node = str(link[1])
            from_output = int(link[2])
            redirect = output_redirect.get((from_node, from_output))
            if redirect:
                from_node, from_output = redirect
            link_map[link_id] = (from_node, from_output)

        prompt: dict[str, Any] = dict(expanded_prompt)
        for node in workflow.get("nodes", []):
            node_id = str(node.get("id"))
            node_type = node.get("type")
            if node_type in skip_types:
                continue
            if isinstance(node_type, str) and node_type in self.subgraphs:
                continue

            inputs: dict[str, Any] = {}
            widget_values = list(node.get("widgets_values") or [])
            if node_type == "KSampler":
                widget_inputs = [
                    i for i in node.get("inputs", []) if i.get("widget") is not None
                ]
                if len(widget_values) > len(widget_inputs):
                    for seed_mode in ("randomize", "fixed", "increment", "decrement"):
                        if seed_mode in widget_values:
                            widget_values.remove(seed_mode)
                            break

            widget_index = 0
            for input_entry in node.get("inputs", []):
                name = input_entry.get("name")
                if not name or name == "upload":
                    continue
                link_id = input_entry.get("link")
                if link_id is not None:
                    source = link_map.get(int(link_id))
                    if source is not None:
                        inputs[name] = [source[0], source[1]]
                    if input_entry.get("widget") is not None and widget_index < len(
                        widget_values
                    ):
                        widget_index += 1
                    continue
                if input_entry.get("widget") is not None and widget_index < len(
                    widget_values
                ):
                    inputs[name] = widget_values[widget_index]
                    widget_index += 1

            prompt[node_id] = {"class_type": node_type, "inputs": inputs}

        return prompt

    def _expand_subgraph_instance(
        self,
        node: dict[str, Any],
        subgraph: dict[str, Any],
        parent_link_map: dict[int, tuple[str, int]],
        next_node_id: int,
    ) -> tuple[dict[str, Any], dict[int, tuple[str, int]], int]:
        values_by_name: dict[str, Any] = {}

        proxy_widgets = (node.get("properties") or {}).get("proxyWidgets") or []
        widget_values = list(node.get("widgets_values") or [])
        if isinstance(proxy_widgets, list):
            for index, entry in enumerate(proxy_widgets):
                if not (isinstance(entry, list) and len(entry) >= 2):
                    continue
                target_id, widget_name = str(entry[0]), str(entry[1])
                if target_id != "-1":
                    continue
                if index < len(widget_values):
                    values_by_name[widget_name] = widget_values[index]

        # Link-based inputs (typically IMAGE) come from parent links.
        for input_entry in node.get("inputs", []):
            name = input_entry.get("name")
            link_id = input_entry.get("link")
            if not name or link_id is None:
                continue
            source = parent_link_map.get(int(link_id))
            if source is not None:
                values_by_name[str(name)] = [source[0], source[1]]

        # Fallback widget mapping for any widget inputs not covered by proxyWidgets.
        widget_inputs = [
            i for i in node.get("inputs", []) if i.get("widget") is not None
        ]
        fallback_index = 0
        for input_entry in widget_inputs:
            name = str(input_entry.get("name"))
            if name in values_by_name:
                continue
            if fallback_index < len(widget_values):
                values_by_name[name] = widget_values[fallback_index]
                fallback_index += 1

        external_by_slot: dict[int, Any] = {}
        for slot, inp in enumerate(subgraph.get("inputs") or []):
            inp_name = str(inp.get("name"))
            if inp_name in values_by_name:
                external_by_slot[int(slot)] = values_by_name[inp_name]

        return self._convert_subgraph_definition(
            subgraph, external_by_slot, next_node_id
        )

    def _convert_subgraph_definition(
        self,
        subgraph: dict[str, Any],
        external_by_slot: dict[int, Any],
        next_node_id: int,
    ) -> tuple[dict[str, Any], dict[int, tuple[str, int]], int]:
        nodes = subgraph.get("nodes") or []
        links = subgraph.get("links") or []

        # Assign new IDs for all non-subgraph nodes in this definition.
        id_map: dict[int, str] = {}
        for internal in nodes:
            internal_type = internal.get("type")
            if isinstance(internal_type, str) and internal_type in self.subgraphs:
                continue
            internal_id = int(internal.get("id"))
            id_map[internal_id] = str(next_node_id)
            next_node_id += 1

        # Expand nested subgraph instances inside this definition.
        prompt: dict[str, Any] = {}
        nested_output_redirect: dict[tuple[int, int], tuple[str, int]] = {}

        link_origin: dict[int, tuple[int, int]] = {}
        for link in links:
            if isinstance(link, dict) and "id" in link:
                link_origin[int(link["id"])] = (
                    int(link.get("origin_id")),
                    int(link.get("origin_slot", 0)),
                )

        for internal in nodes:
            internal_type = internal.get("type")
            if not (isinstance(internal_type, str) and internal_type in self.subgraphs):
                continue

            values_by_name: dict[str, Any] = {}
            for input_entry in internal.get("inputs", []):
                name = input_entry.get("name")
                link_id = input_entry.get("link")
                if not name or link_id is None:
                    continue
                origin_id, origin_slot = link_origin.get(int(link_id), (None, None))
                if origin_id is None:
                    continue
                if int(origin_id) == -10:
                    values_by_name[str(name)] = external_by_slot.get(int(origin_slot))
                else:
                    redirect = nested_output_redirect.get(
                        (int(origin_id), int(origin_slot))
                    )
                    if redirect:
                        values_by_name[str(name)] = [redirect[0], redirect[1]]
                    else:
                        values_by_name[str(name)] = [
                            id_map[int(origin_id)],
                            int(origin_slot),
                        ]

            nested_external_by_slot: dict[int, Any] = {}
            nested_def = self.subgraphs[internal_type]
            for slot, inp in enumerate(nested_def.get("inputs") or []):
                inp_name = str(inp.get("name"))
                if inp_name in values_by_name:
                    nested_external_by_slot[int(slot)] = values_by_name[inp_name]

            nested_prompt, nested_outputs, next_node_id = (
                self._convert_subgraph_definition(
                    nested_def, nested_external_by_slot, next_node_id
                )
            )
            prompt.update(nested_prompt)
            internal_id = int(internal.get("id"))
            for out_slot, mapping in nested_outputs.items():
                nested_output_redirect[(internal_id, int(out_slot))] = mapping

        # Map links to their source node in the flattened prompt graph.
        link_map: dict[int, tuple[Any, int]] = {}
        for link in links:
            if not isinstance(link, dict) or "id" not in link:
                continue
            link_id = int(link["id"])
            origin_id = int(link.get("origin_id"))
            origin_slot = int(link.get("origin_slot", 0))
            redirect = nested_output_redirect.get((origin_id, origin_slot))
            if redirect:
                link_map[link_id] = (redirect[0], redirect[1])
            else:
                link_map[link_id] = (origin_id, origin_slot)

        output_map: dict[int, tuple[str, int]] = {}
        for link in links:
            if not isinstance(link, dict) or "id" not in link:
                continue
            if int(link.get("target_id")) != -20:
                continue
            slot = int(link.get("target_slot", 0))
            origin_id = int(link.get("origin_id"))
            origin_slot = int(link.get("origin_slot", 0))
            redirect = nested_output_redirect.get((origin_id, origin_slot))
            if redirect:
                output_map[slot] = redirect
            else:
                output_map[slot] = (id_map[origin_id], origin_slot)

        # Convert regular nodes into prompt format.
        for internal in nodes:
            internal_type = internal.get("type")
            if isinstance(internal_type, str) and internal_type in self.subgraphs:
                continue

            new_id = id_map[int(internal.get("id"))]
            inputs: dict[str, Any] = {}

            widget_values = list(internal.get("widgets_values") or [])
            widget_inputs = [
                i for i in internal.get("inputs", []) if i.get("widget") is not None
            ]
            if len(widget_values) > len(widget_inputs):
                for seed_mode in ("randomize", "fixed", "increment", "decrement"):
                    if seed_mode in widget_values:
                        widget_values.remove(seed_mode)
                        break

            widget_index = 0
            for input_entry in internal.get("inputs", []):
                name = input_entry.get("name")
                if not name:
                    continue
                link_id = input_entry.get("link")
                if link_id is not None:
                    origin_id, origin_slot = link_map[int(link_id)]
                    if isinstance(origin_id, int) and origin_id == -10:
                        inputs[str(name)] = external_by_slot.get(int(origin_slot))
                        if input_entry.get("widget") is not None and widget_index < len(
                            widget_values
                        ):
                            widget_index += 1
                        continue
                    if isinstance(origin_id, str):
                        inputs[str(name)] = [origin_id, int(origin_slot)]
                        if input_entry.get("widget") is not None and widget_index < len(
                            widget_values
                        ):
                            widget_index += 1
                        continue
                    inputs[str(name)] = [id_map[int(origin_id)], int(origin_slot)]
                    if input_entry.get("widget") is not None and widget_index < len(
                        widget_values
                    ):
                        widget_index += 1
                    continue
                if input_entry.get("widget") is not None and widget_index < len(
                    widget_values
                ):
                    inputs[str(name)] = widget_values[widget_index]
                    widget_index += 1

            prompt[new_id] = {"class_type": internal_type, "inputs": inputs}

        return prompt, output_map, next_node_id

    def render(self, request: RenderRequest) -> Path:
        return self._render_once(request)

    def _render_once(self, request: RenderRequest) -> Path:
        workflow = self._build_workflow(request)
        prompt_id = self._submit(workflow)
        outputs = self._wait_for_output(prompt_id)
        image_info = self._select_primary_image(outputs)
        image_bytes = self._download_image(image_info)
        ensure_parent(request.output_path)
        self._write_output(image_bytes, request.output_path)
        self._write_additional_outputs(outputs, request.output_path)
        return request.output_path

    def _build_workflow(self, request: RenderRequest) -> dict[str, Any]:
        if self.uses_subgraphs:
            workflow_ui = copy.deepcopy(self.raw_template)
            positive_node_id = str(self.nodes.get("positive_prompt", ""))
            if positive_node_id:
                self._set_proxy_widget_value(
                    workflow_ui, positive_node_id, "text", request.prompt
                )
                self._set_proxy_widget_value(
                    workflow_ui, positive_node_id, "noise_seed", request.seed
                )
                self._set_proxy_widget_value(
                    workflow_ui,
                    positive_node_id,
                    "negative_text",
                    request.negative_prompt or "",
                )
            workflow = self._normalize_workflow(workflow_ui)
        else:
            workflow = copy.deepcopy(self.template)
        node_ids = {key: str(value) for key, value in self.nodes.items()}

        def _normalize_model_value(value: Any, key: str) -> Any:
            if not isinstance(value, str):
                return value
            normalized = value.strip().lstrip("-").strip()
            if ":" in normalized:
                prefix = f"{key}:"
                if normalized.lower().startswith(prefix.lower()):
                    return normalized.split(":", 1)[1].strip()
            return normalized

        flux_model_cfg = self.config.get("flux_model") or {}
        flux_unet_name = _normalize_model_value(flux_model_cfg.get("unet"), "unet")
        flux_clip_name = _normalize_model_value(
            flux_model_cfg.get("clip_name"), "clip_name"
        )
        flux_vae_name = _normalize_model_value(
            flux_model_cfg.get("vae_name"), "vae_name"
        )
        if flux_clip_name is None:
            flux_clip_name = _normalize_model_value(
                flux_model_cfg.get("clipname"), "clipname"
            )
        if flux_unet_name or flux_clip_name or flux_vae_name:
            for node in workflow.values():
                if not isinstance(node, dict):
                    continue
                inputs = (
                    node.get("inputs") if isinstance(node.get("inputs"), dict) else None
                )
                if not inputs:
                    continue
                class_type = node.get("class_type")
                if (
                    flux_unet_name
                    and class_type == "UNETLoader"
                    and "unet_name" in inputs
                ):
                    inputs["unet_name"] = str(flux_unet_name)
                if (
                    flux_clip_name
                    and class_type == "CLIPLoader"
                    and "clip_name" in inputs
                ):
                    inputs["clip_name"] = str(flux_clip_name)
                if (
                    flux_vae_name
                    and class_type == "VAELoader"
                    and "vae_name" in inputs
                ):
                    inputs["vae_name"] = str(flux_vae_name)

        def node_id_for(node_key: str) -> Optional[str]:
            if node_key not in node_ids:
                return None
            return node_ids[node_key]

        def set_input(
            node_key: str, field: str, value: Any, required: bool = True
        ) -> None:
            node_id = node_id_for(node_key)
            if not node_id:
                if required:
                    raise ComfyUIError(f"Workflow missing node key {node_key}")
                return
            if node_id not in workflow:
                if required:
                    raise ComfyUIError(
                        f"Workflow missing node id {node_id} ({node_key})"
                    )
                return
            workflow[node_id].setdefault("inputs", {})[field] = value

        pose_path = self._prepare_input_path(request.pose_path)
        ref1_path = self._prepare_input_path(request.image2_path)
        ref2_path = self._prepare_input_path(request.image3_path)

        set_input("load_pose", "image", pose_path)
        set_input("load_ref1", "image", ref1_path, required=False)
        set_input("load_ref2", "image", ref2_path, required=False)

        positive_node = node_id_for("positive_prompt")
        if positive_node and positive_node in workflow:
            self._set_prompt_input(workflow, positive_node, request.prompt)

        negative_node = node_id_for("negative_prompt")
        if negative_node and negative_node in workflow:
            self._set_prompt_input(workflow, negative_node, request.negative_prompt)

        sampler_node_id = node_id_for("sampler")
        if sampler_node_id and sampler_node_id in workflow:
            sampler_node = workflow[sampler_node_id].setdefault("inputs", {})
            sampler_node["seed"] = request.seed
            sampler_node["steps"] = request.steps
            sampler_node["cfg"] = request.cfg
            sampler_node["sampler_name"] = request.sampler
            sampler_node["scheduler"] = request.scheduler
        else:
            # Some workflows use a different seed field (e.g. noise_seed on an edit node).
            if positive_node and positive_node in workflow:
                inputs = workflow[positive_node].setdefault("inputs", {})
                if "noise_seed" in inputs:
                    inputs["noise_seed"] = request.seed

        # Generic parameter adjustments for workflows that don't expose nodes via workflow_nodes.
        for node in workflow.values():
            class_type = node.get("class_type")
            inputs = (
                node.get("inputs") if isinstance(node.get("inputs"), dict) else None
            )
            if not inputs:
                continue
            if class_type == "CFGGuider" and "cfg" in inputs:
                inputs["cfg"] = float(request.cfg)
            if class_type == "Flux2Scheduler" and "steps" in inputs:
                inputs["steps"] = int(request.steps)
            if class_type == "KSamplerSelect" and "sampler_name" in inputs:
                inputs["sampler_name"] = str(request.sampler)

        target_megapixels = float(request.input_megapixels)

        scale_node_id = node_id_for("scale")
        if scale_node_id and scale_node_id in workflow:
            scale_node = workflow[scale_node_id].setdefault("inputs", {})
            scale_node["megapixels"] = target_megapixels

        # Generic adjustments for workflows that don't expose nodes in workflow_nodes.
        for node in workflow.values():
            class_type = node.get("class_type")
            inputs = (
                node.get("inputs") if isinstance(node.get("inputs"), dict) else None
            )
            if not inputs:
                continue
            if class_type == "ImageScaleToTotalPixels" and "megapixels" in inputs:
                inputs["megapixels"] = float(target_megapixels)

        save_node_id = node_id_for("save")
        if not save_node_id:
            raise ComfyUIError("Workflow missing save node mapping")
        if save_node_id not in workflow:
            raise ComfyUIError(f"Workflow missing save node id {save_node_id}")
        save_node = workflow[save_node_id].setdefault("inputs", {})
        save_node["filename_prefix"] = request.output_path.stem

        # If the workflow has additional SaveImage nodes, also set predictable prefixes.
        # This lets us fetch and persist alternate outputs (e.g. cutout/alpha variants).
        for node_id, node in workflow.items():
            if node_id == save_node_id:
                continue
            if not isinstance(node, dict):
                continue
            if node.get("class_type") != "SaveImage":
                continue
            inputs = node.setdefault("inputs", {})
            if "filename_prefix" in inputs:
                token = self._sanitize_secondary_prefix(inputs.get("filename_prefix"))
                if not token:
                    token = f"save_{node_id}"
                inputs["filename_prefix"] = f"{request.output_path.stem}__{token}"

        return workflow

    def _set_proxy_widget_value(
        self, workflow_ui: dict[str, Any], node_id: str, widget_name: str, value: Any
    ) -> None:
        nodes = workflow_ui.get("nodes") or []
        for node in nodes:
            if str(node.get("id")) != str(node_id):
                continue
            proxy_widgets = (node.get("properties") or {}).get("proxyWidgets") or []
            widget_values = list(node.get("widgets_values") or [])
            if not (isinstance(proxy_widgets, list) and widget_values):
                return
            for index, entry in enumerate(proxy_widgets):
                if not (isinstance(entry, list) and len(entry) >= 2):
                    continue
                target_id, name = str(entry[0]), str(entry[1])
                if target_id == "-1" and name == widget_name:
                    if index < len(widget_values):
                        widget_values[index] = value
                        node["widgets_values"] = widget_values
                    return
            return

    def _set_prompt_input(
        self, workflow: dict[str, Any], node_id: str, value: str
    ) -> None:
        node = workflow.get(node_id)
        if not node:
            raise ComfyUIError(f"Workflow missing node id {node_id}")
        inputs = node.setdefault("inputs", {})
        if "prompt" in inputs:
            inputs["prompt"] = value
            return
        if "text" in inputs:
            inputs["text"] = value
            return
        raise ComfyUIError(f"Prompt node {node_id} missing 'prompt' or 'text' input")

    def _prepare_input_path(self, path: Path) -> str:
        if not self.input_copy_dir:
            if self.upload_images:
                return self._upload_image(path)
            return str(path)
        dest_dir = Path(self.input_copy_dir)
        dest_dir.mkdir(parents=True, exist_ok=True)
        dest_path = dest_dir / path.name
        if not dest_path.exists():
            dest_path.write_bytes(path.read_bytes())
        return dest_path.name

    def _upload_image(self, path: Path) -> str:
        with path.open("rb") as handle:
            response = self.session.post(
                f"{self.endpoint}/upload/image",
                files={"image": (path.name, handle, "application/octet-stream")},
                data={"overwrite": "true"},
                timeout=30,
            )
        response.raise_for_status()
        payload = response.json()
        name = payload.get("name")
        subfolder = payload.get("subfolder", "")
        if not name:
            raise ComfyUIError("ComfyUI upload did not return a name")
        if subfolder:
            return f"{subfolder}/{name}"
        return name

    def _submit(self, workflow: dict[str, Any]) -> str:
        response = self.session.post(
            f"{self.endpoint}/prompt",
            json={"prompt": workflow, "client_id": self.client_id},
            timeout=30,
        )
        if response.status_code >= 400:
            raise ComfyUIError(
                f"ComfyUI /prompt failed {response.status_code}: {response.text}"
            )
        payload = response.json()
        prompt_id = payload.get("prompt_id")
        if not prompt_id:
            raise ComfyUIError("ComfyUI did not return a prompt_id")
        return str(prompt_id)

    def _wait_for_output(self, prompt_id: str) -> dict[str, Any]:
        deadline = time.time() + self.timeout_sec
        save_node_id = str(self.nodes["save"])
        while time.time() < deadline:
            try:
                response = self.session.get(
                    f"{self.endpoint}/history/{prompt_id}", timeout=30
                )
                response.raise_for_status()
                payload = response.json()
            except requests.RequestException:
                time.sleep(self.poll_interval_sec)
                continue
            history = payload.get(prompt_id) if isinstance(payload, dict) else None
            outputs = history.get("outputs") if isinstance(history, dict) else None
            if outputs and save_node_id in outputs:
                images = outputs[save_node_id].get("images")
                if images:
                    return outputs
            time.sleep(self.poll_interval_sec)
        raise ComfyUIError("Timed out waiting for ComfyUI output")

    def _select_primary_image(self, outputs: dict[str, Any]) -> dict[str, Any]:
        save_node_id = str(self.nodes["save"])
        node_output = outputs.get(save_node_id) if isinstance(outputs, dict) else None
        images = node_output.get("images") if isinstance(node_output, dict) else None
        if images and isinstance(images, list):
            first = images[0]
            if isinstance(first, dict):
                return first
        raise ComfyUIError(f"Missing primary image output for save node {save_node_id}")

    def _write_additional_outputs(
        self, outputs: dict[str, Any], output_path: Path
    ) -> None:
        if not isinstance(outputs, dict):
            return
        primary_save_node_id = str(self.nodes["save"])
        for node_id, node_output in outputs.items():
            if str(node_id) == primary_save_node_id:
                continue
            if not isinstance(node_output, dict):
                continue
            images = node_output.get("images")
            if not isinstance(images, list):
                continue
            for index, image_info in enumerate(images, start=1):
                if not isinstance(image_info, dict):
                    continue
                try:
                    image_bytes = self._download_image(image_info)
                except Exception:
                    continue
                alt_path = self._additional_output_path(
                    output_path=output_path,
                    node_id=str(node_id),
                    index=index,
                    image_info=image_info,
                )
                ensure_parent(alt_path)
                self._write_output(image_bytes, alt_path)

    @staticmethod
    def _sanitize_secondary_prefix(value: Any) -> str:
        text = str(value or "").strip()
        if not text:
            return ""

        normalized_chars: list[str] = []
        for char in text:
            if char.isalnum() or char in {"-", "_"}:
                normalized_chars.append(char)
            else:
                normalized_chars.append("_")

        normalized = "".join(normalized_chars).strip("._-")
        while "__" in normalized:
            normalized = normalized.replace("__", "_")
        return normalized

    @staticmethod
    def _additional_output_path(
        output_path: Path, node_id: str, index: int, image_info: dict[str, Any]
    ) -> Path:
        filename = str(image_info.get("filename", "")).strip()
        if filename:
            safe_name = Path(filename).name
            if safe_name:
                return output_path.with_name(safe_name)
        return output_path.with_name(
            f"{output_path.stem}__save_{node_id}_{index}{output_path.suffix}"
        )

    def _download_image(self, image_info: dict[str, Any]) -> bytes:
        params = {
            "filename": image_info["filename"],
            "subfolder": image_info.get("subfolder", ""),
            "type": image_info.get("type", self.output_type),
        }
        response = self.session.get(f"{self.endpoint}/view", params=params, timeout=30)
        response.raise_for_status()
        return response.content

    def _write_output(self, data: bytes, output_path: Path) -> None:
        suffix = output_path.suffix.lower().lstrip(".")
        if suffix in {"png", "jpg", "jpeg", "webp"}:
            try:
                image = Image.open(io.BytesIO(data))
                fmt = "JPEG" if suffix == "jpg" else suffix.upper()
                image.save(output_path, format=fmt)
                return
            except Exception:
                pass
        output_path.write_bytes(data)
