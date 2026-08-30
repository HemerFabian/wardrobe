# Architecture

Wardrobe separates the interactive mobile product from expensive local image
processing. The handoff between both sides is a versioned workspace rather than
a server API.

## Components

### Android app

The Flutter app owns intake, local editing, outfit browsing, filters, favorites,
regeneration requests, and workspace import/export. It stores its active pack
inside the app data directory and does not depend on a backend.

Android-specific storage export is implemented by a small Kotlin method channel.
Linux and web remain development targets and do not implement the complete
mobile workspace lifecycle.

### Python generator

The installed `wardrobe` CLI exposes four workspace operations plus a setup
diagnostic:

1. `doctor` checks the configured local services, workflow, and model files.
2. `validate` checks the workspace and required source data.
3. `classify` sends pending intake images to the configured Ollama VLM.
4. `render` creates base outfits and accessory render candidates with FLUX.2
   [klein] 4B.
5. `pack` writes schema 5 and creates a deterministic import ZIP.

The deterministic mock renderer exercises orchestration and packaging. The
ComfyUI renderer adapts the included two-reference FLUX.2 workflow and exchanges
images with the configured ComfyUI HTTP endpoint. Qwen3-VL is a separate intake
classifier and is not part of generation.

### Accessory cutouts

Headwear and shoes are rendered as full images before GroundingDINO locates the
target accessory and SAM produces an alpha mask. This stage deliberately fails
when its required local models are unavailable; it does not silently substitute
a lower-quality legacy algorithm.

## Workspace contract

```text
workspace/
  wardrobe.json
  poses/<pose_id>/pose.*
  poses/<pose_id>/pose.yaml
  items/<category>/<item_id>/image.*
  items/<category>/<item_id>/item.yaml
  renders/<pose_id>/<top_id>__<bottom_id>.*
  overlays/<pose_id>/<category>/<item_id>.*
```

The four item categories are `top`, `bottom`, `headwear`, and `shoes`. Pending
mobile intake entries live under `items/intake_queue` until classification moves
them into a category. Sidecar files preserve IDs, classifications, and render
metadata independently of the app.

Schema 5 records display names, classifications, source paths, current render
and overlay paths, regeneration requests, and render-readiness state. The app
and CLI are released together against this contract.

## Data flow

1. The app creates or edits a local workspace and exports it as a ZIP.
2. The operator extracts the ZIP and runs `classify` against local Ollama.
3. `render` sends references and prompts to FLUX.2 [klein] 4B in local ComfyUI.
4. The cutout stage produces transparent accessory overlays locally.
5. `pack` rebuilds `wardrobe.json` and writes a deterministic ZIP.
6. The app imports the new pack atomically and keeps it available offline.

## Failure boundaries

- Invalid or incomplete intake blocks rendering with an actionable classification error.
- Missing required renders block packing.
- Ollama and ComfyUI failures remain external-service failures and do not corrupt source images.
- Pack import is staged before replacing the active app workspace.
- Pack import rejects traversal paths and archives over 10,000 entries, 512 MiB
  compressed input, 1 GiB expanded content, or 256 MiB per entry.
- Pack creation rejects unsafe manifest paths and omits stale, unreferenced renders/overlays.
- Python workspace discovery rejects absolute, parent-relative, and external
  symlink paths before an image can reach a configured model endpoint.
- Personal workspaces and model weights are outside the Git repository boundary.

## Reproducibility

Unit tests mock all external model services. The public smoke test starts from
raw synthetic pose/top/bottom inputs and runs the same validation, render, and
pack orchestration as the real path. ZIP entries are sorted and normalized, and
an unchanged manifest retains its generation timestamp, so identical inputs
produce byte-identical packs.
