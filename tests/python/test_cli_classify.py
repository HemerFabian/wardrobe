from __future__ import annotations

import io
import json
import tempfile
import unittest
from argparse import Namespace
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

from PIL import Image

from wardrobe_gen.cli import (
    _build_classify_prompt,
    _build_pose_name_prompt,
    _classify_pending_item,
    _classify_pose_name,
    _collect_existing_vocab,
    _ensure_classification_ready_for_render,
    _ensure_pack_preconditions,
    _ensure_required_renders_complete,
    _normalize_and_validate_classification,
    _normalize_and_validate_pose_name,
    _resolve_workspace_root,
    _run_classify,
    _update_vocab,
)
from wardrobe_gen.dataset import (
    Dataset,
    Item,
    PendingIntakeItem,
    Pose,
    scan_dataset,
)
from wardrobe_gen.renderers.ollama_vlm import OllamaVLMError


class _FakeVLMClient:
    def __init__(self, *args, **kwargs) -> None:
        self.calls = 0
        self.model = "qwen3-vl:8b"

    def classify(self, image_path: Path, prompt: str) -> dict[str, str]:
        self.calls += 1
        if '"name": "Front"' in prompt:
            return {"name": "front"}
        return {
            "name": "Hoodie",
            "category": "top",
            "subcategory": "hoodie",
            "color_primary": "black",
            "material": "cotton",
            "style_occasion": "casual",
            "pattern_design": "solid",
        }


class _FlakyVLMClient:
    def __init__(self, *args, **kwargs) -> None:
        self.calls = 0
        self.model = "qwen3-vl:8b"

    def classify(self, image_path: Path, prompt: str) -> dict[str, str]:
        self.calls += 1
        if self.calls >= 2:
            raise RuntimeError("simulated classify error")
        return {
            "name": "Hoodie",
            "category": "top",
            "subcategory": "hoodie",
            "color_primary": "black",
            "material": "cotton",
            "style_occasion": "casual",
            "pattern_design": "solid",
        }


class _AlwaysFailVLMClient:
    def __init__(self) -> None:
        self.calls = 0
        self.model = "qwen3-vl:8b"

    def classify(self, image_path: Path, prompt: str) -> dict[str, str]:
        self.calls += 1
        raise RuntimeError("simulated hard failure")


class _MissingImageVLMClient:
    def __init__(self) -> None:
        self.calls = 0
        self.model = "qwen3-vl:8b"

    def classify(self, image_path: Path, prompt: str) -> dict[str, str]:
        self.calls += 1
        raise OllamaVLMError(f"Image not found: {image_path}")


class _InvalidCategoryThenSuccessVLMClient:
    def __init__(self) -> None:
        self.calls = 0
        self.model = "qwen3-vl:8b"

    def classify(self, image_path: Path, prompt: str) -> dict[str, str]:
        self.calls += 1
        if self.calls == 1:
            return {
                "name": "Shorts",
                "category": "shorts",
                "subcategory": "shorts",
                "color_primary": "black",
                "material": "cotton",
                "style_occasion": "casual",
                "pattern_design": "solid",
            }
        return {
            "name": "Pants",
            "category": "bottom",
            "subcategory": "pants",
            "color_primary": "black",
            "material": "cotton",
            "style_occasion": "casual",
            "pattern_design": "solid",
        }


