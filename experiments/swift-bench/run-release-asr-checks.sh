#!/usr/bin/env bash
# Release-oriented ASR quality checks.
#
# This intentionally lives outside ship-swift.sh: private real-dictation
# fixtures are local maintainer data, not a release-script dependency.

set -euo pipefail

SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$SCRIPT_PATH")"

REAL_AUDIO_DIR="real-audio"
PUBLIC_AUDIO_DIR="public-audio/librispeech-dev-clean"
TRIALS="3"
REQUIRE_REAL_AUDIO=0
REQUIRE_PUBLIC_AUDIO=0
INCLUDE_CANDIDATE_MODELS=0
RUN_TAIL=1
SELF_TEST=0

usage() {
    cat <<'USAGE'
usage: ./run-release-asr-checks.sh [options]

Options:
  --real-audio-dir <path>   private real-dictation fixtures (default: real-audio)
  --public-audio-dir <path> public speech fixtures (default: public-audio/librispeech-dev-clean)
  --trials <n>              trials per clip/backend (default: 3)
  --require-real-audio      fail if no private real-dictation clips are present
  --require-public-audio    fail if no public speech clips are present
  --include-candidate-models
                            also run Unified candidate tail/comparison checks
  --skip-tail               with --include-candidate-models, skip the synthetic tail-word gate
  --self-test               run wrapper parser/detection tests only
  -h, --help                show this help

The default run performs:
  1. helper parser/self-tests,
  2. production v3 regression if private real-dictation fixtures exist,
  3. production v3 regression if public speech fixtures exist.

Unified is not a shipped app model. Use --include-candidate-models only
when evaluating whether a future model is good enough to expose.
USAGE
}

need_value() {
    if [[ $# -lt 2 || -z "$2" || "$2" == --* ]]; then
        echo "$1 requires a value" >&2
        usage >&2
        exit 2
    fi
}

supported_audio_count() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        printf '0'
        return
    fi
    find "$dir" -type f \
        \( -iname '*.wav' -o -iname '*.aiff' -o -iname '*.aif' -o -iname '*.caf' -o -iname '*.m4a' -o -iname '*.mp3' -o -iname '*.flac' \) \
        | wc -l | tr -d '[:space:]'
}

assert_eq() {
    local actual="$1"
    local expected="$2"
    local label="$3"
    if [[ "$actual" != "$expected" ]]; then
        echo "self-test failed for $label: expected '$expected', got '$actual'" >&2
        exit 1
    fi
}

assert_contains() {
    local file="$1"
    local needle="$2"
    if ! grep -Fq -- "$needle" "$file"; then
        echo "self-test expected output to contain: $needle" >&2
        exit 1
    fi
}

run_self_test() {
    local tmpdir
    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/parakey-release-asr-self-test.XXXXXX")"
    trap 'rm -rf "$tmpdir"' EXIT INT TERM

    mkdir -p "$tmpdir/fixtures/nested"
    touch "$tmpdir/fixtures/one.wav"
    touch "$tmpdir/fixtures/two.m4a"
    touch "$tmpdir/fixtures/two-and-a-half.flac"
    touch "$tmpdir/fixtures/ignore.txt"
    touch "$tmpdir/fixtures/nested/three.caf"

    assert_eq "$(supported_audio_count "$tmpdir/fixtures")" "4" "supported audio detection"
    assert_eq "$(supported_audio_count "$tmpdir/missing")" "0" "missing audio directory detection"

    local missing_value_log="$tmpdir/missing-value.log"
    if bash "$SCRIPT_PATH" --trials >"$missing_value_log" 2>&1; then
        echo "self-test expected --trials without a value to fail" >&2
        exit 1
    fi
    assert_contains "$missing_value_log" "--trials requires a value"

    rm -rf "$tmpdir"
    trap - EXIT INT TERM
    echo "release ASR checks self-test passed"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --real-audio-dir)
            need_value "$@"
            REAL_AUDIO_DIR="$2"
            shift 2
            ;;
        --public-audio-dir)
            need_value "$@"
            PUBLIC_AUDIO_DIR="$2"
            shift 2
            ;;
        --trials)
            need_value "$@"
            TRIALS="$2"
            shift 2
            ;;
        --require-real-audio)
            REQUIRE_REAL_AUDIO=1
            shift
            ;;
        --require-public-audio)
            REQUIRE_PUBLIC_AUDIO=1
            shift
            ;;
        --include-candidate-models)
            INCLUDE_CANDIDATE_MODELS=1
            shift
            ;;
        --skip-tail)
            RUN_TAIL=0
            shift
            ;;
        --self-test)
            SELF_TEST=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ "$SELF_TEST" -eq 1 ]]; then
    run_self_test
    exit 0
