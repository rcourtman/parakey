#!/usr/bin/env bash
# ship-swift.sh — full release pipeline for native Swift Parakey.
#
# Designed for unattended agent operation: there's nothing to remember
# between invocations. Reads the current version out of
# swift/Info.plist, bumps it, builds a release-optimised binary, wraps
# it in a signed + notarised .app, tags the commit, creates the
# GitHub release, and updates + verifies the sibling Homebrew Cask in
# one shot.
#
#   ./ship-swift.sh                 # default: bump patch (0.2.0 -> 0.2.1)
#   ./ship-swift.sh --minor         # 0.2.x -> 0.3.0
#   ./ship-swift.sh --major         # 0.x.x -> 1.0.0
#   ./ship-swift.sh --version 0.2.5 # explicit
#   ./ship-swift.sh --dry-run       # build everything, skip git/tag/release/cask
#   ./ship-swift.sh --no-cask       # ship binary + GitHub release, skip Cask bump
#   ./ship-swift.sh --skip-qa       # emergencies only: skip self-tests, smoke test, CI-green gate
#   ./ship-swift.sh --cask-only 0.2.5 # resume: redo only the Cask stage for a published release
#   ./ship-swift.sh --self-test     # exercise release helper checks, no build/release
#
# Pre-flight requires:
#   - clean working tree on `main`
#   - notary credentials stored (keychain profile "parakey-notary")
#   - gh CLI authenticated for github.com
#   - brew CLI installed for post-release Cask verification
#   - sibling Homebrew tap at ../homebrew-parakey (override with
#     PARAKEY_HOMEBREW_TAP=/path/to/tap)
#
# Recovery: if anything after the build fails, swift/Info.plist and
# synced docs metadata may be locally mutated. Reset with `git checkout
# swift/Info.plist README.md docs/` and try again. Built artefacts in
# swift/dist/ are safe to delete. If the GitHub release published but
# the Cask stage failed, resume with `./ship-swift.sh --cask-only
# <version>` instead of re-running the full flow.

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
CASK_TOKEN="rcourtman/parakey/parakey"
# Directory-level superset of SYNCED_PATHS in scripts/sync-docs.py
# (every synced file lives at README.md or under docs/). Deliberately
# coarse: a path added to SYNCED_PATHS alone is still committed and
# rolled back here without this list needing a matching edit. Pre-flight
# rejects untracked files under these paths so `git add docs` cannot
# sweep strays into the release commit.
DOC_SYNC_PATHS=(
    README.md
    docs
)
NO_ATTRIBUTION_CHECKER="${NO_ATTRIBUTION_CHECKER:-/Users/rcourtman/.codex/skills/github-no-attribution/scripts/check_no_attribution.py}"
ROLLBACK_RELEASE_MUTATIONS=0

