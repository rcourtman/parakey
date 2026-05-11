#!/usr/bin/env bash
# ship-swift.sh — full release pipeline for native Swift Parakey.
#
# Designed for unattended agent operation: there's nothing to remember
# between invocations. Reads the current version out of
# swift/Info.plist, bumps it, builds a release-optimised binary, wraps
# it in a signed + notarised .app, tags the commit, creates the
# GitHub release, and updates the sibling Homebrew Cask in one shot.
#
#   ./ship-swift.sh                 # default: bump patch (0.2.0 -> 0.2.1)
#   ./ship-swift.sh --minor         # 0.2.x -> 0.3.0
#   ./ship-swift.sh --major         # 0.x.x -> 1.0.0
#   ./ship-swift.sh --version 0.2.5 # explicit
#   ./ship-swift.sh --dry-run       # build everything, skip git/tag/release/cask
#   ./ship-swift.sh --no-cask       # ship binary + GitHub release, skip Cask bump
#
# Pre-flight requires:
#   - clean working tree on `main`
#   - notary credentials stored (keychain profile "parakey-notary")
#   - gh CLI authenticated for github.com
#   - sibling Homebrew tap at ../homebrew-parakey (override with
#     PARAKEY_HOMEBREW_TAP=/path/to/tap)
#
# Recovery: if anything after the build fails, swift/Info.plist is
# the only locally-mutated file. Reset with `git checkout
# swift/Info.plist` and try again. Built artefacts in swift/dist/
# are safe to delete.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
SWIFT_DIR="$PROJECT_DIR/swift"
INFO_PLIST="$SWIFT_DIR/Info.plist"
ENTITLEMENTS="$PROJECT_DIR/entitlements.plist"
APP="$SWIFT_DIR/dist/Parakey.app"
ZIP_OUT="$SWIFT_DIR/dist/Parakey.zip"
NOTARY_PROFILE="parakey-notary"
CASK_TAP="${PARAKEY_HOMEBREW_TAP:-$PROJECT_DIR/../homebrew-parakey}"
CASK_FILE="$CASK_TAP/Casks/parakey.rb"

# ---- 0. CLI ---------------------------------------------------------------
BUMP=patch
TARGET=""
DRY_RUN=0
NO_CASK=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --patch)   BUMP=patch; shift ;;
        --minor)   BUMP=minor; shift ;;
        --major)   BUMP=major; shift ;;
        --version) TARGET="$2"; BUMP=explicit; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --no-cask) NO_CASK=1; shift ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's|^# \{0,1\}||'
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

# ---- 1. Pre-flight --------------------------------------------------------
say "Pre-flight checks"

command -v swift >/dev/null || die "swift not on PATH — install Xcode command line tools"
command -v plutil >/dev/null || die "plutil missing (macOS only)"

current_branch="$(git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD)"
[[ "$current_branch" == "main" ]] || die "not on main (currently '$current_branch')"

git -C "$PROJECT_DIR" update-index --refresh >/dev/null 2>&1 || true
if ! git -C "$PROJECT_DIR" diff-index --quiet HEAD --; then
    die "working tree has uncommitted changes — commit or stash before shipping"
fi

if [[ "$DRY_RUN" -eq 0 ]]; then
    command -v gh >/dev/null || die "'gh' CLI not installed (brew install gh)"
    gh auth status >/dev/null 2>&1 || die "'gh' is not authenticated (gh auth login)"
fi

if [[ "$NO_CASK" -eq 0 && "$DRY_RUN" -eq 0 ]]; then
    [[ -f "$CASK_FILE" ]] || die "cask not found at $CASK_FILE — set PARAKEY_HOMEBREW_TAP or use --no-cask"
    tap_branch="$(git -C "$CASK_TAP" rev-parse --abbrev-ref HEAD)"
    git -C "$CASK_TAP" update-index --refresh >/dev/null 2>&1 || true
    if ! git -C "$CASK_TAP" diff-index --quiet HEAD --; then
        die "Homebrew tap has uncommitted changes at $CASK_TAP"
    fi
fi

