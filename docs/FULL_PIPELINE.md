# Full local AI pipeline

This runbook covers the supported end-to-end path: Android intake, local
classification, FLUX.2 image editing, accessory cutouts, deterministic packing,
and Android import.

## 1. Install the generator

Install Python 3.11 or newer and `uv`, then install Wardrobe with its local ML
dependencies:

```bash
uv sync --dev --extra ml --locked
```

The standard setup uses these defaults:

- Ollama: `http://127.0.0.1:11434`
- classifier: `qwen3-vl:8b-instruct-q4_K_M`
- ComfyUI: `http://127.0.0.1:8188`
- SAM checkpoint: `models/sam_vit_h_4b8939.pth`

No config file is needed when these values match the host. For a different
endpoint or checkpoint location:

```bash
cp config.example.yaml config.local.yaml
```

`config.local.yaml` is ignored and loaded automatically from the repository
root. An alternative file can be selected explicitly; the global option must
appear before the subcommand:

```bash
uv run wardrobe --config /path/to/local.yaml doctor
```

CLI flags override both built-in defaults and local configuration.

## 2. Configure Ollama classification

Qwen3-VL is used only to turn intake photos into structured clothing metadata.
It does not generate outfit images.

```bash
ollama pull qwen3-vl:8b-instruct-q4_K_M
ollama list
```

Another local vision-language model can be selected through `vlm.model`, but it
must accept images and reliably return the JSON fields requested by Wardrobe.

## 3. Configure FLUX.2 [klein] 4B in ComfyUI

Update ComfyUI and install the model files required by the bundled
`src/wardrobe_gen/workflows/flux2_klein_4b_edit.json` workflow:

```text
ComfyUI/models/diffusion_models/flux-2-klein-4b-fp8.safetensors
ComfyUI/models/text_encoders/qwen_3_4b.safetensors
ComfyUI/models/vae/flux2-vae.safetensors
```

Authoritative references:

- [Black Forest Labs FLUX.2 [klein] 4B FP8 model card](https://huggingface.co/black-forest-labs/FLUX.2-klein-4b-fp8)
- [ComfyUI FLUX.2 [klein] guide and model links](https://docs.comfy.org/tutorials/flux/flux-2-klein)
- [Official ComfyUI workflow templates](https://github.com/Comfy-Org/workflow_templates)

The `qwen_3_4b.safetensors` file is FLUX.2's text encoder. It is unrelated to
the Ollama Qwen3-VL classifier.

Start ComfyUI and confirm the API is reachable:

```bash
curl --fail http://127.0.0.1:8188/system_stats
```

ComfyUI Desktop may use another port such as 8000. Put that endpoint under
`comfyui.endpoint` in `config.local.yaml`; do not edit the bundled workflow.

The distilled workflow uses four sampling steps. An NVIDIA GPU is strongly
recommended. Eight gigabytes of VRAM can work with ComfyUI offloading but is a
tight lower bound; available system memory and the ComfyUI installation affect
peak requirements.

## 4. Configure accessory cutouts

Wardrobe detects headwear and shoes with
`IDEA-Research/grounding-dino-tiny`, then segments them with SAM ViT-H.

Download `sam_vit_h_4b8939.pth` from the
[Segment Anything project](https://github.com/facebookresearch/segment-anything)
and place it under `models/`, or set `cutout.sam_checkpoint` in the local config.

GroundingDINO normally runs cache-only. For its first download, temporarily use:

```yaml
cutout:
  allow_download: true
```

After a successful download, restore `false`. `cutout.device` defaults to
`auto`; it can be changed to a concrete Torch device when needed. The existing
`WARDROBE_SAM_VIT_H_CHECKPOINT`, `WARDROBE_CUTOUT_ALLOW_DOWNLOAD`, and
`WARDROBE_CUTOUT_DEVICE` environment variables remain valid and take precedence
for one-off local runs.

Run the read-only setup check before handling a workspace:

```bash
uv run wardrobe doctor
```

Every line should report `OK` before a full render.

## 5. Capture and export on Android

1. Start the Flutter app on an Android device or emulator.
2. Add at least one pose, top, and bottom.
3. Add headwear and shoes when accessory overlays are required.
4. Export the workspace ZIP through **Manage Data**.
5. Extract it into an ignored local directory:

```bash
mkdir -p wardrobe_workspace
unzip wardrobe_workspace.zip -d wardrobe_workspace
```

Never copy personal intake images into the synthetic demo directories or force
add an ignored workspace to Git.

## 6. Classify, validate, render, and pack

Run all commands from the repository root:

```bash
uv run wardrobe classify wardrobe_workspace
uv run wardrobe validate wardrobe_workspace
uv run wardrobe render wardrobe_workspace
uv run wardrobe pack wardrobe_workspace \
  --zip-path wardrobe_workspace/wardrobe_pack.zip
unzip -t wardrobe_workspace/wardrobe_pack.zip
```

Useful render controls include `--pose`, `--top`, `--bottom`, `--force`,
`--max-images`, `--seed`, `--steps`, `--cfg`, and `--sampler`. These are advanced
run-specific overrides; the normal four-step FLUX.2 path needs none of them.

Use `--show-raw-vlm` only for local debugging because model responses can
describe private clothing images.

## 7. Import and verify

Import `wardrobe_workspace/wardrobe_pack.zip` in the Android app and verify:

- every expected pose and clothing category is present;
- top and bottom combinations switch without missing images;
- headwear and shoes align and retain transparent backgrounds;
- filters, favorites, editing, and regeneration requests work;
- export produces a readable workspace ZIP;
- the viewer remains functional after Ollama and ComfyUI are stopped.

The run is complete only after this Android re-import check. Public verification
notes must not contain personal filenames, local endpoints, absolute paths,
prompts derived from private images, or screenshots of private content.