# ---- 0. CLI ---------------------------------------------------------------
BUMP=patch
TARGET=""
DRY_RUN=0
NO_CASK=0
SELF_TEST=0
SKIP_QA=0
CASK_ONLY=0
CASK_ONLY_VERSION=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --patch)   BUMP=patch; shift ;;
        --minor)   BUMP=minor; shift ;;
        --major)   BUMP=major; shift ;;
        --version) TARGET="$2"; BUMP=explicit; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --no-cask) NO_CASK=1; shift ;;
        --skip-qa) SKIP_QA=1; shift ;;
        --cask-only)
            [[ $# -ge 2 ]] || { echo "--cask-only needs a version argument (X.Y.Z)" >&2; exit 1; }
            CASK_ONLY=1; CASK_ONLY_VERSION="$2"; shift 2 ;;
        --self-test) SELF_TEST=1; shift ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's|^# \{0,1\}||'
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

if [[ "$CASK_ONLY" -eq 1 && ( "$DRY_RUN" -eq 1 || "$NO_CASK" -eq 1 ) ]]; then
    echo "--cask-only cannot be combined with --dry-run or --no-cask" >&2
    exit 1
fi

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

rollback_release_mutations_on_exit() {
    local status=$?
    if [[ "$status" -ne 0 && "$ROLLBACK_RELEASE_MUTATIONS" -eq 1 ]]; then
        warn "Release failed before commit completed; reverting Info.plist and synced docs."
        git -C "$PROJECT_DIR" checkout -- "$INFO_PLIST" "${DOC_SYNC_PATHS[@]}" >/dev/null 2>&1 || true
        rm -rf "$APP"
    fi
}
trap rollback_release_mutations_on_exit EXIT

check_no_attribution_file() {
    local label="$1"
    local path="$2"
    if [[ -f "$NO_ATTRIBUTION_CHECKER" ]]; then
        /usr/bin/python3 "$NO_ATTRIBUTION_CHECKER" --label "$label" "$path"
    else
        /usr/bin/python3 - "$label" "$path" <<'PY'
import pathlib
import re
import sys

label, path = sys.argv[1], pathlib.Path(sys.argv[2])
text = path.read_text(encoding="utf-8")
patterns = [
    r"\b" + "chat" + r"\s*" + "gpt" + r"\b|\b" + "chat" + "gpt" + r"\b",
    r"\b" + "open" + "ai" + r"\b",
    r"\b" + "co" + "dex" + r"\b|\[" + "co" + "dex" + r"\]|" + "co" + "dex" + r"/",
    r"\b" + "ai" + r"[- ]" + "generated" + r"\b",
    r"\b" + "ai" + r"[- ]" + "assisted" + r"\b",
    r"\b" + "generated" + r"\s+" + "by" + r"\b",
    r"\b" + "generated" + r"\s+" + "with" + r"\b",
    r"\b" + "written" + r"\s+" + "by" + r"\b",
    r"\b" + "authored" + r"\s+" + "by" + r"\b",
    r"\b" + "created" + r"\s+" + "with" + r"\b",
    r"\b" + "powered" + r"\s+" + "by" + r"\b",
    r"^\s*" + "co" + r"-" + "authored" + r"-" + "by" + r"\s*:",
]
for pattern in patterns:
    if re.search(pattern, text, re.I | re.M):
        raise SystemExit(f"no-attribution preflight failed for {label}: {path}")
PY
    fi
}

check_no_attribution_text() {
    local label="$1"
    local text="$2"
    if [[ -f "$NO_ATTRIBUTION_CHECKER" ]]; then
        printf '%s\n' "$text" | /usr/bin/python3 "$NO_ATTRIBUTION_CHECKER" --label "$label"
    else
        /usr/bin/python3 - "$label" "$text" <<'PY'
import re
import sys

label, text = sys.argv[1], sys.argv[2]
patterns = [
    r"\b" + "chat" + r"\s*" + "gpt" + r"\b|\b" + "chat" + "gpt" + r"\b",
    r"\b" + "open" + "ai" + r"\b",
    r"\b" + "co" + "dex" + r"\b|\[" + "co" + "dex" + r"\]|" + "co" + "dex" + r"/",
    r"\b" + "ai" + r"[- ]" + "generated" + r"\b",
    r"\b" + "ai" + r"[- ]" + "assisted" + r"\b",
    r"\b" + "generated" + r"\s+" + "by" + r"\b",
    r"\b" + "generated" + r"\s+" + "with" + r"\b",
    r"\b" + "written" + r"\s+" + "by" + r"\b",
    r"\b" + "authored" + r"\s+" + "by" + r"\b",
    r"\b" + "created" + r"\s+" + "with" + r"\b",
    r"\b" + "powered" + r"\s+" + "by" + r"\b",
    r"^\s*" + "co" + r"-" + "authored" + r"-" + "by" + r"\s*:",
]
for pattern in patterns:
    if re.search(pattern, text, re.I | re.M):
        raise SystemExit(f"no-attribution preflight failed for {label}")
PY
    fi
}

is_release_version() {
    [[ "$1" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
}

is_build_number() {
    [[ "$1" =~ ^(0|[1-9][0-9]*)$ ]]
}

is_sha256() {
    [[ "$1" =~ ^[0-9a-f]{64}$ ]]
}

compute_target_version() {
    local current="$1"
    local bump="$2"
    local explicit_target="${3:-}"
    local major minor patch

    case "$bump" in
        explicit)
            is_release_version "$explicit_target" \
                || die "--version needs X.Y.Z without leading zeroes, got '$explicit_target'"
            printf '%s\n' "$explicit_target"
            ;;
        patch|minor|major)
            is_release_version "$current" \
                || die "current version must be X.Y.Z without leading zeroes, got '$current'"
            IFS=. read -r major minor patch <<<"$current"
            case "$bump" in
                patch) printf '%s.%s.%s\n' "$major" "$minor" "$((patch + 1))" ;;
                minor) printf '%s.%s.0\n' "$major" "$((minor + 1))" ;;
                major) printf '%s.0.0\n' "$((major + 1))" ;;
            esac
            ;;
        *)
            die "unknown version bump: $bump"
            ;;
    esac
}

