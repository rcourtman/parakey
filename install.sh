#!/usr/bin/env bash
# Parakey installer — sets up the venv, installs the app bundle, the
# LaunchAgent, signs the bundle, and loads the agent.
#
# Usage: ./install.sh
#
# Idempotent: safe to re-run after pulling updates.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DEST="$HOME/Applications/Parakey.app"
PLIST_DEST="$HOME/Library/LaunchAgents/com.local.parakey.plist"

# Override to pick a specific signing identity, e.g.
#     PARAKEY_CODESIGN_IDENTITY="My Cert" ./install.sh
# Otherwise the first available "Developer ID Application:" cert is used,
# falling back to ad-hoc signing if none is found.
CODESIGN_IDENTITY="${PARAKEY_CODESIGN_IDENTITY:-}"

say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

say "Project directory: $PROJECT_DIR"

# Detect first install vs upgrade so we only run the permissions flow once.
IS_FIRST_INSTALL=0
[[ ! -e "$APP_DEST" ]] && IS_FIRST_INSTALL=1

# --- Dependency checks ------------------------------------------------------
say "Checking system dependencies"
command -v python3 >/dev/null || die "python3 not found. Install via brew: brew install python"
command -v ffmpeg  >/dev/null || die "ffmpeg not found. Install via brew: brew install ffmpeg"
[[ "$(uname -m)" == "arm64" ]] || warn "This Mac is not Apple Silicon — Parakeet-MLX will not work."

# --- Python venv + deps -----------------------------------------------------
VENV="$PROJECT_DIR/.venv"
if [[ ! -d "$VENV" ]]; then
    say "Creating venv at $VENV"
    python3 -m venv "$VENV"
fi
say "Installing Python dependencies"
"$VENV/bin/pip" install --quiet --upgrade pip
"$VENV/bin/pip" install --quiet -r "$PROJECT_DIR/requirements.txt"

# --- App bundle -------------------------------------------------------------
say "Installing Parakey.app to $APP_DEST"
mkdir -p "$APP_DEST/Contents/MacOS" "$APP_DEST/Contents/Resources"
cp "$PROJECT_DIR/templates/Parakey.app/Contents/Info.plist"  "$APP_DEST/Contents/Info.plist"
cp "$PROJECT_DIR/templates/Parakey.app/Contents/MacOS/parakey" "$APP_DEST/Contents/MacOS/parakey"
chmod +x "$APP_DEST/Contents/MacOS/parakey"
if [[ -f "$PROJECT_DIR/icon/Parakey.icns" ]]; then
    cp "$PROJECT_DIR/icon/Parakey.icns" "$APP_DEST/Contents/Resources/Parakey.icns"
else
    warn "icon/Parakey.icns missing — bundle will use generic icon"
fi
plutil -lint "$APP_DEST/Contents/Info.plist" >/dev/null

# --- LaunchAgent ------------------------------------------------------------
say "Installing LaunchAgent to $PLIST_DEST"
mkdir -p "$(dirname "$PLIST_DEST")"
sed "s|__HOME__|$HOME|g" "$PROJECT_DIR/templates/com.local.parakey.plist" > "$PLIST_DEST"
plutil -lint "$PLIST_DEST" >/dev/null

# --- Codesign ---------------------------------------------------------------
if [[ -n "$CODESIGN_IDENTITY" ]]; then
    say "Signing bundle with override identity: $CODESIGN_IDENTITY"
    codesign --force --deep --sign "$CODESIGN_IDENTITY" --options runtime --timestamp "$APP_DEST"
else
    CERT_HASH="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk '/Developer ID Application:/ { print $2; exit }')"
    if [[ -n "$CERT_HASH" ]]; then
        say "Signing bundle with Developer ID ($CERT_HASH)"
        codesign --force --deep --sign "$CERT_HASH" --options runtime --timestamp "$APP_DEST"
    else
        warn "No Developer ID cert found — falling back to ad-hoc signing"
        say "Ad-hoc signing bundle"
        codesign --force --deep --sign - "$APP_DEST"
    fi
fi
codesign --verify --deep --strict "$APP_DEST" >/dev/null && say "Signature OK"

# --- LaunchAgent (re)load ---------------------------------------------------
say "(Re)loading LaunchAgent"
launchctl bootout "gui/$(id -u)/com.local.parakey" 2>/dev/null || true
# bootout is asynchronous; retry bootstrap a few times if it loses the race.
for attempt in 1 2 3 4 5; do
    if launchctl bootstrap "gui/$(id -u)" "$PLIST_DEST" 2>/dev/null; then
        break
    fi
    if [[ $attempt -eq 5 ]]; then
        die "launchctl bootstrap failed after 5 attempts"
    fi
    sleep 1
done

# --- Done -------------------------------------------------------------------
if [[ "$IS_FIRST_INSTALL" == "1" ]]; then
    say "First install — opening Privacy & Security panes"
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"  >/dev/null 2>&1 || true
    sleep 0.4
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" >/dev/null 2>&1 || true
    sleep 0.4
    open "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent" >/dev/null 2>&1 || true

    cat <<EOF

================================================================
NEXT STEP — grant Parakey.app three permissions

The three Privacy & Security panes have been opened for you. In each
one, add Parakey.app from ~/Applications/ and toggle it ON:

  1. Microphone
  2. Accessibility
  3. Input Monitoring

When all three are toggled on, run:

    launchctl kickstart -k gui/\$(id -u)/com.local.parakey

Then hold Right Control to dictate. You should hear a tink when
recording starts and a pop when the transcript is pasted.
================================================================

EOF
else
    cat <<EOF

Parakey is installed and running. Hold Right Control to dictate.

To restart manually:
    launchctl kickstart -k gui/\$(id -u)/com.local.parakey

EOF
fi
