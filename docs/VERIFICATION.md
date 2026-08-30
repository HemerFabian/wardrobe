# Release verification

This document records the release paths exercised for v0.1.0. Public demo
assets and the inputs used below are synthetic. Full local AI outputs remain
outside the repository.

## Deterministic pipeline

The lightweight smoke test starts in a temporary directory with raw pose, top,
and bottom images and no existing manifest or renders. It validates the inputs,
renders every combination with the mock renderer, creates the pack twice,
requires identical SHA-256 hashes, and checks ZIP integrity and contents.

```bash
uv sync --dev --locked
scripts/smoke_demo.sh
```

This verifies orchestration and packaging without Ollama, ComfyUI, CUDA, or
model downloads. It is not a generative-image quality benchmark.

## Full local AI path

The documented local stack was checked with live services and the bundled
FLUX.2 [klein] 4B workflow:

- `wardrobe doctor` found the configured Qwen3-VL model, ComfyUI, all three
  FLUX.2 model files, ML dependencies, the SAM checkpoint, and the cached
  GroundingDINO model;
- Qwen3-VL classified a synthetic queued garment, moved it into the detected
  category, wrote schema-valid metadata, and left an empty intake queue;
- ComfyUI generated a new base outfit from synthetic pose, top, and bottom
  references using FLUX.2 [klein] 4B;
- ComfyUI, GroundingDINO, and SAM generated transparent headwear and shoe
  overlays;
- the resulting workspace validated, produced two byte-identical ZIP files,
  and passed `unzip -t`;
- the ZIP was imported through Android's system file picker and displayed
  offline in the app.

The headwear check reproduced an accessory-type regression: an underspecified
request could turn a beanie reference into a cap. The production path now locks
the classified accessory type and uses the previously evaluated stable
reference strategy. A repeated live render produced a brimless beanie, the SAM
cutout retained transparency, and the Android composition aligned with the
generated outfit. The shoe overlay was also checked in the Android composition.

The generated test pack and screenshots from this live run are intentionally
not checked into the repository.

## Automated release gates

The local release candidate passes:

```bash
uv sync --dev --locked
uv run ruff check src tests/python
uv run pytest
scripts/smoke_demo.sh

cd apps/wardrobe_flutter
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
flutter build apk --debug
```

Results:

- Ruff: no findings;
- Python: 74 tests passed;
- deterministic smoke: passed with byte-identical packs;
- Flutter format: no changes;
- Flutter analyze: no issues;
- Flutter: 91 tests passed;
- Android debug APK: built successfully with Flutter 3.38.9.

Android UI checks covered content-pack import, base rendering, headwear and shoe
composition, filtering, favorites, item editing, photo-intake picker launch,
and workspace-export picker launch. Automated tests additionally cover schema
handling, archive limits, unsafe paths, navigation, and workspace state.

## Signed Android release

The signed universal APK was built separately from the private local signing
key and verified with `apksigner`:

- package: `app.wardrobe.viewer`;
- version name: `0.1.0`;
- version code: `1`;
- APK Signature Scheme v2;
- one RSA 4096-bit signer;
- public subject: `CN=Wardrobe Release, O=Wardrobe`.

The release manifest requests no normal Internet, camera, or broad storage
permission. The APK, checksum file, and public certificate fingerprint are
release assets only and are not committed to Git.

GitHub Actions repeats the Python, smoke, Flutter analysis/test, and Android
debug-build checks. Publication remains gated on a green private-repository CI
run and final maintainer review.