# ---- 2. Compute target version --------------------------------------------
current_version="$(plutil -extract CFBundleShortVersionString raw "$INFO_PLIST")"
current_build="$(plutil -extract CFBundleVersion raw "$INFO_PLIST")"
[[ -n "$current_version" ]] || die "could not read CFBundleShortVersionString from $INFO_PLIST"
[[ -n "$current_build"   ]] || die "could not read CFBundleVersion from $INFO_PLIST"

if [[ "$BUMP" == "explicit" ]]; then
    [[ "$TARGET" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "--version needs X.Y.Z, got '$TARGET'"
    new_version="$TARGET"
else
    IFS=. read -r major minor patch <<<"$current_version"
    case "$BUMP" in
        patch) new_version="$major.$minor.$((patch + 1))" ;;
        minor) new_version="$major.$((minor + 1)).0"      ;;
        major) new_version="$((major + 1)).0.0"           ;;
    esac
fi
new_build=$((current_build + 1))

say "Version: $current_version (build $current_build) -> $new_version (build $new_build)"

if git -C "$PROJECT_DIR" rev-parse "v$new_version" >/dev/null 2>&1; then
    die "tag v$new_version already exists -- pick a different version"
fi

# ---- 3. Build release-optimised binary ------------------------------------
say "Building (release)"
( cd "$SWIFT_DIR" && swift build -c release 2>&1 | tail -5 ) \
    || die "swift build failed"

BIN="$SWIFT_DIR/.build/release/Parakey"
[[ -f "$BIN" ]] || die "release build produced no $BIN"

# ---- 4. Bump Info.plist (before wrapping, so the .app carries new version)
say "Updating Info.plist version + build numbers"
plutil -replace CFBundleShortVersionString -string "$new_version" "$INFO_PLIST"
plutil -replace CFBundleVersion            -string "$new_build"  "$INFO_PLIST"
plutil -lint "$INFO_PLIST" >/dev/null || {
    git -C "$PROJECT_DIR" checkout -- "$INFO_PLIST"
    die "Info.plist invalid after rewrite (reverted)"
}

# ---- 5. Wrap binary in a fresh .app ---------------------------------------
say "Wrapping in $APP"
rm -rf "$APP" "$ZIP_OUT" "$SWIFT_DIR/dist"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Parakey"
cp "$INFO_PLIST" "$APP/Contents/Info.plist"
cp "$SWIFT_DIR/Resources/parakey-menubar.png"    "$APP/Contents/Resources/"
cp "$SWIFT_DIR/Resources/parakey-menubar@2x.png" "$APP/Contents/Resources/"
if [[ -f "$PROJECT_DIR/icon/Parakey.icns" ]]; then
    cp "$PROJECT_DIR/icon/Parakey.icns" "$APP/Contents/Resources/Parakey.icns"
fi

# ---- 6. Codesign ----------------------------------------------------------
CODESIGN_IDENTITY="${PARAKEY_CODESIGN_IDENTITY:-}"
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
    --entitlements "$ENTITLEMENTS" \
    --timestamp "$APP"
codesign --verify --deep --strict "$APP" >/dev/null
say "Signature OK ($(codesign --display --verbose=2 "$APP" 2>&1 | awk -F= '/^Authority/ {print $2; exit}'))"

# ---- 6.5 Entitlement assertion --------------------------------------------
say "Asserting required entitlements are present"
EMBEDDED_ENTITLEMENTS="$(codesign -d --entitlements - "$APP" 2>&1)"
REQUIRED_ENTITLEMENTS=(
    # Just the two microphone keys. The Python-era JIT / unsigned-exec
    # / disable-library-validation entitlements are gone — native
    # Swift + CoreML doesn't need them. If a future regression
    # re-introduces a Python runtime or unsigned dylib here, this
    # assertion will fail loudly.
    "com.apple.security.device.audio-input"
    "com.apple.security.device.microphone"
)
for key in "${REQUIRED_ENTITLEMENTS[@]}"; do
    if ! grep -q "$key" <<<"$EMBEDDED_ENTITLEMENTS"; then
        printf '%s\n' "$EMBEDDED_ENTITLEMENTS" >&2
        die "missing required entitlement: $key"
    fi
done
say "All required entitlements present"

