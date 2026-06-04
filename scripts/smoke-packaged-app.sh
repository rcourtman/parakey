#!/usr/bin/env bash
# Build a throwaway .app bundle and verify the packaging contract used by
# dev-run.sh and ship-swift.sh without notarising or publishing anything.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SWIFT_DIR="$PROJECT_DIR/swift"
ENTITLEMENTS="$PROJECT_DIR/entitlements.plist"
APP="${PARAKEY_SMOKE_APP:-${TMPDIR:-/tmp}/Parakey-smoke.app}"

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

say "Building debug binary"
( cd "$SWIFT_DIR" && swift build ) >/dev/null

say "Wrapping $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$SWIFT_DIR/.build/debug/Parakey" "$APP/Contents/MacOS/Parakey"
cp "$SWIFT_DIR/Info.plist" "$APP/Contents/Info.plist"
cp "$SWIFT_DIR/Resources/parakey-menubar.png" "$APP/Contents/Resources/"
cp "$SWIFT_DIR/Resources/parakey-menubar@2x.png" "$APP/Contents/Resources/"
if [[ -f "$PROJECT_DIR/icon/Parakey.icns" ]]; then
    cp "$PROJECT_DIR/icon/Parakey.icns" "$APP/Contents/Resources/Parakey.icns"
fi

say "Checking bundle metadata and resources"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
bundle_id="$(plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist")"
[[ "$bundle_id" == "com.local.parakey" ]] || die "unexpected bundle id: $bundle_id"
min_system="$(plutil -extract LSMinimumSystemVersion raw "$APP/Contents/Info.plist")"
[[ "$min_system" == "14.0" ]] || die "unexpected minimum macOS version: $min_system"
[[ -x "$APP/Contents/MacOS/Parakey" ]] || die "missing executable"
[[ -s "$APP/Contents/Resources/parakey-menubar.png" ]] || die "missing menubar PNG"
[[ -s "$APP/Contents/Resources/parakey-menubar@2x.png" ]] || die "missing menubar @2x PNG"
[[ -s "$APP/Contents/Resources/Parakey.icns" ]] || die "missing app icon"

say "Signing ad hoc with production entitlements"
codesign --force --deep --sign - \
    --options runtime \
    --entitlements "$ENTITLEMENTS" \
    "$APP" >/dev/null
codesign --verify --deep --strict "$APP" >/dev/null

say "Checking embedded entitlements"
embedded="$(codesign -d --entitlements - "$APP" 2>&1)"
for key in \
    "com.apple.security.device.audio-input" \
    "com.apple.security.device.microphone"
do
    grep -q "$key" <<<"$embedded" || {
        printf '%s\n' "$embedded" >&2
        die "missing required entitlement: $key"
    }
done

say "Running packaged self-tests"
"$APP/Contents/MacOS/Parakey" --self-test all >/dev/null

say "Packaged app smoke test passed"
