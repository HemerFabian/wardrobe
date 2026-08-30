# ComfyUI workflow

`flux2_klein_4b_edit.json` is Wardrobe's bundled FLUX.2 [klein] 4B distilled
image-editing workflow. The CLI fills its two image inputs, prompt, seed, model
names, and output prefix before sending the normalized graph to ComfyUI.

The workflow expects these external files:

- `models/diffusion_models/flux-2-klein-4b-fp8.safetensors`
- `models/text_encoders/qwen_3_4b.safetensors`
- `models/vae/flux2-vae.safetensors`

No model weights are included. The `qwen_3_4b` file is FLUX.2's text encoder;
it is unrelated to the Qwen3-VL model used by Ollama for clothing
classification.

Only generic workflows belong here. Never commit private endpoints, personal
filenames, generated images, tokens, local paths, or model files.