increment_build_number() {
    local current_build="$1"
    is_build_number "$current_build" \
        || die "CFBundleVersion must be a non-negative integer without leading zeroes, got '$current_build'"
    printf '%s\n' "$((current_build + 1))"
}

rewrite_cask_file() {
    local cask_file="$1"
    local new_version="$2"
    local new_sha="$3"

    [[ -f "$cask_file" ]] || die "cask not found at $cask_file"
    is_release_version "$new_version" || die "invalid cask version: $new_version"
    is_sha256 "$new_sha" || die "invalid cask sha256: $new_sha"

    /usr/bin/python3 - "$cask_file" "$new_version" "$new_sha" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
new_version = sys.argv[2]
new_sha = sys.argv[3]
src = path.read_text()

src, version_count = re.subn(
    r'^(\s*version\s+")[^"]+("\s*)$',
    rf'\g<1>{new_version}\g<2>',
    src,
    count=0,
    flags=re.M,
)
src, sha_count = re.subn(
    r'^(\s*sha256\s+")[0-9a-f]{64}("\s*)$',
    rf'\g<1>{new_sha}\g<2>',
    src,
    count=0,
    flags=re.M,
)

if version_count != 1:
    raise SystemExit(f"expected exactly one cask version line, found {version_count}")
if sha_count != 1:
    raise SystemExit(f"expected exactly one cask sha256 line, found {sha_count}")

path.write_text(src)
PY
}

# Takes GitHub check-runs JSON (the commits/<sha>/check-runs payload) as
# $1 and prints exactly one of: success | failing | pending | missing.
check_runs_overall_state() {
    /usr/bin/python3 - "$1" <<'PY'
import json
import sys

runs = json.loads(sys.argv[1]).get("check_runs", [])
if not runs:
    print("missing")
elif any(run.get("status") != "completed" for run in runs):
    print("pending")
elif any(run.get("conclusion") not in ("success", "neutral", "skipped") for run in runs):
    print("failing")
else:
    print("success")
PY
}

