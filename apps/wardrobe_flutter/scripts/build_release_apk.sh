#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/../.." && pwd)"
DIST_DIR="$REPO_ROOT/dist"
PACKAGE_NAME="app.wardrobe.viewer"
EXPECTED_VERSION="0.1.0"
EXPECTED_VERSION_CODE="1"
OUTPUT_NAME="wardrobe-v${EXPECTED_VERSION}-android-universal.apk"
SYMBOLS_DIR="$DIST_DIR/symbols-v${EXPECTED_VERSION}"
STAGING_ROOT=""

cleanup() {
  if [[ -n "$STAGING_ROOT" && -d "$STAGING_ROOT" ]]; then
    rm -rf -- "$STAGING_ROOT"
  fi
}
trap cleanup EXIT

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "error: $name is required for a signed release build." >&2
    echo "See apps/wardrobe_flutter/README.md for the release-signing setup." >&2
    exit 2
  fi
}

find_android_tool() {
  local tool="$1"
  local sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
  local candidate

  if command -v "$tool" >/dev/null 2>&1; then
    command -v "$tool"
    return
  fi

  if [[ -z "$sdk_root" && -f "$APP_ROOT/android/local.properties" ]]; then
    sdk_root="$(sed -n 's/^sdk\.dir=//p' "$APP_ROOT/android/local.properties" | tail -n 1)"
  fi

  if [[ -n "$sdk_root" && -d "$sdk_root/build-tools" ]]; then
    candidate="$(find "$sdk_root/build-tools" -mindepth 2 -maxdepth 2 -type f -name "$tool" -print | sort -V | tail -n 1)"
    if [[ -n "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  fi

  echo "error: unable to find Android build tool '$tool'." >&2
  exit 2
}

require_env WARDROBE_KEYSTORE_PATH
require_env WARDROBE_KEYSTORE_PASSWORD

if [[ ! -f "$WARDROBE_KEYSTORE_PATH" ]]; then
  echo "error: WARDROBE_KEYSTORE_PATH does not point to a readable file." >&2
  exit 2
fi

export WARDROBE_KEY_ALIAS="${WARDROBE_KEY_ALIAS:-wardrobe}"
export GRADLE_OPTS="${GRADLE_OPTS:+$GRADLE_OPTS }-Dorg.gradle.daemon=false"

APKSIGNER="$(find_android_tool apksigner)"
AAPT="$(find_android_tool aapt)"

mkdir -p "$DIST_DIR"

STAGING_ROOT="$(mktemp -d "/tmp/wardrobe-v${EXPECTED_VERSION}-release.XXXXXX")"
STAGING_REPO="$STAGING_ROOT/repository"
rsync -a \
  --exclude '/.git/' \
  --exclude '/.venv/' \
  --exclude '/dist/' \
  --exclude '/apps/wardrobe_flutter/.dart_tool/' \
  --exclude '/apps/wardrobe_flutter/build/' \
  --exclude '/apps/wardrobe_flutter/android/.gradle/' \
  --exclude '*.keystore' \
  --exclude '*.jks' \
  --exclude '*.p12' \
  --exclude '*.pfx' \
  "$REPO_ROOT/" "$STAGING_REPO/"
BUILD_APP_ROOT="$STAGING_REPO/apps/wardrobe_flutter"

(
  cd "$BUILD_APP_ROOT"
  flutter build apk \
    --release \
    --split-debug-info="$SYMBOLS_DIR"
)

SOURCE_APK="$BUILD_APP_ROOT/build/app/outputs/flutter-apk/app-release.apk"
OUTPUT_APK="$DIST_DIR/$OUTPUT_NAME"
install -m 0644 "$SOURCE_APK" "$OUTPUT_APK"

"$APKSIGNER" verify --verbose --print-certs "$OUTPUT_APK"

PRIVACY_HIT="$(
  unzip -p "$OUTPUT_APK" 2>/dev/null \
    | strings \
    | grep -E -m 1 '(/home/[^/]+/|/Users/[^/]+/|[A-Za-z]:\\Users\\|/mnt/[a-z]/Users/|WARDROBE_KEYSTORE_|wardrobe-release\.p12|freenet)' \
    || true
)"
if [[ -n "$PRIVACY_HIT" ]]; then
  echo "error: release APK contains a private build path or signing reference:" >&2
  echo "$PRIVACY_HIT" >&2
  exit 1
fi

BADGING_OUTPUT="$("$AAPT" dump badging "$OUTPUT_APK")"
BADGING="${BADGING_OUTPUT%%$'\n'*}"
[[ "$BADGING" == *"name='$PACKAGE_NAME'"* ]] || {
  echo "error: unexpected APK package: $BADGING" >&2
  exit 1
}
[[ "$BADGING" == *"versionName='$EXPECTED_VERSION'"* ]] || {
  echo "error: unexpected APK version name: $BADGING" >&2
  exit 1
}
[[ "$BADGING" == *"versionCode='$EXPECTED_VERSION_CODE'"* ]] || {
  echo "error: unexpected APK version code: $BADGING" >&2
  exit 1
}

PERMISSIONS="$($AAPT dump permissions "$OUTPUT_APK")"
if grep -Eq 'android\.permission\.(INTERNET|CAMERA|READ_EXTERNAL_STORAGE|WRITE_EXTERNAL_STORAGE|MANAGE_EXTERNAL_STORAGE)' <<<"$PERMISSIONS"; then
  echo "error: release APK requests a forbidden broad permission:" >&2
  grep -E 'android\.permission\.(INTERNET|CAMERA|READ_EXTERNAL_STORAGE|WRITE_EXTERNAL_STORAGE|MANAGE_EXTERNAL_STORAGE)' <<<"$PERMISSIONS" >&2
  exit 1
fi

(
  cd "$DIST_DIR"
  sha256sum "$OUTPUT_NAME" > SHA256SUMS.txt
)

CERTIFICATE_OUTPUT="$("$APKSIGNER" verify --print-certs "$OUTPUT_APK")"
CERTIFICATE_SHA256="$(sed -n 's/^Signer #1 certificate SHA-256 digest: //p' <<<"$CERTIFICATE_OUTPUT")"
if [[ -z "$CERTIFICATE_SHA256" ]]; then
  echo "error: unable to read the signing-certificate fingerprint." >&2
  exit 1
fi

printf '%s\n' "$CERTIFICATE_SHA256" > "$DIST_DIR/CERTIFICATE_SHA256.txt"

APK_SHA256="$(cut -d ' ' -f 1 "$DIST_DIR/SHA256SUMS.txt")"
APK_SIZE="$(du -h "$OUTPUT_APK" | cut -f 1)"
sed \
  -e "s/{{APK_SHA256}}/$APK_SHA256/g" \
  -e "s/{{CERTIFICATE_SHA256}}/$CERTIFICATE_SHA256/g" \
  -e "s/{{APK_SIZE}}/$APK_SIZE/g" \
  "$REPO_ROOT/.github/release-notes/v0.1.0.md.in" \
  > "$DIST_DIR/RELEASE_NOTES.md"

echo
echo "Release APK: $OUTPUT_APK"
echo "Checksums:  $DIST_DIR/SHA256SUMS.txt"
echo "Notes:      $DIST_DIR/RELEASE_NOTES.md"
echo "Symbols:    $SYMBOLS_DIR (keep private; do not upload)"
echo "Certificate SHA-256: $CERTIFICATE_SHA256"