fi

if ! [[ "$TRIALS" =~ ^[0-9]+$ ]] || [[ "$TRIALS" -lt 1 ]]; then
    echo "--trials must be a positive integer" >&2
    exit 2
fi

echo "running helper self-tests..."
./run-tail-word-regression.sh --self-test
./add-real-dictation-fixture.sh --self-test
./fetch-public-speech-fixtures.sh --self-test
./run-real-dictation-regression.sh --self-test
./run-real-model-comparison.sh --self-test
./run-public-model-comparison.sh --self-test
./bench-power.sh --self-test

if [[ "$INCLUDE_CANDIDATE_MODELS" -eq 1 ]]; then
    if [[ "$RUN_TAIL" -eq 1 ]]; then
        echo
        echo "running candidate synthetic tail-word ASR gate..."
        ./run-tail-word-regression.sh
    else
        echo
        echo "skipping candidate synthetic tail-word ASR gate (--skip-tail)"
    fi
fi

real_count="$(supported_audio_count "$REAL_AUDIO_DIR")"
if [[ "$real_count" -eq 0 ]]; then
    if [[ "$REQUIRE_REAL_AUDIO" -eq 1 ]]; then
        echo "no private real-dictation clips found in $REAL_AUDIO_DIR" >&2
        exit 1
    fi
    echo
    echo "no private real-dictation clips found in $REAL_AUDIO_DIR; skipped real-audio WER gates"
else
    echo
    echo "running private production v3 ASR regression on $real_count clip(s)..."
    ./run-real-dictation-regression.sh --input-dir "$REAL_AUDIO_DIR" --backend v3 --trials "$TRIALS"
    if [[ "$INCLUDE_CANDIDATE_MODELS" -eq 1 ]]; then
        echo
        echo "running private v3-vs-Unified candidate comparison on $real_count clip(s)..."
        ./run-real-model-comparison.sh --input-dir "$REAL_AUDIO_DIR" --trials "$TRIALS" --unified-trailing-silence-ms 250
    fi
fi

public_count="$(supported_audio_count "$PUBLIC_AUDIO_DIR")"
if [[ "$public_count" -eq 0 ]]; then
    if [[ "$REQUIRE_PUBLIC_AUDIO" -eq 1 ]]; then
        echo "no public speech clips found in $PUBLIC_AUDIO_DIR" >&2
        exit 1
    fi
    echo
    echo "no public speech clips found in $PUBLIC_AUDIO_DIR; skipped public WER gates"
    echo
    echo "release ASR checks passed"
    exit 0
fi

echo
echo "running public production v3 ASR regression on $public_count clip(s)..."
./run-real-dictation-regression.sh \
    --input-dir "$PUBLIC_AUDIO_DIR" \
    --out-dir public-results \
    --backend v3 \
    --trials "$TRIALS" \
    --public-corpus \
    --show-transcripts \
    --show-paths

if [[ "$INCLUDE_CANDIDATE_MODELS" -eq 1 ]]; then
    echo
    echo "running public v3-vs-Unified candidate comparison on $public_count clip(s)..."
    ./run-public-model-comparison.sh --fixture-dir "$PUBLIC_AUDIO_DIR" --trials "$TRIALS" --unified-trailing-silence-ms 250
fi

echo
echo "release ASR checks passed"