# Shared by the full release flow and --cask-only. Sets $tap_branch.
cask_preflight() {
    command -v brew >/dev/null || die "'brew' CLI not installed (needed to verify the published Cask)"
    [[ -f "$CASK_FILE" ]] || die "cask not found at $CASK_FILE — set PARAKEY_HOMEBREW_TAP or use --no-cask"
    tap_branch="$(git -C "$CASK_TAP" rev-parse --abbrev-ref HEAD)"
    git -C "$CASK_TAP" update-index --refresh >/dev/null 2>&1 || true
    if ! git -C "$CASK_TAP" diff-index --quiet HEAD --; then
        die "Homebrew tap has uncommitted changes at $CASK_TAP
   A previous cask stage may have died mid-rewrite. Inspect the tap, then
   discard the half-applied rewrite (git -C \"$CASK_TAP\" checkout -- .)
   before re-running ./ship-swift.sh --cask-only <version>."
    fi
}

# Cask update + verification against an already-published GitHub release.
# Used by the tail of the full release flow and by --cask-only resume.
# Requires cask_preflight to have set $tap_branch.
run_cask_stage() {
    local version="$1"
    local zip_sha="$2"
    local resume_hint="fix the issue, then resume with: ./ship-swift.sh --cask-only $version"

    say "Updating Homebrew Cask at $CASK_FILE"
    rewrite_cask_file "$CASK_FILE" "$version" "$zip_sha"
    grep -q "version \"$version\"" "$CASK_FILE" || die "cask rewrite failed (version) -- $resume_hint"
    grep -q "sha256 \"$zip_sha\""  "$CASK_FILE" || die "cask rewrite failed (sha256) -- $resume_hint"

    git -C "$CASK_TAP" add Casks/parakey.rb
    local cask_commit_message="parakey $version"
    check_no_attribution_text "cask commit message" "$cask_commit_message"
    if git -C "$CASK_TAP" diff --cached --quiet; then
        # Resume case: a previous run already committed this rewrite.
        say "Cask file already at v$version; nothing new to commit"
    else
        git -C "$CASK_TAP" commit -m "$cask_commit_message" \
            || die "tap commit failed -- $resume_hint"
    fi
    git -C "$CASK_TAP" push origin "$tap_branch" \
        || die "tap push failed -- $resume_hint"

    say "Verifying published Homebrew Cask"
    local remote_tap_head local_tap_head
    remote_tap_head="$(git -C "$CASK_TAP" ls-remote origin "refs/heads/$tap_branch" | awk '{print $1}')"
    local_tap_head="$(git -C "$CASK_TAP" rev-parse HEAD)"
    [[ "$remote_tap_head" == "$local_tap_head" ]] \
        || die "tap push did not publish HEAD ($local_tap_head) -- $resume_hint"

    brew tap rcourtman/parakey >/dev/null || die "brew tap rcourtman/parakey failed -- $resume_hint"
    brew update >/dev/null || die "brew update failed after Cask push -- $resume_hint"

    local published_version
    published_version="$(brew info --cask "$CASK_TOKEN" 2>/dev/null | awk 'NR == 1 { print $NF; exit }')"
    [[ "$published_version" == "$version" ]] \
        || die "Homebrew sees $CASK_TOKEN as '$published_version', expected '$version' -- $resume_hint"

    brew fetch --cask --force "$CASK_TOKEN" \
        || die "brew fetch failed for $CASK_TOKEN v$version -- $resume_hint"
    say "Homebrew Cask OK ($CASK_TOKEN v$version)"
}

assert_self_test_equals() {
    local actual="$1"
    local expected="$2"
    local message="$3"
    [[ "$actual" == "$expected" ]] || die "$message: got '$actual', expected '$expected'"
}

assert_self_test_fails() {
    local message="$1"
    shift
    if ( "$@" ) >/dev/null 2>&1; then
        die "$message"
    fi
}

run_release_script_self_test() {
    say "Release script self-test"

    check_no_attribution_text "self-test clean release message" "Release v9.8.7"

    local banned_sample
    banned_sample="$(printf '%s%s %s %s%s' "Gen" "erated" "by" "Chat" "GPT")"
    if check_no_attribution_text "self-test banned release message" "$banned_sample" >/dev/null 2>&1; then
        die "no-attribution checker accepted banned release text"
    fi

    local tmpdir
    tmpdir="$(mktemp -d)"
    local notes_file="$tmpdir/notes.md"
    printf '%s\n' "Plain release notes" >"$notes_file"
    check_no_attribution_file "self-test release notes" "$notes_file"

    check_no_attribution_text "self-test generated notes" "$(printf -- '- Release v9.8.7\n- Improve update checks')"

    assert_self_test_equals "$(compute_target_version "1.2.3" patch)" "1.2.4" \
        "patch version bump failed"
    assert_self_test_equals "$(compute_target_version "1.2.3" minor)" "1.3.0" \
        "minor version bump failed"
    assert_self_test_equals "$(compute_target_version "1.2.3" major)" "2.0.0" \
        "major version bump failed"
    assert_self_test_equals "$(compute_target_version "1.2.3" explicit "4.5.6")" "4.5.6" \
        "explicit version selection failed"
    assert_self_test_equals "$(increment_build_number "42")" "43" \
        "build number increment failed"
    assert_self_test_fails "accepted malformed current version" \
        compute_target_version "1.02.3" patch
    assert_self_test_fails "accepted malformed explicit version" \
        compute_target_version "1.2.3" explicit "1.2"
    assert_self_test_fails "accepted malformed build number" \
        increment_build_number "04"

    assert_self_test_equals \
        "$(check_runs_overall_state '{"check_runs": []}')" \
        "missing" "empty check-run list should report missing"
    assert_self_test_equals \
        "$(check_runs_overall_state '{"check_runs": [{"status": "completed", "conclusion": "success"}, {"status": "completed", "conclusion": "skipped"}]}')" \
        "success" "green check runs should report success"
    assert_self_test_equals \
        "$(check_runs_overall_state '{"check_runs": [{"status": "completed", "conclusion": "success"}, {"status": "in_progress", "conclusion": null}]}')" \
        "pending" "in-progress check run should report pending"
    assert_self_test_equals \
        "$(check_runs_overall_state '{"check_runs": [{"status": "completed", "conclusion": "failure"}]}')" \
        "failing" "failed check run should report failing"

    local cask_file
    cask_file="$tmpdir/parakey.rb"
    local old_sha new_sha
    old_sha="$(printf 'a%.0s' {1..64})"
    new_sha="$(printf 'b%.0s' {1..64})"
    cat >"$cask_file" <<EOF
cask "parakey" do
  version "1.2.3"
  sha256 "$old_sha"
end
EOF
    rewrite_cask_file "$cask_file" "4.5.6" "$new_sha"
    grep -qx '  version "4.5.6"' "$cask_file" \
        || die "self-test cask rewrite missed version"
    grep -qx "  sha256 \"$new_sha\"" "$cask_file" \
        || die "self-test cask rewrite missed sha256"

    cat >"$cask_file" <<EOF
cask "parakey" do
  version "1.2.3"
  version "1.2.4"
  sha256 "$old_sha"
end
EOF
    assert_self_test_fails "accepted duplicate cask version lines" \
        rewrite_cask_file "$cask_file" "4.5.6" "$new_sha"
    assert_self_test_fails "accepted malformed cask sha256" \
        rewrite_cask_file "$cask_file" "4.5.6" "not-a-sha"

    rm -rf "$tmpdir"
    say "Release script self-test passed"
}

if [[ "$SELF_TEST" -eq 1 ]]; then
    run_release_script_self_test
    exit 0
fi

# ---- 0.5 Cask-only resume ---------------------------------------------------
# Recovers a half-released state: the GitHub release published but the
# Cask stage failed. Validates the release + asset exist, recomputes the
# zip sha256 from the published asset, then re-runs only the Cask stage.
if [[ "$CASK_ONLY" -eq 1 ]]; then
    is_release_version "$CASK_ONLY_VERSION" \
        || die "--cask-only needs X.Y.Z without leading zeroes, got '$CASK_ONLY_VERSION'"
    command -v gh >/dev/null || die "'gh' CLI not installed (brew install gh)"
    gh auth status >/dev/null 2>&1 || die "'gh' is not authenticated (gh auth login)"
    cask_preflight

    say "Validating published release v$CASK_ONLY_VERSION"
    release_assets="$(gh release view "v$CASK_ONLY_VERSION" --repo rcourtman/parakey \
        --json assets --jq '.assets[].name')" \
        || die "release v$CASK_ONLY_VERSION not found on GitHub -- --cask-only resumes an already-published release"
    grep -qx 'Parakey.zip' <<<"$release_assets" \
        || die "release v$CASK_ONLY_VERSION has no Parakey.zip asset -- upload it (gh release upload) before resuming the Cask"

    say "Downloading published Parakey.zip to compute sha256"
    cask_only_tmp="$(mktemp -d)"
    gh release download "v$CASK_ONLY_VERSION" --repo rcourtman/parakey \
        --pattern Parakey.zip --dir "$cask_only_tmp" \
        || die "could not download Parakey.zip from release v$CASK_ONLY_VERSION"
    cask_only_sha="$(shasum -a 256 "$cask_only_tmp/Parakey.zip" | awk '{print $1}')"
    rm -rf "$cask_only_tmp"

    run_cask_stage "$CASK_ONLY_VERSION" "$cask_only_sha"
    say "Cask resume complete for v$CASK_ONLY_VERSION"
    echo
    echo "  Cask:     brew update && brew upgrade --cask $CASK_TOKEN"
    echo
    exit 0
fi

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

# The release `git add` below is directory-level (README.md, docs/), so
# refuse untracked strays there that would get swept into the commit.
untracked_synced="$(git -C "$PROJECT_DIR" ls-files --others --exclude-standard -- "${DOC_SYNC_PATHS[@]}")"
[[ -z "$untracked_synced" ]] \
    || die "untracked files under synced-docs paths would be committed by the release: $untracked_synced"

head_sha="$(git -C "$PROJECT_DIR" rev-parse HEAD)"

if [[ "$DRY_RUN" -eq 0 ]]; then
    command -v gh >/dev/null || die "'gh' CLI not installed (brew install gh)"
    gh auth status >/dev/null 2>&1 || die "'gh' is not authenticated (gh auth login)"

    say "Fetching origin to verify branch + tag state"
    git -C "$PROJECT_DIR" fetch origin || die "git fetch origin failed"
    remote_main="$(git -C "$PROJECT_DIR" rev-parse origin/main)"
    if [[ "$head_sha" != "$remote_main" ]]; then
        die "local main ($head_sha) != origin/main ($remote_main) -- push (or pull/rebase) so they match before shipping"
    fi
fi

if [[ "$NO_CASK" -eq 0 && "$DRY_RUN" -eq 0 ]]; then
    cask_preflight
fi

# ---- 2. Compute target version --------------------------------------------
current_version="$(plutil -extract CFBundleShortVersionString raw "$INFO_PLIST")"
current_build="$(plutil -extract CFBundleVersion raw "$INFO_PLIST")"
[[ -n "$current_version" ]] || die "could not read CFBundleShortVersionString from $INFO_PLIST"
[[ -n "$current_build"   ]] || die "could not read CFBundleVersion from $INFO_PLIST"

new_version="$(compute_target_version "$current_version" "$BUMP" "$TARGET")"
new_build="$(increment_build_number "$current_build")"

say "Version: $current_version (build $current_build) -> $new_version (build $new_build)"

if git -C "$PROJECT_DIR" rev-parse -q --verify "refs/tags/v$new_version" >/dev/null; then
    die "tag v$new_version already exists locally -- pick a different version (or delete the stale local tag first)"
fi
if [[ "$DRY_RUN" -eq 0 ]]; then
    remote_tag_ref="$(git -C "$PROJECT_DIR" ls-remote --tags origin "refs/tags/v$new_version")" \
        || die "git ls-remote failed while checking origin for tag v$new_version"
    [[ -z "$remote_tag_ref" ]] \
        || die "tag v$new_version already exists on origin -- pick a different version"
fi

# ---- 2.5 QA gates -----------------------------------------------------------
# Cheap-to-medium checks before the expensive notarisation round-trip:
# CI must be green for HEAD, the debug self-test suite must pass (same
# invocation as .github/workflows/check.yml), and the packaging contract
# must hold (scripts/smoke-packaged-app.sh builds + checks its own
# throwaway debug bundle, so it needs no input from this script).
if [[ "$SKIP_QA" -eq 1 ]]; then
    warn "Skipping QA gates (--skip-qa): CI status, self-test suite, packaged smoke test"
else
    if [[ "$DRY_RUN" -eq 0 ]]; then
        say "Checking CI status for HEAD ($head_sha)"
        ci_json="$(gh api "repos/rcourtman/parakey/commits/$head_sha/check-runs?per_page=100")" \
            || die "could not query CI check-runs for $head_sha"
        ci_state="$(check_runs_overall_state "$ci_json")"
        case "$ci_state" in
            success) say "CI is green for HEAD" ;;
            missing) die "no CI check-runs found for HEAD ($head_sha) -- wait for CI to start/finish, or --skip-qa in an emergency" ;;
            pending) die "CI is still running for HEAD ($head_sha) -- wait for green, or --skip-qa in an emergency" ;;
            failing) die "CI is red for HEAD ($head_sha) -- fix CI before shipping, or --skip-qa in an emergency" ;;
            *)       die "unexpected CI state '$ci_state' for HEAD ($head_sha)" ;;
        esac
    fi

    say "Running debug self-test suite (same as CI)"
    ( cd "$SWIFT_DIR" && swift run -c debug Parakey --self-test all ) \
        || die "swift self-test suite failed -- fix before shipping, or --skip-qa in an emergency"

    say "Running packaged-app smoke test"
    "$PROJECT_DIR/scripts/smoke-packaged-app.sh" \
        || die "packaged-app smoke test failed -- fix before shipping, or --skip-qa in an emergency"
