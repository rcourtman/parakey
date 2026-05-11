#!/usr/bin/env bash
# ship.sh — full end-to-end Parakey release pipeline.
#
# Designed for unattended agent operation: there is nothing to remember
# between invocations. Reads the current version out of Parakey.spec,
# bumps it, builds + notarises the .app, tags the commit, creates the
# GitHub release, and updates the sibling Homebrew Cask in one shot.
#
#   ./ship.sh                 # default: bump patch (0.1.1 → 0.1.2)
#   ./ship.sh --minor         # 0.1.x → 0.2.0
#   ./ship.sh --major         # 0.x.x → 1.0.0
#   ./ship.sh --version 0.1.5 # explicit
#   ./ship.sh --dry-run       # build everything, skip git/tag/release/cask
#   ./ship.sh --no-cask       # ship binary + GitHub release, skip Cask bump
#
# Pre-flight requires:
#   - clean working tree on `main`
#   - .venv installed (run install.sh once if not)
#   - notary credentials stored (release.sh will warn if not)
#   - gh CLI authenticated for github.com (`gh auth status`)
#   - sibling Homebrew tap at ../homebrew-parakey (override with
#     PARAKEY_HOMEBREW_TAP=/path/to/tap)
#
# Recovery: if anything after the build fails, Parakey.spec is the only
# locally-mutated file. Reset with `git checkout Parakey.spec` and try
# again. Built artefacts in dist/ are safe to delete.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
SPEC="$PROJECT_DIR/Parakey.spec"
CASK_TAP="${PARAKEY_HOMEBREW_TAP:-$PROJECT_DIR/../homebrew-parakey}"
CASK_FILE="$CASK_TAP/Casks/parakey.rb"

# --- 0. CLI ----------------------------------------------------------------
BUMP=patch
TARGET=""
DRY_RUN=0
NO_CASK=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --patch)     BUMP=patch; shift ;;
        --minor)     BUMP=minor; shift ;;
        --major)     BUMP=major; shift ;;
        --version)   TARGET="$2"; BUMP=explicit; shift 2 ;;
        --dry-run)   DRY_RUN=1; shift ;;
        --no-cask)   NO_CASK=1; shift ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's|^# \{0,1\}||'
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

# --- 1. Pre-flight ---------------------------------------------------------
say "Pre-flight checks"

[[ -d "$PROJECT_DIR/.venv" ]] || die "missing .venv — run ./install.sh first"

# Sync venv with requirements.txt. Idempotent: pip is a no-op if every
# package is already at the pinned version. Picks up new deps (e.g.
# pyinstaller arriving here in 2026-05) without a separate install step.
say "Syncing venv with requirements.txt"
"$PROJECT_DIR/.venv/bin/pip" install --quiet --upgrade pip
"$PROJECT_DIR/.venv/bin/pip" install --quiet -r "$PROJECT_DIR/requirements.txt"

current_branch="$(git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD)"
[[ "$current_branch" == "main" ]] || die "not on main (currently '$current_branch')"

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
    if ! git -C "$CASK_TAP" diff-index --quiet HEAD --; then
        die "Homebrew tap has uncommitted changes at $CASK_TAP"
    fi
fi

# --- 2. Compute target version ---------------------------------------------
# Pull current CFBundleShortVersionString out of Parakey.spec. The spec is
# Python; we don't import it (would need PyInstaller), just regex it.
current_version="$(awk -F\" '/CFBundleShortVersionString/ {print $4; exit}' "$SPEC")"
current_build="$(awk -F\" '/CFBundleVersion/ {print $4; exit}' "$SPEC")"
[[ -n "$current_version" ]] || die "could not parse CFBundleShortVersionString from $SPEC"
[[ -n "$current_build"   ]] || die "could not parse CFBundleVersion from $SPEC"

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

say "Version: $current_version (build $current_build) → $new_version (build $new_build)"

# Refuse to re-release a version that already has a git tag.
if git -C "$PROJECT_DIR" rev-parse "v$new_version" >/dev/null 2>&1; then
    die "tag v$new_version already exists — pick a different version"
fi

# --- 3. Run unit tests + compile sanity ------------------------------------
say "Running unit tests"
( cd "$PROJECT_DIR" && "$PROJECT_DIR/.venv/bin/python" -m unittest discover -s tests -q ) \
    || die "unit tests failed — aborting release"

