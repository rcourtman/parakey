#!/usr/bin/env bash
# Add an existing local recording to the private real-dictation corpus.

set -euo pipefail

SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$SCRIPT_PATH")"

INPUT_DIR="real-audio"
CLIP_ID=""
AUDIO_PATH=""
REFERENCE_TEXT=""
REFERENCE_FILE=""
SELF_TEST=0

usage() {
    cat <<'USAGE'
usage: ./add-real-dictation-fixture.sh --id <clip-id> --audio <path> (--reference "text" | --reference-file <path>) [options]

Options:
  --input-dir <path>       destination fixture directory (default: real-audio)
  --id <clip-id>           safe filename stem: letters, numbers, dot, underscore, dash
  --audio <path>           existing local recording to copy
  --reference <text>       reference transcript text
  --reference-file <path>  file containing reference transcript text
  --self-test              run parser and safety self-tests
  -h, --help               show this help

Supported audio extensions: wav, aiff, aif, caf, m4a, mp3, flac.
The destination audio and .txt sidecar are ignored by git.
USAGE
}

need_value() {
    if [[ $# -lt 2 || -z "$2" || "$2" == --* ]]; then
        echo "$1 requires a value" >&2
        usage >&2
        exit 2
    fi
}

is_safe_clip_id() {
    [[ "$1" =~ ^[A-Za-z0-9_.-]+$ ]] && [[ "$1" != "." ]] && [[ "$1" != ".." ]]
}

is_supported_audio_extension() {
    local lower
    lower="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    case "$lower" in
        wav|aiff|aif|caf|m4a|mp3|flac) return 0 ;;
        *) return 1 ;;
    esac
}

assert_success() {
    local label="$1"
    shift
    if ! "$@"; then
        echo "self-test expected success: $label" >&2
        exit 1
    fi
}

assert_failure() {
    local label="$1"
    shift
    if "$@"; then
        echo "self-test expected failure: $label" >&2
        exit 1
    fi
}

assert_file_contains() {
    local file="$1"
    local needle="$2"
    if ! grep -Fq -- "$needle" "$file"; then
        echo "self-test expected $file to contain: $needle" >&2
        exit 1
    fi
}

run_self_test() {
    local tmpdir
    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/parakey-add-fixture-self-test.XXXXXX")"
    trap 'rm -rf "$tmpdir"' EXIT INT TERM

    assert_success "safe id" is_safe_clip_id "short-note_001"
    assert_failure "path separator id" is_safe_clip_id "../secret"
    assert_failure "empty id" is_safe_clip_id ""
    assert_success "wav extension" is_supported_audio_extension "wav"
    assert_success "M4A extension" is_supported_audio_extension "M4A"
    assert_success "FLAC extension" is_supported_audio_extension "FLAC"
    assert_failure "unsupported extension" is_supported_audio_extension "mov"

    local audio="$tmpdir/source.wav"
    local ref="$tmpdir/ref.txt"
    printf 'fake wav bytes\n' >"$audio"
    printf 'reference text\n' >"$ref"
    bash "$SCRIPT_PATH" \
        --input-dir "$tmpdir/fixtures" \
        --id "clip-001" \
        --audio "$audio" \
        --reference-file "$ref" >/dev/null

    [[ -f "$tmpdir/fixtures/clip-001.wav" ]] || {
        echo "self-test expected copied audio fixture" >&2
        exit 1
    }
    assert_file_contains "$tmpdir/fixtures/clip-001.txt" "reference text"

    local duplicate_log="$tmpdir/duplicate.log"
    if bash "$SCRIPT_PATH" \
        --input-dir "$tmpdir/fixtures" \
        --id "clip-001" \
        --audio "$audio" \
        --reference "duplicate" >"$duplicate_log" 2>&1; then
        echo "self-test expected duplicate fixture to fail" >&2
        exit 1
    fi
    assert_file_contains "$duplicate_log" "destination already exists"

    rm -rf "$tmpdir"
    trap - EXIT INT TERM
    echo "add real-dictation fixture self-test passed"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --input-dir)
            need_value "$@"
            INPUT_DIR="$2"
            shift 2
            ;;
        --id)
            need_value "$@"
            CLIP_ID="$2"
            shift 2
            ;;
        --audio)
            need_value "$@"
            AUDIO_PATH="$2"
            shift 2
            ;;
        --reference)
            need_value "$@"
            REFERENCE_TEXT="$2"
            shift 2
            ;;
        --reference-file)
            need_value "$@"
            REFERENCE_FILE="$2"
            shift 2
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

if ! is_safe_clip_id "$CLIP_ID"; then
    echo "--id must contain only letters, numbers, dot, underscore, and dash" >&2
    exit 2
fi

if [[ -z "$AUDIO_PATH" || ! -f "$AUDIO_PATH" ]]; then
    echo "--audio must point to an existing file" >&2
    exit 2
fi

if [[ -n "$REFERENCE_TEXT" && -n "$REFERENCE_FILE" ]]; then
    echo "pass only one of --reference or --reference-file" >&2
    exit 2
fi

if [[ -n "$REFERENCE_FILE" ]]; then
    if [[ ! -f "$REFERENCE_FILE" ]]; then
        echo "--reference-file must point to an existing file" >&2
        exit 2
    fi
    REFERENCE_TEXT="$(cat "$REFERENCE_FILE")"
fi

if [[ -z "${REFERENCE_TEXT//[[:space:]]/}" ]]; then
    echo "reference transcript is required" >&2
    exit 2
fi

extension="${AUDIO_PATH##*.}"
if [[ "$extension" == "$AUDIO_PATH" ]] || ! is_supported_audio_extension "$extension"; then
    echo "unsupported audio extension: $extension" >&2
    exit 2
fi
extension="$(printf '%s' "$extension" | tr '[:upper:]' '[:lower:]')"

mkdir -p "$INPUT_DIR"
audio_out="$INPUT_DIR/$CLIP_ID.$extension"
ref_out="$INPUT_DIR/$CLIP_ID.txt"

if [[ -e "$audio_out" || -e "$ref_out" ]]; then
    echo "destination already exists for clip id: $CLIP_ID" >&2
    exit 1
fi

cp "$AUDIO_PATH" "$audio_out"
printf '%s\n' "$REFERENCE_TEXT" >"$ref_out"

echo "audio: $audio_out"
echo "reference: $ref_out"