fi

# ---- 3. Build release-optimised binary ------------------------------------
say "Building (release)"
( cd "$SWIFT_DIR" && swift build -c release 2>&1 | tail -5 ) \
    || die "swift build failed"

BIN="$SWIFT_DIR/.build/release/Parakey"
[[ -f "$BIN" ]] || die "release build produced no $BIN"

# ---- 4. Bump Info.plist (before wrapping, so the .app carries new version)
say "Updating Info.plist version + build numbers"
ROLLBACK_RELEASE_MUTATIONS=1
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
# Hard requirement: scripts/smoke-packaged-app.sh fails CI on a missing
# icon, so the release packaging must hold the same contract.
[[ -f "$PROJECT_DIR/icon/Parakey.icns" ]] \
    || die "icon/Parakey.icns missing -- the packaged app must ship with an icon"
cp "$PROJECT_DIR/icon/Parakey.icns" "$APP/Contents/Resources/Parakey.icns"

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
    # The two microphone keys (Tahoe Hardened Runtime + sandbox
    # legacy). The full justification + ban-list for everything else
    # lives in ../AGENTS.md — if you're tempted to add JIT,
    # unsigned-exec, or disable-library-validation here, read that
    # section first.
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

say "Syncing release docs metadata"
/usr/bin/python3 "$PROJECT_DIR/scripts/sync-docs.py" --release-zip "$ZIP_OUT" \
    || die "docs metadata sync failed"

