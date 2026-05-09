#!/usr/bin/env bash
# Regenerate the .icns and menu bar PNGs from the canonical SVG sources.
# Run this whenever icon/parakey.svg or icon/parakey-menubar.svg changes.
set -euo pipefail

cd "$(dirname "$0")"

command -v rsvg-convert >/dev/null || { echo "rsvg-convert missing — brew install librsvg"; exit 1; }
command -v iconutil     >/dev/null || { echo "iconutil missing (should ship with Xcode CLT)"; exit 1; }

# --- App icon (.icns) -------------------------------------------------------
ICONSET="parakey.iconset"
rm -rf "$ICONSET"
mkdir  "$ICONSET"

declare -a SIZES=(16 32 128 256 512)
for s in "${SIZES[@]}"; do
    rsvg-convert -w  "$s"        -h  "$s"        parakey.svg > "$ICONSET/icon_${s}x${s}.png"
    rsvg-convert -w  "$((s*2))"  -h  "$((s*2))"  parakey.svg > "$ICONSET/icon_${s}x${s}@2x.png"
done
# 1024x1024 is only needed at @1x (icon_512x512@2x covers retina at the largest size)

iconutil --convert icns "$ICONSET" --output Parakey.icns
echo "  built Parakey.icns"

# --- Menu bar template ------------------------------------------------------
# @2x must be quoted so the shell doesn't try to glob the [email pattern.
rsvg-convert -w 22 -h 22 parakey-menubar.svg --output 'parakey-menubar.png'
rsvg-convert -w 44 -h 44 parakey-menubar.svg --output 'parakey-menubar@2x.png'
echo "  built parakey-menubar.png + parakey-menubar@2x.png"

# Clean up the iconset; we only need the .icns
rm -rf "$ICONSET"
echo "Done."