class CliClassifyTest(unittest.TestCase):
    def _base_config(self) -> dict:
        return {
            "images": {
                "output_size": [1080, 1920],
                "image_format": "png",
                "overlay_format": "png",
                "thumbnail_size": [64, 64],
                "thumbnail_format": "jpg",
            },
            "vlm": {
                "provider": "ollama",
                "endpoint": "http://127.0.0.1:11434",
                "model": "qwen3-vl:8b",
                "timeout_sec": 30,
                "max_retries": 1,
                "temperature": 0.1,
                "prompt_version": "test-v1",
            },
            "classify": {"require_before_render": True},
        }

    def _create_workspace_with_pending(self, root: Path, count: int = 1) -> None:
        (root / "poses").mkdir(parents=True, exist_ok=True)
        (root / "items" / "top").mkdir(parents=True, exist_ok=True)
        (root / "items" / "bottom").mkdir(parents=True, exist_ok=True)
        (root / "items" / "headwear").mkdir(parents=True, exist_ok=True)
        (root / "items" / "shoes").mkdir(parents=True, exist_ok=True)

        intake_entries = []
        for index in range(1, count + 1):
            pending_id = f"pending-{index}"
            pending_dir = root / "items" / "intake_queue" / pending_id
            pending_dir.mkdir(parents=True, exist_ok=True)
            Image.new("RGB", (80, 120), color=(20, 20, 20)).save(
                pending_dir / "image.png",
                format="PNG",
            )
            Image.new("RGB", (64, 64), color=(20, 20, 20)).save(
                pending_dir / "thumb.jpg",
                format="JPEG",
            )
            entry = {
                "id": pending_id,
                "path": f"items/intake_queue/{pending_id}/image.png",
                "thumb_path": f"items/intake_queue/{pending_id}/thumb.jpg",
                "meta_path": f"items/intake_queue/{pending_id}/item.yaml",
                "created_at": "2026-02-21T10:00:00Z",
            }
            intake_entries.append(entry)
            (pending_dir / "item.yaml").write_text(
                json.dumps(entry),
                encoding="utf-8",
            )

        (root / "wardrobe.json").write_text(
            json.dumps(
                {
                    "schema_version": 4,
                    "images": {
                        "output_size": [1080, 1920],
                        "image_format": "png",
                        "overlay_format": "png",
                        "thumbnail_size": [64, 64],
                        "thumbnail_format": "jpg",
                    },
                    "poses": [],
                    "categories": {
                        "top": [],
                        "bottom": [],
                        "headwear": [],
                        "shoes": [],
                    },
                    "intake_queue": intake_entries,
                    "renders": [],
                    "overlays": [],
                }
            ),
            encoding="utf-8",
        )

    def _create_workspace_with_pending_pose_name(self, root: Path) -> None:
        self._create_workspace_with_pending(root, count=0)
        pose_dir = root / "poses" / "pose-1"
        pose_dir.mkdir(parents=True, exist_ok=True)
        Image.new("RGB", (80, 120), color=(80, 80, 80)).save(
            pose_dir / "pose.png",
            format="PNG",
        )
        (pose_dir / "pose.yaml").write_text(
            json.dumps(
                {
                    "id": "pose-1",
                    "name": "Pose 1",
                    "path": "poses/pose-1/pose.png",
                    "meta_path": "poses/pose-1/pose.yaml",
                    "render_ready": False,
                }
            ),
            encoding="utf-8",
        )
        manifest_payload = json.loads((root / "wardrobe.json").read_text(encoding="utf-8"))
        manifest_payload["poses"] = [
            {
                "id": "pose-1",
                "name": "Pose 1",
                "path": "poses/pose-1/pose.png",
                "meta_path": "poses/pose-1/pose.yaml",
                "render_ready": False,
            }
        ]
        (root / "wardrobe.json").write_text(
            json.dumps(manifest_payload),
            encoding="utf-8",
        )

    def test_normalization_rejects_composite_values(self) -> None:
        with self.assertRaises(ValueError):
            _normalize_and_validate_classification(
                {
                    "name": "Hoodie",
                    "category": "top",
                    "subcategory": "hoodie",
                    "color_primary": "black, white",
                    "material": "cotton",
                    "style_occasion": "casual",
                    "pattern_design": "solid",
                }
            )

    def test_collect_existing_vocab_groups_subcategories_by_category(self) -> None:
        dataset = Dataset(
            root=Path("/tmp/workspace"),
            poses=[],
            items_by_category={
                "top": [
                    Item(
                        item_id="top-hoodie",
                        name="Hoodie",
                        category="top",
                        path=Path("/tmp/top-hoodie.png"),
                        subcategory="Hoodie",
                        color_primary="Black",
                        material="Cotton",
                        style_occasion="Casual",
                        pattern_design="Solid",
                    ),
                    Item(
                        item_id="top-shirt",
                        name="Shirt",
                        category="top",
                        path=Path("/tmp/top-shirt.png"),
                        subcategory="T-Shirt",
                        color_primary="White",
                        material="Cotton",
                        style_occasion="Casual",
                        pattern_design="Solid",
                    ),
                ],
                "bottom": [
                    Item(
                        item_id="bottom-jeans",
                        name="Jeans",
                        category="bottom",
                        path=Path("/tmp/bottom-jeans.png"),
                        subcategory="Jeans",
                        color_primary="Blue",
                        material="Denim",
                        style_occasion="Casual",
                        pattern_design="Solid",
                    )
                ],
                "headwear": [],
                "shoes": [],
            },
        )

        vocab = _collect_existing_vocab(dataset)

        self.assertEqual(vocab["subcategory_by_category"]["top"], ["hoodie", "t-shirt"])
        self.assertEqual(vocab["subcategory_by_category"]["bottom"], ["jeans"])
        self.assertEqual(vocab["subcategory_by_category"]["headwear"], [])
        self.assertEqual(vocab["subcategory_by_category"]["shoes"], [])
        self.assertIn("cotton", vocab["material"])
        self.assertIn("denim", vocab["material"])

    def test_build_classify_prompt_includes_subcategory_mapping_and_few_shot_guard(self) -> None:
        prompt = _build_classify_prompt(
            {
                "subcategory_by_category": {
                    "top": ["hoodie"],
                    "bottom": ["jeans"],
                    "headwear": [],
                    "shoes": ["sneaker"],
                },
                "color_primary": ["black"],
                "material": ["cotton"],
                "style_occasion": ["casual"],
                "pattern_design": ["solid"],
            }
        )

        self.assertIn("Existing workspace subcategories by category", prompt)
        self.assertIn("- top: [hoodie]", prompt)
        self.assertIn("- bottom: [jeans]", prompt)
        self.assertIn("- shoes: [sneaker]", prompt)
        self.assertIn("Few-shot examples (illustrative only; DO NOT copy values blindly):", prompt)
        self.assertIn("Use the examples only as output-format guidance", prompt)
        self.assertIn("Never use conjunctions in field values", prompt)
        self.assertIn("if no single color dominates, use 'mixed'", prompt)

    def test_update_vocab_updates_subcategory_for_selected_category_only(self) -> None:
        vocab: dict[str, object] = {
            "subcategory_by_category": {
                "top": ["hoodie"],
                "bottom": ["jeans"],
                "headwear": [],
                "shoes": [],
            },
            "color_primary": ["black"],
            "material": ["cotton"],
            "style_occasion": ["casual"],
            "pattern_design": ["solid"],
        }

        _update_vocab(
            vocab,
            {
                "name": "White T-Shirt",
                "category": "top",
                "subcategory": "t-shirt",
                "color_primary": "white",
                "material": "cotton",
                "style_occasion": "casual",
                "pattern_design": "solid",
            },
        )

        self.assertEqual(
            vocab["subcategory_by_category"]["top"],  # type: ignore[index]
            ["hoodie", "t-shirt"],
        )
        self.assertEqual(
            vocab["subcategory_by_category"]["bottom"],  # type: ignore[index]
            ["jeans"],
        )
        self.assertIn("white", vocab["color_primary"])  # type: ignore[arg-type]

    def test_classify_dry_run_does_not_mutate_workspace(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            self._create_workspace_with_pending(root)
            dataset = scan_dataset(root, ["top", "bottom", "headwear", "shoes"])
            args = Namespace(limit=None, dry_run=True, force=False)

            with patch("wardrobe_gen.cli.OllamaVLMClient", _FakeVLMClient):
                _run_classify(args, self._base_config(), dataset, root)

            self.assertEqual(len(dataset.intake_queue), 1)
            self.assertEqual(len(dataset.items_by_category["top"]), 0)
            self.assertTrue((root / "items" / "intake_queue" / "pending-1" / "image.png").exists())

    def test_classify_moves_pending_item_into_main_category(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            self._create_workspace_with_pending(root)
            dataset = scan_dataset(root, ["top", "bottom", "headwear", "shoes"])
            args = Namespace(limit=None, dry_run=False, force=False)

            with patch("wardrobe_gen.cli.OllamaVLMClient", _FakeVLMClient):
                _run_classify(args, self._base_config(), dataset, root)

            self.assertEqual(len(dataset.intake_queue), 0)
            self.assertEqual(len(dataset.items_by_category["top"]), 1)

            top_item = dataset.items_by_category["top"][0]
            self.assertEqual(top_item.item_id, "hoodie")
            self.assertEqual(top_item.name, "Hoodie")
            self.assertEqual(top_item.subcategory, "hoodie")
            self.assertEqual(top_item.color_primary, "black")
            self.assertEqual(top_item.tags, ())
            self.assertTrue(top_item.path.exists())

            manifest_payload = json.loads((root / "wardrobe.json").read_text(encoding="utf-8"))
            self.assertEqual(manifest_payload["schema_version"], 5)
            self.assertEqual(manifest_payload["intake_queue"], [])
            self.assertEqual(manifest_payload["categories"]["top"][0]["name"], "Hoodie")

    def test_classify_updates_pending_pose_name(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            self._create_workspace_with_pending_pose_name(root)
            dataset = scan_dataset(root, ["top", "bottom", "headwear", "shoes"])
            args = Namespace(limit=None, dry_run=False, force=False)

            with patch("wardrobe_gen.cli.OllamaVLMClient", _FakeVLMClient):
                _run_classify(args, self._base_config(), dataset, root)

            self.assertEqual(dataset.poses[0].name, "Front")
            manifest_payload = json.loads((root / "wardrobe.json").read_text(encoding="utf-8"))
            self.assertEqual(manifest_payload["poses"][0]["name"], "Front")

    def test_classify_prints_progress_with_eta(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            self._create_workspace_with_pending(root, count=2)
            dataset = scan_dataset(root, ["top", "bottom", "headwear", "shoes"])
            args = Namespace(limit=None, dry_run=True, force=False)
            captured = io.StringIO()

            with patch("wardrobe_gen.cli.OllamaVLMClient", _FakeVLMClient):
                with redirect_stdout(captured):
                    _run_classify(args, self._base_config(), dataset, root)

            output = captured.getvalue()
            self.assertIn("[classify]", output)
            self.assertIn("2/2 (100.0%)", output)
            self.assertIn("ETA", output)
            self.assertIn("fertig ca.", output)
            self.assertIn("status=ok", output)

    def test_classify_dry_run_without_flag_does_not_print_raw_prompt_and_response_for_item(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            self._create_workspace_with_pending(root, count=1)
            dataset = scan_dataset(root, ["top", "bottom", "headwear", "shoes"])
            args = Namespace(limit=None, dry_run=True, force=False, show_raw_vlm=False)
            captured = io.StringIO()

            with patch("wardrobe_gen.cli.OllamaVLMClient", _FakeVLMClient):
                with redirect_stdout(captured):
                    _run_classify(args, self._base_config(), dataset, root)

            output = captured.getvalue()
            self.assertNotIn("[raw][item=pending-1][prompt]", output)
            self.assertNotIn("[raw][item=pending-1][response_attempt_1]", output)

    def test_classify_dry_run_with_flag_prints_raw_prompt_and_response_for_item(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            self._create_workspace_with_pending(root, count=1)
            dataset = scan_dataset(root, ["top", "bottom", "headwear", "shoes"])
            args = Namespace(limit=None, dry_run=True, force=False, show_raw_vlm=True)
            captured = io.StringIO()

            with patch("wardrobe_gen.cli.OllamaVLMClient", _FakeVLMClient):
                with redirect_stdout(captured):
                    _run_classify(args, self._base_config(), dataset, root)

            output = captured.getvalue()
            self.assertIn("[raw][item=pending-1][prompt]", output)
            self.assertIn("Classify the clothing item in the image", output)
            self.assertIn("[raw][item=pending-1][response_attempt_1]", output)
            self.assertIn('"category": "top"', output)

    def test_classify_raw_trace_keeps_each_item_label(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            self._create_workspace_with_pending(root, count=2)
            dataset = scan_dataset(root, ["top", "bottom", "headwear", "shoes"])
            args = Namespace(
                limit=None,
                dry_run=True,
                force=False,
                show_raw_vlm=True,
            )
            captured = io.StringIO()

            with patch("wardrobe_gen.cli.OllamaVLMClient", _FakeVLMClient):
                with redirect_stdout(captured):
                    _run_classify(args, self._base_config(), dataset, root)

            output = captured.getvalue()
            self.assertIn("[raw][item=pending-1][prompt]", output)
            self.assertIn("[raw][item=pending-2][prompt]", output)

    def test_classify_dry_run_with_flag_prints_raw_prompt_and_response_for_pose(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            self._create_workspace_with_pending_pose_name(root)
            dataset = scan_dataset(root, ["top", "bottom", "headwear", "shoes"])
            args = Namespace(limit=None, dry_run=True, force=False, show_raw_vlm=True)
            captured = io.StringIO()

            with patch("wardrobe_gen.cli.OllamaVLMClient", _FakeVLMClient):
                with redirect_stdout(captured):
                    _run_classify(args, self._base_config(), dataset, root)

            output = captured.getvalue()
            self.assertIn("[raw][pose=pose-1][prompt]", output)
            self.assertIn("Analyze the person pose image and respond with JSON only.", output)
            self.assertIn("[raw][pose=pose-1][response_attempt_1]", output)
            self.assertIn('"name": "front"', output)

    def test_classify_failure_step_marks_progress_error(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            self._create_workspace_with_pending(root, count=2)
            dataset = scan_dataset(root, ["top", "bottom", "headwear", "shoes"])
            args = Namespace(limit=None, dry_run=True, force=False)
            captured = io.StringIO()

            with patch("wardrobe_gen.cli.OllamaVLMClient", _FlakyVLMClient):
                with redirect_stdout(captured):
                    _run_classify(args, self._base_config(), dataset, root)

            output = captured.getvalue()
            self.assertIn("status=error", output)
            self.assertIn("2/2 (100.0%)", output)

    def test_pending_item_retries_match_max_retries(self) -> None:
        client = _AlwaysFailVLMClient()
        pending_item = PendingIntakeItem(
            item_id="pending-1",
            path=Path("/tmp/missing-item.png"),
        )
        with self.assertRaises(RuntimeError) as ctx:
            _classify_pending_item(
                client=client,
                pending_item=pending_item,
                vocab={},
                max_retries=3,
            )

        self.assertEqual(client.calls, 4)
        self.assertIn("after 3 retries", str(ctx.exception))

    def test_pending_item_missing_image_is_not_retried(self) -> None:
        client = _MissingImageVLMClient()
        pending_item = PendingIntakeItem(
            item_id="pending-1",
            path=Path("/tmp/missing-item.png"),
        )
        with self.assertRaises(RuntimeError) as ctx:
            _classify_pending_item(
                client=client,
                pending_item=pending_item,
                vocab={},
                max_retries=10,
            )

        self.assertEqual(client.calls, 1)
        self.assertIn("after 0 retries", str(ctx.exception))
        self.assertIn("Image not found:", str(ctx.exception))

    def test_pending_item_invalid_category_is_retried(self) -> None:
        client = _InvalidCategoryThenSuccessVLMClient()
        pending_item = PendingIntakeItem(
            item_id="pending-1",
            path=Path("/tmp/item.png"),
        )

        result = _classify_pending_item(
            client=client,
            pending_item=pending_item,
            vocab={},
            max_retries=2,
        )

        self.assertEqual(client.calls, 2)
        self.assertEqual(result["category"], "bottom")
        self.assertEqual(result["name"], "Pants")

    def test_pending_item_error_message_contains_raw_response(self) -> None:
        client = _InvalidCategoryThenSuccessVLMClient()
        pending_item = PendingIntakeItem(
            item_id="pending-1",
            path=Path("/tmp/item.png"),
        )
        with self.assertRaises(RuntimeError) as ctx:
            _classify_pending_item(
                client=client,
                pending_item=pending_item,
                vocab={},
                max_retries=0,
            )

        message = str(ctx.exception)
        self.assertIn("raw_response:", message)
        self.assertIn('"category": "shorts"', message)

    def test_scan_dataset_ignores_manifest_intake_entries_with_missing_image(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            self._create_workspace_with_pending(root, count=2)
            missing_image = root / "items" / "intake_queue" / "pending-1" / "image.png"
            missing_image.unlink()

            dataset = scan_dataset(root, ["top", "bottom", "headwear", "shoes"])

            self.assertEqual(len(dataset.intake_queue), 1)
            self.assertEqual(dataset.intake_queue[0].item_id, "pending-2")
            self.assertTrue(dataset.intake_queue[0].path.exists())

    def test_pose_name_retries_match_max_retries(self) -> None:
        client = _AlwaysFailVLMClient()
        pose = Pose(
            pose_id="pose-1",
            name="Pose 1",
            path=Path("/tmp/missing-pose.png"),
            render_ready=False,
        )
        with patch(
            "wardrobe_gen.cli._classify_pose_name_with_loose_parser",
            return_value=None,
        ):
            with self.assertRaises(RuntimeError) as ctx:
                _classify_pose_name(
                    client=client,
                    pose=pose,
                    max_retries=3,
                )

        self.assertEqual(client.calls, 4)
        self.assertIn("after 3 retries", str(ctx.exception))

    def test_build_pose_name_prompt_uses_simple_few_shot_examples(self) -> None:
        prompt = _build_pose_name_prompt()

        self.assertIn("Return a very simple pose name using 1-2 common words.", prompt)
        self.assertIn('Good examples: "Front", "Side", "Back", "Sitting", "Walking".', prompt)
        self.assertIn('- Person facing the camera -> {"name": "Front"}', prompt)
        self.assertIn('"name": "Front"', prompt)

    def test_normalize_and_validate_pose_name_capitalizes_first_letter(self) -> None:
        self.assertEqual(_normalize_and_validate_pose_name({"name": "front"}), "Front")
        self.assertEqual(_normalize_and_validate_pose_name('{"name":"side"}'), "Side")

    def test_render_and_pack_guards_block_pending_queue(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            self._create_workspace_with_pending(root)
            dataset = scan_dataset(root, ["top", "bottom", "headwear", "shoes"])
            config = {"classify": {"require_before_render": True}}

            with self.assertRaises(SystemExit):
                _ensure_classification_ready_for_render(dataset, config)
            with self.assertRaises(SystemExit):
                _ensure_pack_preconditions(dataset)

    def test_render_and_pack_guards_block_pending_pose_names(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            root = Path(tmp_dir)
            self._create_workspace_with_pending_pose_name(root)
            dataset = scan_dataset(root, ["top", "bottom", "headwear", "shoes"])
            config = {"classify": {"require_before_render": True}}

            with self.assertRaises(SystemExit):
                _ensure_classification_ready_for_render(dataset, config)
            with self.assertRaises(SystemExit):
                _ensure_pack_preconditions(dataset)

    def test_pack_guard_blocks_missing_required_renders(self) -> None:
        manifest_payload = {
            "poses": [{"id": "pose-1", "render_ready": False}],
            "categories": {
                "top": [{"id": "top-1", "render_ready": False}],
                "bottom": [{"id": "bottom-1", "render_ready": True}],
            },
        }
        with self.assertRaises(SystemExit):
            _ensure_required_renders_complete(manifest_payload)

    def test_resolve_workspace_root_uses_explicit_argument(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            repo_root = Path(tmp_dir)
            workspace = repo_root / "workspace-from-arg"
            workspace.mkdir(parents=True, exist_ok=True)

            resolved = _resolve_workspace_root(
                repo_root=repo_root,
                workspace_arg="workspace-from-arg",
                config={"workspace_root": "workspace-from-config"},
            )

            self.assertEqual(resolved, workspace.resolve())

    def test_resolve_workspace_root_uses_config_default(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            repo_root = Path(tmp_dir)
            workspace = repo_root / "workspace-from-config"
            workspace.mkdir(parents=True, exist_ok=True)

            resolved = _resolve_workspace_root(
                repo_root=repo_root,
                workspace_arg=None,
                config={"workspace_root": "workspace-from-config"},
            )

            self.assertEqual(resolved, workspace.resolve())

    def test_resolve_workspace_root_errors_when_missing(self) -> None:
        with tempfile.TemporaryDirectory() as tmp_dir:
            repo_root = Path(tmp_dir)
            with self.assertRaises(SystemExit):
                _resolve_workspace_root(
                    repo_root=repo_root,
                    workspace_arg=None,
                    config={},
                )


if __name__ == "__main__":
    unittest.main()
