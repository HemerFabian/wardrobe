# Privacy

Wardrobe is designed for local, offline-first use.

## Android app

- The app has no analytics, account system, or project backend.
- It does not upload wardrobe images, content packs, or workspace exports.
- Imported and captured images are stored inside the app's local workspace.
- A workspace leaves the app only when the user explicitly exports or shares it.

## Generator

The Python generator sends images only to the services configured by the user.
Its built-in defaults point to Ollama and ComfyUI on `127.0.0.1`. An optional
ignored `config.local.yaml` can select different endpoints. Changing them to
remote hosts also changes the privacy boundary; the operator is responsible for
the remote services and their data handling.

The optional GroundingDINO model can be downloaded from Hugging Face when
`cutout.allow_download` is enabled locally (or
`WARDROBE_CUTOUT_ALLOW_DOWNLOAD=1` is set). That download contains no wardrobe
images. Normal local runs use the cached model and do not upload wardrobe images
to Hugging Face.

## Repository

The repository contains synthetic demo assets, but no personal wardrobe
photos, production signing keys, API keys, private model weights, or generated
personal workspaces. See `ASSETS.md` for the demo asset terms.
