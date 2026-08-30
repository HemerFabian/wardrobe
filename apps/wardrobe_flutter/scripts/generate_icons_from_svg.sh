#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SVG_SRC="$APP_DIR/assets/app_icon/icon.svg"

if [[ ! -f "$SVG_SRC" ]]; then
  echo "Missing SVG source: $SVG_SRC" >&2
  exit 1
fi

if command -v magick >/dev/null 2>&1; then
  CONVERT=(magick convert)
elif command -v convert >/dev/null 2>&1; then
  CONVERT=(convert)
else
  echo "ImageMagick not found. Install 'magick' or 'convert'." >&2
  exit 1
fi

render_png() {
  local size="$1"
  local out="$2"
  mkdir -p "$(dirname "$out")"
  "${CONVERT[@]}" \
    -background none \
    "$SVG_SRC" \
    -resize "${size}x${size}" \
    -colorspace sRGB \
    -depth 8 \
    "PNG32:$out"
  echo "generated: $out (${size}x${size})"
}

# Master PNG derived from SVG.
render_png 1024 "$APP_DIR/assets/app_icon/icon.png"

# Android launcher icons.
render_png 48  "$APP_DIR/android/app/src/main/res/mipmap-mdpi/ic_launcher.png"
render_png 72  "$APP_DIR/android/app/src/main/res/mipmap-hdpi/ic_launcher.png"
render_png 96  "$APP_DIR/android/app/src/main/res/mipmap-xhdpi/ic_launcher.png"
render_png 144 "$APP_DIR/android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png"
render_png 192 "$APP_DIR/android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png"

# Android adaptive foreground layer.
render_png 108 "$APP_DIR/android/app/src/main/res/mipmap-mdpi/ic_launcher_foreground.png"
render_png 162 "$APP_DIR/android/app/src/main/res/mipmap-hdpi/ic_launcher_foreground.png"
render_png 216 "$APP_DIR/android/app/src/main/res/mipmap-xhdpi/ic_launcher_foreground.png"
render_png 324 "$APP_DIR/android/app/src/main/res/mipmap-xxhdpi/ic_launcher_foreground.png"
render_png 432 "$APP_DIR/android/app/src/main/res/mipmap-xxxhdpi/ic_launcher_foreground.png"

# Web icons.
render_png 192 "$APP_DIR/web/icons/Icon-192.png"
render_png 512 "$APP_DIR/web/icons/Icon-512.png"
render_png 192 "$APP_DIR/web/icons/Icon-maskable-192.png"
render_png 512 "$APP_DIR/web/icons/Icon-maskable-512.png"
render_png 32  "$APP_DIR/web/favicon.png"
