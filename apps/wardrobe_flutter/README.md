# Wardrobe Flutter

Flutter client for capturing wardrobe inputs and browsing offline content
packs. Android is the supported app target for v0.1.0.

## Install the signed Android build

Download `wardrobe-v0.1.0-android-universal.apk` and `SHA256SUMS.txt` from the
[v0.1.0 release](https://github.com/HemerFabian/wardrobe/releases/tag/v0.1.0).
The universal APK supports ARM64, ARMv7, and x86_64 Android devices.

Android will ask for permission to install an app from outside Google Play.
Only install the APK downloaded from this repository's release page, and
compare its SHA-256 digest with `SHA256SUMS.txt` first. The release notes also
publish the signing-certificate fingerprint used for future Wardrobe updates.

## Development

```bash
flutter pub get
flutter run
```

## Checks

```bash
flutter analyze
flutter test
flutter build apk --debug
```

## Signed release build

Android requires every installable APK to be signed. Wardrobe release builds
must use the dedicated project key and deliberately refuse to fall back to the
standard debug key.

Set the local signing inputs without adding them to the repository:

```bash
export WARDROBE_KEYSTORE_PATH=/secure/path/wardrobe-release.p12
export WARDROBE_KEYSTORE_PASSWORD='use-your-password-manager'
export WARDROBE_KEY_ALIAS=wardrobe
./scripts/build_release_apk.sh
```

The script builds and verifies a universal APK, checks its package, version,
and sensitive permissions, and writes the ignored release files to `dist/` at
the repository root. See [`docs/RELEASING.md`](../../docs/RELEASING.md) for key
creation, backup, verification, and release steps.

## App Icon Workflow

The app icon source of truth is:

```text
assets/app_icon/icon.svg
```

Regenerate Android and web icons with:

```bash
./scripts/generate_icons_from_svg.sh
```