# Tidy up the unzipped .app so Spotlight / Launch Services don't
# accidentally favour it over /Applications/Parakey.app.
rm -rf "$APP"

if [[ "$DRY_RUN" -eq 1 ]]; then
    say "Dry run -- stopping before git/tag/release/cask. Reverting Info.plist and synced docs."
    git -C "$PROJECT_DIR" checkout -- "$INFO_PLIST" "${DOC_SYNC_PATHS[@]}"
    say "Done (dry run)."
    exit 0
fi

# ---- 9. Commit, tag, push -------------------------------------------------
say "Committing version bump"
release_commit_message="Release v$new_version"
release_title="v$new_version"
NOTES_FILE="$SWIFT_DIR/release-notes/v$new_version.md"
USE_NOTES_FILE=0
notes=""

check_no_attribution_text "release commit message" "$release_commit_message"
check_no_attribution_text "release title" "$release_title"

# If a hand-written release-notes file exists for this version, use it
# verbatim — preferable to a list of commit subjects for releases with
# any narrative content (migration steps, breaking changes, etc.).
# Otherwise fall back to the exact generated commit-list the GitHub
# release step will publish. Preflight before pushing the tag so a
# release-note wording issue does not leave remote state half-published.
if [[ -f "$NOTES_FILE" ]]; then
    USE_NOTES_FILE=1
    check_no_attribution_file "release notes" "$NOTES_FILE"
