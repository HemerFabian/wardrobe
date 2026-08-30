#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEMO_SOURCE="$REPO_ROOT/apps/wardrobe_flutter/assets/builtin_pack_src"
SMOKE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/wardrobe-smoke.XXXXXX")"
WORKSPACE="$SMOKE_ROOT/workspace"
PACK_ONE="$SMOKE_ROOT/wardrobe_pack_one.zip"
PACK_TWO="$SMOKE_ROOT/wardrobe_pack_two.zip"

cleanup() {
  if [[ "${WARDROBE_SMOKE_KEEP:-0}" == "1" ]]; then
    echo "Smoke workspace kept at: $SMOKE_ROOT"
    return
  fi
  rm -rf -- "$SMOKE_ROOT"
}
trap cleanup EXIT

cp -a "$DEMO_SOURCE" "$WORKSPACE"

# Build a minimal raw fixture from the synthetic source assets. The checked-in
# generated renders and accessory overlays are deliberately not reused.
rm -rf -- \
  "$WORKSPACE/renders" \
  "$WORKSPACE/overlays" \
  "$WORKSPACE/items/headwear" \
  "$WORKSPACE/items/shoes" \
  "$WORKSPACE/poses/dummy2"
rm -f -- "$WORKSPACE/wardrobe.json"

cd "$REPO_ROOT"
uv run wardrobe validate "$WORKSPACE"
uv run wardrobe render \
  "$WORKSPACE" \
  --renderer mock \
  --force
uv run wardrobe pack \
  "$WORKSPACE" \
  --zip-path "$PACK_ONE"
uv run wardrobe pack \
  "$WORKSPACE" \
  --zip-path "$PACK_TWO"

cmp "$PACK_ONE" "$PACK_TWO"
unzip -t "$PACK_ONE" >/dev/null

if unzip -Z1 "$PACK_ONE" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
  echo "Archive contains an unsafe path." >&2
  exit 1
fi

if unzip -Z1 "$PACK_ONE" | grep -Eq '^renders/.*\.png$'; then
  echo "Archive contains a stale PNG render instead of the configured WebP output." >&2
  exit 1
fi

echo "Deterministic smoke test passed."
sha256sum "$PACK_ONE"
