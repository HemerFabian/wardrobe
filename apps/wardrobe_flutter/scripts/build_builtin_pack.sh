#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
WORKSPACE_ROOT="$REPO_ROOT/apps/wardrobe_flutter/assets/builtin_pack_src"
ZIP_PATH="$REPO_ROOT/apps/wardrobe_flutter/assets/builtin_pack/wardrobe_pack.zip"

(
  cd "$REPO_ROOT"
  uv run wardrobe pack \
    "$WORKSPACE_ROOT" \
    --zip-path "$ZIP_PATH"
)