else
    prev_tag="$(git -C "$PROJECT_DIR" describe --tags --abbrev=0 2>/dev/null || true)"
    if [[ -n "$prev_tag" ]]; then
        prior_notes="$(git -C "$PROJECT_DIR" log --pretty='- %s' "$prev_tag..HEAD")"
        notes="$(printf -- '- %s\n%s' "$release_commit_message" "$prior_notes")"
    else
        notes="Initial Swift release."
    fi
    check_no_attribution_text "generated release notes" "$notes"
fi

git -C "$PROJECT_DIR" add "$INFO_PLIST" "${DOC_SYNC_PATHS[@]}"
git -C "$PROJECT_DIR" commit -m "$release_commit_message"
ROLLBACK_RELEASE_MUTATIONS=0
# Annotated, not lightweight: `git push --follow-tags` only pushes
# annotated tags, and we push the tag ref explicitly anyway so the
# remote tag exists before `gh release create` references it.
git -C "$PROJECT_DIR" tag -a "v$new_version" -m "$release_commit_message"

say "Pushing main + tag"
git -C "$PROJECT_DIR" push origin main "refs/tags/v$new_version"

# ---- 10. GitHub release ---------------------------------------------------
say "Creating GitHub release v$new_version"

# At this point main and the tag are already on origin; only the GitHub
# release itself is missing. `gh release create` on an existing pushed
# tag attaches to that tag, so re-running it manually is safe.
release_failure_msg="gh release create failed -- commit and tag v$new_version ARE pushed to origin; no GitHub release exists yet. Re-run: gh release create v$new_version $ZIP_OUT --repo rcourtman/parakey --title $release_title --notes ... (it will reuse the pushed tag), then finish with ./ship-swift.sh --cask-only $new_version"

if [[ "$USE_NOTES_FILE" -eq 1 ]]; then
    say "Using hand-written release notes from $NOTES_FILE"
    gh release create "v$new_version" "$ZIP_OUT" \
        --repo rcourtman/parakey \
        --title "$release_title" \
        --notes-file "$NOTES_FILE" \
        || die "$release_failure_msg"
else
    gh release create "v$new_version" "$ZIP_OUT" \
        --repo rcourtman/parakey \
        --title "$release_title" \
        --notes "$notes" \
        || die "$release_failure_msg"
fi

# ---- 11. Homebrew Cask bump -----------------------------------------------
if [[ "$NO_CASK" -eq 1 ]]; then
    say "Skipping Cask bump (--no-cask)"
else
    run_cask_stage "$new_version" "$ZIP_SHA"
fi

# ---- 12. Done -------------------------------------------------------------
say "Shipped v$new_version"
echo
echo "  GitHub:   https://github.com/rcourtman/parakey/releases/tag/v$new_version"
echo "  Cask:     brew update && brew upgrade --cask $CASK_TOKEN"
echo
