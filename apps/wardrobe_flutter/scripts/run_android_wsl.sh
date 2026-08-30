#!/usr/bin/env bash
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "$APP_DIR/../.." && pwd)"
WORKSPACE_ROOT="$REPO_DIR/apps/wardrobe_flutter/assets/builtin_pack_src"

FLUTTER_BIN="${FLUTTER_BIN:-}"
if [[ -z "$FLUTTER_BIN" ]]; then
  if command -v flutter >/dev/null 2>&1; then
    FLUTTER_BIN="$(command -v flutter)"
  else
    FLUTTER_BIN="$HOME/flutter/bin/flutter"
  fi
fi

if [[ ! -x "$FLUTTER_BIN" ]]; then
  echo "Flutter binary not found: $FLUTTER_BIN" >&2
  exit 1
fi

find_adb_win() {
  if [[ -n "${ADB_WIN:-}" && -x "${ADB_WIN}" ]]; then
    echo "$ADB_WIN"
    return 0
  fi

  local candidate
  candidate="/mnt/c/Users/$USER/AppData/Local/Android/Sdk/platform-tools/adb.exe"
  if [[ -x "$candidate" ]]; then
    echo "$candidate"
    return 0
  fi

  candidate="$(ls /mnt/c/Users/*/AppData/Local/Android/Sdk/platform-tools/adb.exe 2>/dev/null | head -n 1 || true)"
  if [[ -n "$candidate" && -x "$candidate" ]]; then
    echo "$candidate"
    return 0
  fi

  return 1
}

ADB_WIN_BIN="$(find_adb_win || true)"
if [[ -z "$ADB_WIN_BIN" ]]; then
  echo "Windows adb.exe not found. Set ADB_WIN to the full adb.exe path." >&2
  exit 1
fi

if [[ ! -d "$WORKSPACE_ROOT" ]]; then
  echo "Workspace directory not found: $WORKSPACE_ROOT" >&2
  exit 1
fi

BUILTIN_SRC_ZIP="${BUILTIN_SRC_ZIP:-$REPO_DIR/apps/wardrobe_flutter/assets/builtin_pack_src/pack/wardrobe_pack.zip}"
BUILTIN_ASSET_ZIP="$REPO_DIR/apps/wardrobe_flutter/assets/builtin_pack/wardrobe_pack.zip"
SYNC_BUILTIN_ASSET="${SYNC_BUILTIN_ASSET:-1}"
RESET_ACTIVE_PACK="${RESET_ACTIVE_PACK:-1}"
AUTO_BUILD_BUILTIN_SRC_ZIP="${AUTO_BUILD_BUILTIN_SRC_ZIP:-1}"
DEFAULT_ZIP_PATH="$WORKSPACE_ROOT/pack/wardrobe_pack.zip"
ZIP_PATH="${1:-$DEFAULT_ZIP_PATH}"

DEVICE_ID="${DEVICE_ID:-emulator-5554}"
APP_ID="${APP_ID:-app.wardrobe.viewer}"
MAIN_ACTIVITY="${MAIN_ACTIVITY:-${APP_ID}.MainActivity}"

echo "==> Building debug APK"
if [[ "$ZIP_PATH" == "$DEFAULT_ZIP_PATH" && ! -f "$ZIP_PATH" && "$AUTO_BUILD_BUILTIN_SRC_ZIP" == "1" ]]; then
  echo "==> Default ZIP missing, building it first"
  (
    cd "$REPO_DIR"
    uv run wardrobe pack "$WORKSPACE_ROOT" --zip-path "$ZIP_PATH"
  )
fi

if [[ ! -f "$ZIP_PATH" ]]; then
  echo "ZIP pack not found: $ZIP_PATH" >&2
  exit 1
fi

if [[ "$SYNC_BUILTIN_ASSET" == "1" ]]; then
  if [[ ! -f "$BUILTIN_SRC_ZIP" ]]; then
    if [[ "$AUTO_BUILD_BUILTIN_SRC_ZIP" == "1" ]]; then
      echo "==> Built-in source ZIP missing, building it first"
      (
        cd "$REPO_DIR"
        uv run wardrobe pack "$WORKSPACE_ROOT" --zip-path "$BUILTIN_SRC_ZIP"
      )
    fi
  fi
  if [[ ! -f "$BUILTIN_SRC_ZIP" ]]; then
    echo "Warning: built-in source ZIP still missing: $BUILTIN_SRC_ZIP" >&2
    echo "Warning: continuing without built-in asset sync." >&2
    SYNC_BUILTIN_ASSET="0"
  fi
  if [[ "$SYNC_BUILTIN_ASSET" == "1" ]]; then
    echo "==> Syncing built-in asset ZIP"
    cp -f "$BUILTIN_SRC_ZIP" "$BUILTIN_ASSET_ZIP"
  fi
fi

(cd "$APP_DIR" && "$FLUTTER_BIN" build apk --debug)

APK_PATH="$APP_DIR/build/app/outputs/flutter-apk/app-debug.apk"
if [[ ! -f "$APK_PATH" ]]; then
  echo "APK not found after build: $APK_PATH" >&2
  exit 1
fi

echo "==> Checking emulator: $DEVICE_ID"
if ! "$ADB_WIN_BIN" devices | tr -d '\r' | awk '{print $1}' | grep -qx "$DEVICE_ID"; then
  echo "Device '$DEVICE_ID' not found. Start the emulator in Android Studio first." >&2
  "$ADB_WIN_BIN" devices || true
  exit 1
fi

APK_WIN="$(wslpath -w "$APK_PATH")"
ZIP_WIN="$(wslpath -w "$ZIP_PATH")"

echo "==> Installing APK"
"$ADB_WIN_BIN" -s "$DEVICE_ID" install -r "$APK_WIN"

if [[ "$RESET_ACTIVE_PACK" == "1" ]]; then
  echo "==> Resetting active in-app pack to force built-in reload"
  "$ADB_WIN_BIN" -s "$DEVICE_ID" shell "run-as $APP_ID sh -c 'rm -rf files/wardrobe_flutter/active_pack files/wardrobe_flutter/active_pack_staging'" >/dev/null 2>&1 || {
    echo "Warning: run-as reset failed (app may keep previous active pack)." >&2
  }
fi

echo "==> Pushing content pack to app-accessible storage"
"$ADB_WIN_BIN" -s "$DEVICE_ID" shell "mkdir -p /sdcard/Android/data/$APP_ID/files" >/dev/null
"$ADB_WIN_BIN" -s "$DEVICE_ID" push "$ZIP_WIN" "/sdcard/Android/data/$APP_ID/files/wardrobe_pack.zip"
"$ADB_WIN_BIN" -s "$DEVICE_ID" push "$ZIP_WIN" /sdcard/Download/wardrobe_pack.zip >/dev/null || true

echo "==> Starting app"
"$ADB_WIN_BIN" -s "$DEVICE_ID" shell am start -n "$APP_ID/$MAIN_ACTIVITY" >/dev/null

echo "Done."
if [[ "$SYNC_BUILTIN_ASSET" == "1" ]]; then
  echo "Built-in asset synced from: $BUILTIN_SRC_ZIP"
fi
echo "In-app ZIP path (recommended): /storage/emulated/0/Android/data/$APP_ID/files/wardrobe_pack.zip"
echo "Alt path: /sdcard/Android/data/$APP_ID/files/wardrobe_pack.zip"
echo "Alt path: /sdcard/Download/wardrobe_pack.zip"
