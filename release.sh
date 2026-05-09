#!/usr/bin/env bash
# release.sh — build, sign, notarise, and package Parakey for distribution.
#
# Output: dist/Parakey.app  (signed, notarised, ready to drag-install)
#         dist/Parakey.zip  (the same .app zipped for GitHub Releases)
#
# Notarisation is skipped automatically if you haven't stored notary
# credentials yet. One-time setup:
#
#   xcrun notarytool store-credentials parakey-notary \
#       --apple-id <YOUR_APPLE_ID>             \
#       --team-id  UJD57YVK2B                  \
#       --password <APP_SPECIFIC_PASSWORD>
#
# Generate the app-specific password at https://appleid.apple.com under
# "Sign-in and Security → App-Specific Passwords".
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$PROJECT_DIR/dist/Parakey.app"
ZIP_OUT="$PROJECT_DIR/dist/Parakey.zip"
NOTARY_PROFILE="parakey-notary"

# Override to pick a specific signing identity, otherwise the first
# "Developer ID Application:" cert is used.
CODESIGN_IDENTITY="${PARAKEY_CODESIGN_IDENTITY:-}"

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

# --- 1. PyInstaller build ---------------------------------------------------
say "Building bundle with PyInstaller"
[[ -d "$PROJECT_DIR/.venv" ]] || die "venv missing — run install.sh first"
rm -rf "$PROJECT_DIR/build" "$PROJECT_DIR/dist"
"$PROJECT_DIR/.venv/bin/pyinstaller" --noconfirm "$PROJECT_DIR/Parakey.spec" \
    >/tmp/parakey-build.log 2>&1 \
    || { tail -40 /tmp/parakey-build.log; die "PyInstaller build failed (full log: /tmp/parakey-build.log)"; }
[[ -d "$APP" ]] || die "PyInstaller produced no Parakey.app"
say "Built $(du -sh "$APP" | cut -f1) bundle"

# --- 2. Codesign ------------------------------------------------------------
if [[ -n "$CODESIGN_IDENTITY" ]]; then
    CERT="$CODESIGN_IDENTITY"
else
    CERT="$(security find-identity -v -p codesigning 2>/dev/null \
            | awk '/Developer ID Application:/ { print $2; exit }')"
fi
[[ -n "$CERT" ]] || die "No Developer ID Application cert in keychain"

say "Signing bundle (cert $CERT)"
codesign --force --deep --sign "$CERT" --options runtime --timestamp "$APP"
codesign --verify --deep --strict "$APP" >/dev/null
say "Signature OK ($(codesign --display --verbose=2 "$APP" 2>&1 | awk -F= '/^Authority/ {print $2; exit}'))"

# --- 3. Notarise (optional) -------------------------------------------------
if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    say "Notarising (this typically takes 1–3 minutes)"
    NOTARIZE_ZIP="$(mktemp -d)/parakey-notarize.zip"
    /usr/bin/ditto -c -k --keepParent "$APP" "$NOTARIZE_ZIP"
    xcrun notarytool submit "$NOTARIZE_ZIP" \
        --keychain-profile "$NOTARY_PROFILE" --wait
    rm -f "$NOTARIZE_ZIP"

    say "Stapling notarisation ticket"
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
else
    warn "No notary credentials stored (xcrun keychain profile '$NOTARY_PROFILE')"
    warn "Skipping notarisation. Users will see Gatekeeper warnings on first launch."
    warn "To enable, run once:"
    warn "  xcrun notarytool store-credentials $NOTARY_PROFILE \\"
    warn "      --apple-id <YOUR_APPLE_ID> \\"
    warn "      --team-id  UJD57YVK2B \\"
    warn "      --password <APP_SPECIFIC_PASSWORD>"
fi

# --- 4. Zip for release -----------------------------------------------------
say "Packaging Parakey.zip"
rm -f "$ZIP_OUT"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP_OUT"
say "Done"
echo
echo "  $APP"
echo "  $ZIP_OUT  ($(du -h "$ZIP_OUT" | cut -f1))"