say "Compile sanity check"
"$PROJECT_DIR/.venv/bin/python" -m py_compile \
    "$PROJECT_DIR/parakey.py" \
    "$PROJECT_DIR/warmup_gate.py" \
    "$PROJECT_DIR/inference_worker.py" \
    "$PROJECT_DIR/update_check.py" \
    "$PROJECT_DIR/bench.py" \
    "$PROJECT_DIR/bench_idle.py" \
    || die "py_compile failed"

# --- 4. Bump version in Parakey.spec ---------------------------------------
say "Updating Parakey.spec"
# Use python for the rewrite so we don't have to worry about quoting/escapes.
"$PROJECT_DIR/.venv/bin/python" - "$SPEC" "$new_version" "$new_build" <<'PY'
import re, sys, pathlib
path, new_version, new_build = sys.argv[1], sys.argv[2], sys.argv[3]
src = pathlib.Path(path).read_text()
src = re.sub(r'("CFBundleShortVersionString":\s*")[^"]+(")', rf'\g<1>{new_version}\g<2>', src, count=1)
src = re.sub(r'("CFBundleVersion":\s*")[^"]+(")',           rf'\g<1>{new_build}\g<2>',  src, count=1)
pathlib.Path(path).write_text(src)
PY
grep -q "\"CFBundleShortVersionString\": \"$new_version\"" "$SPEC" \
    || die "Parakey.spec rewrite failed (CFBundleShortVersionString)"
grep -q "\"CFBundleVersion\": \"$new_build\"" "$SPEC" \
    || die "Parakey.spec rewrite failed (CFBundleVersion)"

# --- 5. Build, sign, notarise, zip -----------------------------------------
say "Building release artefacts (release.sh)"
"$PROJECT_DIR/release.sh" || {
    warn "release.sh failed — reverting Parakey.spec"
    git -C "$PROJECT_DIR" checkout -- "$SPEC"
    die "build failed; Parakey.spec restored"
}

ZIP="$PROJECT_DIR/dist/Parakey.zip"
[[ -f "$ZIP" ]] || die "expected $ZIP after release.sh, not found"
ZIP_SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
ZIP_SIZE="$(du -h "$ZIP" | cut -f1)"
say "Built $ZIP ($ZIP_SIZE, sha256 $ZIP_SHA)"

if [[ "$DRY_RUN" -eq 1 ]]; then
    say "Dry run — stopping before git/tag/release/cask. Reverting spec."
    git -C "$PROJECT_DIR" checkout -- "$SPEC"
    say "Done (dry run)."
    exit 0
fi

# --- 6. Commit version bump + tag + push -----------------------------------
say "Committing version bump"
git -C "$PROJECT_DIR" add "$SPEC"
git -C "$PROJECT_DIR" commit -m "Release v$new_version"
git -C "$PROJECT_DIR" tag "v$new_version"

say "Pushing main + tag"
git -C "$PROJECT_DIR" push origin main --follow-tags

# --- 7. Create GitHub release with the zip ---------------------------------
say "Creating GitHub release v$new_version"
# Notes: list commits since previous tag, falling back to a sensible default.
prev_tag="$(git -C "$PROJECT_DIR" describe --tags --abbrev=0 "v$new_version^" 2>/dev/null || true)"
if [[ -n "$prev_tag" ]]; then
    range="$prev_tag..v$new_version"
    notes="$(git -C "$PROJECT_DIR" log --pretty='- %s' "$range")"
else
    notes="Initial tagged release."
fi
gh release create "v$new_version" "$ZIP" \
    --repo rcourtman/parakey \
    --title "v$new_version" \
    --notes "$notes" \
    || die "gh release create failed — tag is pushed; re-run gh release manually"

# --- 8. Update Homebrew Cask -----------------------------------------------
if [[ "$NO_CASK" -eq 1 ]]; then
    say "Skipping Cask bump (--no-cask)"
else
    say "Updating Homebrew Cask at $CASK_FILE"
    "$PROJECT_DIR/.venv/bin/python" - "$CASK_FILE" "$new_version" "$ZIP_SHA" <<'PY'
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

# --- 9. Done ---------------------------------------------------------------
say "Shipped v$new_version"
echo
echo "  GitHub:   https://github.com/rcourtman/parakey/releases/tag/v$new_version"
echo "  Cask:     brew upgrade --cask parakey   (after tap pulls)"
echo
