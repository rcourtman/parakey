#!/usr/bin/env bash
# dev-run.sh — local iteration loop for the Swift Parakey port.
#
# Rebuilds main.swift, drops the binary into a minimal .app wrapper
# at /tmp/Parakey-dev.app, signs it with the Developer ID + hardened
# runtime + the production entitlements (so TCC carries over from
# the Cask-installed Parakey, no manual permission re-grants), kills
# any prior dev instance, and relaunches via `open`.
#
# Usage: ./dev-run.sh
#
# When you're done testing and want the production Cask Parakey
# back, just `open /Applications/Parakey.app` — both binaries share
# bundle id `com.local.parakey`, so the TCC entries are
# interchangeable.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
APP="/tmp/Parakey-dev.app"

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

say "Building (debug)..."
( cd "$HERE" && swift build 2>&1 | grep -vE "^/.*warning:|^[0-9]+ \|" | tail -3 )

say "Wrapping in $APP..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$HERE/.build/debug/Parakey" "$APP/Contents/MacOS/Parakey"
# Single canonical Info.plist (swift/Info.plist) — same file
# ship-swift.sh uses, so dev and release builds advertise the same
# bundle id / minimum macOS / usage descriptions / icon. Don't
# overwrite this with an inline heredoc; the canonical Info.plist is
# the source of truth, full stop.
cp "$HERE/Info.plist" "$APP/Contents/Info.plist"
# Menubar PNGs into the canonical Contents/Resources/ slot. NSImage
# (named:) on Bundle.main finds them under this exact path. We avoid
# SwiftPM's auto-generated <Package>_<Target>.bundle because it lacks
# an Info.plist, which makes codesign --deep error out.
cp "$HERE/Resources/parakey-menubar.png"    "$APP/Contents/Resources/"
cp "$HERE/Resources/parakey-menubar@2x.png" "$APP/Contents/Resources/"
# .icns for the About dialog + dock (when "Show in Dock" is on).
if [[ -f "$REPO/icon/Parakey.icns" ]]; then
    cp "$REPO/icon/Parakey.icns" "$APP/Contents/Resources/Parakey.icns"
fi

say "Signing with Developer ID + hardened runtime..."
CERT_HASH="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk '/Developer ID Application:/ { print $2; exit }')"
[[ -n "$CERT_HASH" ]] || { echo "no Developer ID cert in keychain" >&2; exit 1; }
codesign --force --deep --sign "$CERT_HASH" \
    --options runtime \
    --entitlements "$REPO/entitlements.plist" \
    --timestamp \
    "$APP" >/dev/null 2>&1

say "Checking signed entitlements..."
EMBEDDED_ENTITLEMENTS="$(codesign -d --entitlements - "$APP" 2>&1)"
for key in \
    "com.apple.security.device.audio-input" \
    "com.apple.security.device.microphone"
do
    if ! grep -q "$key" <<<"$EMBEDDED_ENTITLEMENTS"; then
        printf '%s\n' "$EMBEDDED_ENTITLEMENTS" >&2
        echo "missing required entitlement: $key" >&2
        exit 1
    fi
done

say "Stopping any prior dev instance..."
pkill -f "Parakey-dev.app" 2>/dev/null || true
# Also kill any Cask instance — same bundle id would clash on TCC + hotkey.
pkill -f "/Applications/Parakey.app" 2>/dev/null || true
sleep 0.5

say "Launching..."
open "$APP"
sleep 1
ps aux | grep -E "Parakey-dev.app|Parakey.app" | grep -v grep | awk '{print "  pid="$2, $11}'
echo
echo "  log: tail -f ~/Library/Logs/Parakey.log"
echo "  stop: pkill -f Parakey-dev.app"
