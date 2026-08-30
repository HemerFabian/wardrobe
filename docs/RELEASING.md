# Android Release Process

This process creates the directly distributed Android APK for Wardrobe. The
private signing key and its passwords must never be committed, uploaded as a
release asset, pasted into an issue, or stored in a shell-history command.

## One-time signing key

Create a dedicated PKCS#12 keystore outside the repository. Run `keytool`
interactively so the password is not written to shell history:

```bash
keytool -genkeypair \
  -keystore /secure/path/wardrobe-release.p12 \
  -storetype PKCS12 \
  -alias wardrobe \
  -keyalg RSA \
  -keysize 4096 \
  -validity 10000 \
  -dname "CN=Wardrobe Release,O=Wardrobe"
```

Store the password in a password manager. Keep a second encrypted copy of the
keystore outside WSL and confirm that it can be read with:

```bash
keytool -list -v -keystore /secure/path/wardrobe-release.p12 -alias wardrobe
```

Losing this key prevents Android from accepting later Wardrobe APKs as updates
to an installed copy. Publishing is blocked until both the password-manager
entry and the encrypted backup have been confirmed.

## Build and verify

Export the signing inputs for the current shell. The key password is the same
as the PKCS#12 store password.

```bash
export WARDROBE_KEYSTORE_PATH=/secure/path/wardrobe-release.p12
read -rsp "Wardrobe keystore password: " WARDROBE_KEYSTORE_PASSWORD
export WARDROBE_KEYSTORE_PASSWORD
export WARDROBE_KEY_ALIAS=wardrobe

apps/wardrobe_flutter/scripts/build_release_apk.sh
unset WARDROBE_KEYSTORE_PASSWORD
```

The ignored `dist/` directory will contain:

- `wardrobe-v0.1.0-android-universal.apk`
- `SHA256SUMS.txt`
- `CERTIFICATE_SHA256.txt`
- `RELEASE_NOTES.md`
- `symbols-v0.1.0/` with private Dart symbol files for local diagnostics

The script verifies the APK signature and requires package
`app.wardrobe.viewer`, version name `0.1.0`, version code `1`, and no normal
Internet, camera, or broad external-storage permission.
The split symbol files keep local build paths out of the APK. They remain
ignored and private; do not attach them to the GitHub release.

## Publish

1. Install the APK on a clean Android emulator and run the documented app
   acceptance checks.
2. Confirm `SHA256SUMS.txt` with `sha256sum --check SHA256SUMS.txt`.
3. Use `dist/RELEASE_NOTES.md` as the GitHub release notes.
4. Attach only the APK and `SHA256SUMS.txt`; never attach the keystore.
5. Keep the repository private until the final release review is complete.