# ---- 7. Notarise ----------------------------------------------------------
if [[ "$DRY_RUN" -eq 0 ]]; then
    if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        say "Notarising (typically 1-3 minutes)"
        NOTARIZE_ZIP="$(mktemp -d)/parakey-notarize.zip"
        /usr/bin/ditto -c -k --keepParent "$APP" "$NOTARIZE_ZIP"
        xcrun notarytool submit "$NOTARIZE_ZIP" \
            --keychain-profile "$NOTARY_PROFILE" --wait
        rm -f "$NOTARIZE_ZIP"
        say "Stapling notarisation ticket"
        xcrun stapler staple "$APP"
        xcrun stapler validate "$APP"
    else
        die "no notary credentials -- run xcrun notarytool store-credentials parakey-notary first"
    fi
else
    warn "Dry run: skipping notarisation"
fi

# ---- 8. Zip ---------------------------------------------------------------
say "Packaging Parakey.zip"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP_OUT"
ZIP_SHA="$(shasum -a 256 "$ZIP_OUT" | awk '{print $1}')"
ZIP_SIZE="$(du -h "$ZIP_OUT" | cut -f1)"
say "Built $ZIP_OUT ($ZIP_SIZE, sha256 $ZIP_SHA)"

# Tidy up the unzipped .app so Spotlight / Launch Services don't
# accidentally favour it over /Applications/Parakey.app.
rm -rf "$APP"

if [[ "$DRY_RUN" -eq 1 ]]; then
    say "Dry run -- stopping before git/tag/release/cask. Reverting Info.plist."
    git -C "$PROJECT_DIR" checkout -- "$INFO_PLIST"
    say "Done (dry run)."
    exit 0
fi

# ---- 9. Commit, tag, push -------------------------------------------------
say "Committing version bump"
git -C "$PROJECT_DIR" add "$INFO_PLIST"
git -C "$PROJECT_DIR" commit -m "Release v$new_version"
git -C "$PROJECT_DIR" tag "v$new_version"

say "Pushing main + tag"
git -C "$PROJECT_DIR" push origin main --follow-tags

# ---- 10. GitHub release ---------------------------------------------------
say "Creating GitHub release v$new_version"
prev_tag="$(git -C "$PROJECT_DIR" describe --tags --abbrev=0 "v$new_version^" 2>/dev/null || true)"
if [[ -n "$prev_tag" ]]; then
    range="$prev_tag..v$new_version"
    notes="$(git -C "$PROJECT_DIR" log --pretty='- %s' "$range")"
else
    notes="Initial Swift release."
fi
gh release create "v$new_version" "$ZIP_OUT" \
    --repo rcourtman/parakey \
    --title "v$new_version" \
    --notes "$notes" \
    || die "gh release create failed -- tag is pushed; re-run gh release manually"

# ---- 11. Homebrew Cask bump -----------------------------------------------
if [[ "$NO_CASK" -eq 1 ]]; then
    say "Skipping Cask bump (--no-cask)"
else
    say "Updating Homebrew Cask at $CASK_FILE"
    # Use python for the rewrite so we don't have to worry about
    # quoting / escapes inside Ruby strings.
    /usr/bin/python3 - "$CASK_FILE" "$new_version" "$ZIP_SHA" <<'PY'
import re, sys, pathlib
path, new_version, new_sha = sys.argv[1], sys.argv[2], sys.argv[3]
src = pathlib.Path(path).read_text()
src = re.sub(r'(version\s+")[^"]+(")', rf'\g<1>{new_version}\g<2>', src, count=1)
src = re.sub(r'(sha256\s+")[^"]+(")',  rf'\g<1>{new_sha}\g<2>',     src, count=1)
pathlib.Path(path).write_text(src)
PY
    grep -q "version \"$new_version\"" "$CASK_FILE" || die "cask rewrite failed (version)"
    grep -q "sha256 \"$ZIP_SHA\""      "$CASK_FILE" || die "cask rewrite failed (sha256)"

    git -C "$CASK_TAP" add Casks/parakey.rb
    git -C "$CASK_TAP" commit -m "parakey $new_version"
    git -C "$CASK_TAP" push origin "$tap_branch"
fi

# ---- 12. Done -------------------------------------------------------------
say "Shipped v$new_version"
echo
echo "  GitHub:   https://github.com/rcourtman/parakey/releases/tag/v$new_version"
echo "  Cask:     brew upgrade --cask parakey   (after tap pulls)"
echo
