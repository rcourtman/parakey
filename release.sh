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

# --- 0. Pre-clean -----------------------------------------------------------
# Kill any leftover Parakey instance launched from a previous build's
# dist/ directory. Spotlight indexes that path and the user can
# accidentally launch it from there, leading to two menu-bar icons.
# (We deliberately do NOT touch /Applications/Parakey.app — that's
# the brew-installed copy and may be in active use.)
if pgrep -f "$PROJECT_DIR/dist/Parakey.app" >/dev/null 2>&1; then
    say "Stopping leftover Parakey instance from previous build"
    pkill -f "$PROJECT_DIR/dist/Parakey.app" 2>/dev/null || true
    sleep 1
fi

# --- 1. PyInstaller build ---------------------------------------------------
say "Building bundle with PyInstaller"
[[ -d "$PROJECT_DIR/.venv" ]] || die "venv missing — run install.sh first"
rm -rf "$PROJECT_DIR/build" "$PROJECT_DIR/dist"
"$PROJECT_DIR/.venv/bin/pyinstaller" --noconfirm "$PROJECT_DIR/Parakey.spec" \
    >/tmp/parakey-build.log 2>&1 \
    || { tail -40 /tmp/parakey-build.log; die "PyInstaller build failed (full log: /tmp/parakey-build.log)"; }
[[ -d "$APP" ]] || die "PyInstaller produced no Parakey.app"
say "Built $(du -sh "$APP" | cut -f1) bundle"

# --- 1.5 Embedded Python.framework Info.plist tweaks ------------------------
# Two goals:
#   1. Identify as Parakey (not Python) when macOS walks framework metadata
#      for tooltips / dock attribution / Privacy panes.
#   2. Preserve NSMicrophoneUsageDescription on whichever Info.plist macOS
#      consults when AVCaptureDevice.requestAccess decides whether to show
#      its prompt — without this, a PyInstaller-bundled app gets denied
#      silently because the framework's plist looks "incomplete."
PY_INFO="$APP/Contents/Frameworks/Python.framework/Versions/3.14/Resources/Info.plist"
if [[ -f "$PY_INFO" ]]; then
    say "Patching embedded Python.framework Info.plist (identity + usage descriptions)"
    plutil -replace CFBundleIdentifier  -string "com.local.parakey.python" "$PY_INFO"
    plutil -replace CFBundleName        -string "Parakey" "$PY_INFO"
    plutil -replace CFBundleDisplayName -string "Parakey" "$PY_INFO"
    plutil -replace NSMicrophoneUsageDescription -string \
        "Parakey records audio while you hold the dictation hotkey, then transcribes it locally on your Mac." \
        "$PY_INFO"
    plutil -replace NSAppleEventsUsageDescription -string \
        "Parakey uses System Events to paste transcribed text at your cursor." \
        "$PY_INFO"
fi

# --- 2. Codesign ------------------------------------------------------------
if [[ -n "$CODESIGN_IDENTITY" ]]; then
    CERT="$CODESIGN_IDENTITY"
else
    CERT="$(security find-identity -v -p codesigning 2>/dev/null \
            | awk '/Developer ID Application:/ { print $2; exit }')"
fi
[[ -n "$CERT" ]] || die "No Developer ID Application cert in keychain"

say "Signing bundle (cert $CERT)"
codesign --force --deep --sign "$CERT" \
    --options runtime \
    --entitlements "$PROJECT_DIR/entitlements.plist" \
    --timestamp "$APP"
codesign --verify --deep --strict "$APP" >/dev/null
say "Signature OK ($(codesign --display --verbose=2 "$APP" 2>&1 | awk -F= '/^Authority/ {print $2; exit}'))"

# --- 2.5 Entitlement assertion --------------------------------------------
# A missing or wrong entitlement is silent at the bundle level — Gatekeeper
# accepts the signed app, notarisation passes, the user just can't actually
# use the feature. macOS Tahoe 26 made this worse by tightening which
# microphone entitlement key it honours. Fail loudly here, before we spend
# 1–3 minutes notarising a broken build.
say "Asserting required entitlements are present in the signed bundle"
EMBEDDED_ENTITLEMENTS="$(codesign -d --entitlements - "$APP" 2>&1)"
REQUIRED_ENTITLEMENTS=(
    "com.apple.security.cs.allow-jit"
    "com.apple.security.cs.allow-unsigned-executable-memory"
    "com.apple.security.cs.disable-library-validation"
    "com.apple.security.device.audio-input"   # Tahoe 26+: hardened-runtime microphone
    "com.apple.security.device.microphone"    # legacy compatibility
)
for key in "${REQUIRED_ENTITLEMENTS[@]}"; do
    if ! grep -q "$key" <<<"$EMBEDDED_ENTITLEMENTS"; then
        warn "Embedded entitlements:"
        printf '%s\n' "$EMBEDDED_ENTITLEMENTS" >&2
        die "missing required entitlement: $key — refusing to ship a build that won't work"
    fi
done
say "All required entitlements present"

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

# --- 5. Post-clean ----------------------------------------------------------
# Remove the unzipped dist/Parakey.app and the PyInstaller intermediate
# build/ directory. The .zip is the canonical release artifact; leaving
# the .app behind invites Spotlight / Launch Services to launch it
# instead of the installed /Applications/Parakey.app, producing the
# duplicate-instances bug we hit in v0.1.1 testing.
say "Cleaning intermediate build artefacts"
# PyInstaller produces both dist/Parakey/ (the COLLECT directory)
# and dist/Parakey.app (the BUNDLE wrapping it). Both can be
# launched, so both go.
rm -rf "$APP" "$PROJECT_DIR/dist/Parakey" "$PROJECT_DIR/build"

say "Done"
echo
echo "  $ZIP_OUT  ($(du -h "$ZIP_OUT" | cut -f1))"
echo
echo "  Distribute the zip; the unpacked .app has been removed to avoid"
echo "  accidentally running it instead of the installed copy in"
echo "  /Applications/."
