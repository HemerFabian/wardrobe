# Repository Guidelines

## Project Structure & Module Organization
- `src/wardrobe_gen/`: installed Python generator package and CLI (`doctor`, `validate`, `classify`, `render`, `pack`).
- `tests/python/`: Python unit tests for configuration, dataset, CLI flow, and manifest behavior.
- `src/wardrobe_gen/workflows/`: bundled ComfyUI workflow; do not commit model weights.
- `apps/wardrobe_flutter/lib/`: Flutter app code (models, services, UI).
- `apps/wardrobe_flutter/test/`: Flutter unit/widget tests.
- `apps/wardrobe_flutter/assets/builtin_pack_src/`: synthetic source files for the bundled demo pack.
- `apps/wardrobe_flutter/assets/builtin_pack/wardrobe_pack.zip`: generated bundled demo pack used by the app and tests.
- Local workspaces, generated outputs, model weights, and debug archives are ignored by `.gitignore`.

## Build, Test, and Development Commands
- Setup Python deps: `uv sync --dev --locked`
- Setup optional local ML deps: `uv sync --dev --extra ml --locked`
- Generator help: `uv run wardrobe --help`
- Validate demo workspace: `uv run wardrobe validate apps/wardrobe_flutter/assets/builtin_pack_src`
- Deterministic mock smoke: `scripts/smoke_demo.sh`
- Rebuild built-in ZIP: `apps/wardrobe_flutter/scripts/build_builtin_pack.sh`
- Python lint: `uv run ruff check src tests/python`
- Python tests: `uv run pytest`
- Flutter app: `cd apps/wardrobe_flutter && flutter pub get && flutter run`
- Flutter checks: `cd apps/wardrobe_flutter && flutter analyze && flutter test`

## Coding Style & Naming Conventions
- Python: follow PEP 8, 4-space indentation, type hints for new/changed public functions.
- Dart/Flutter: follow `flutter_lints` (`apps/wardrobe_flutter/analysis_options.yaml`), keep widgets small and composable.
- IDs are slugified from filenames (`pose_id`, `item_id`); keep filenames descriptive and lowercase-friendly.
- Render naming convention: `renders/<pose_id>/<top_id>__<bottom_id>.<ext>` (double underscore separator).

## Testing Guidelines
- Add/update tests with each behavioral change in generator or app.
- Prefer targeted runs while iterating, for example `uv run pytest tests/python/test_result_manifest.py`.
- For Flutter-focused changes, run `cd apps/wardrobe_flutter && flutter test test/wardrobe_repository_test.dart`.
- Cover schema-impacting changes on both sides (Python manifest writer and Flutter parser).
- Avoid committing regenerated demo ZIP changes unless the source demo assets or manifest behavior intentionally changed.

## Commit Message Conventions
- Prefer Conventional Commits: `feat: ...`, `fix: ...`, `chore: ...`, optional scope (`feat(wardrobe_flutter): ...`).
- Keep subject imperative and specific; reference schema/version changes explicitly (example: `feat: bump manifest schema to v3`).
- Keep release-preparation changes cohesive and follow the repository owner's requested history strategy.
