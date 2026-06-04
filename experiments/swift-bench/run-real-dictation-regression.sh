#!/usr/bin/env bash
# Run the Swift benchmark over private real-dictation fixtures.
#
# Expected layout by default:
#
#   real-audio/
#     short-note.wav
#     short-note.txt
#     noisy-room.m4a
#     noisy-room.txt
#
# Each .txt sidecar is the reference transcript for the audio with the
# same stem. Reports default to redacted transcript output and land under
# real-results/, which is ignored by git.

set -euo pipefail

SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$SCRIPT_PATH")"

INPUT_DIR="real-audio"
OUTDIR="real-results"
BACKEND="v3"
TRIALS="5"
ALLOW_MISSING_REF=0
REDACT_TRANSCRIPTS=1
REDACT_PATHS=1
SELF_TEST=0

usage() {
    cat <<'USAGE'
usage: ./run-real-dictation-regression.sh [options]

Options:
  --input-dir <path>       directory with private audio + .txt sidecars (default: real-audio)
  --out-dir <path>         report directory (default: real-results)
  --backend <name>         parakey-bench backend: v3, apple, 110m, fluid, both (default: v3)
  --trials <n>             measured trials per clip (default: 5)
  --allow-missing-ref      run clips without .txt sidecars, skipping WER
  --show-transcripts       include reference/hypothesis text in the report
  --show-paths             include local fixture filenames and paths in the report
  --self-test              run parser and report-redaction self-tests
  -h, --help               show this help

Supported input extensions: wav, aiff, aif, caf, m4a, mp3.
Audio is normalized through afconvert into a temporary 16 kHz Float32
WAV before benchmarking; parakey-bench then does the final mono
conversion with AVAudioConverter.
USAGE
}

need_value() {
    if [[ $# -lt 2 || -z "$2" || "$2" == --* ]]; then
        echo "$1 requires a value" >&2
        usage >&2
        exit 2
    fi
}

path_label() {
    if [[ "$REDACT_PATHS" -eq 1 ]]; then
        printf '<redacted path>'
    else
        printf '%s' "$1"
    fi
}

transcript_output_label() {
    if [[ "$REDACT_TRANSCRIPTS" -eq 1 ]]; then
        printf 'redacted'
    else
        printf 'included'
    fi
}

fixture_paths_label() {
    if [[ "$REDACT_PATHS" -eq 1 ]]; then
        printf 'redacted'
    else
        printf 'included'
    fi
}

clip_id_for() {
    local index="$1"
    local stem="$2"
    if [[ "$REDACT_PATHS" -eq 1 ]]; then
        printf '%03d' "$index"
    else
        printf '%03d-%s' "$index" "$stem" | tr -c '[:alnum:]_.-' '-'
    fi
}

write_report_header() {
    local report="$1"
    local timestamp="$2"
    local clip_count="$3"
    {
        echo "# Parakey Real-Dictation Regression"
        echo
        echo "- Date: $timestamp"
        echo "- Input directory: $(path_label "$INPUT_DIR")"
        echo "- Backend: $BACKEND"
        echo "- Trials per clip: $TRIALS"
        echo "- Transcript output: $(transcript_output_label)"
        echo "- Fixture paths: $(fixture_paths_label)"
        echo "- Clips: $clip_count"
        echo
        echo "> This report is generated from private local fixtures. The default"
        echo "> redacted mode keeps reference text, hypothesis text, filenames, and"
        echo "> local paths out of the report while preserving WER, latency, and"
        echo "> memory numbers."
    } >"$report"
}

write_clip_section_header() {
    local report="$1"
    local clip_number="$2"
    local clip_id="$3"
    local stem="$4"
    local clip="$5"
    local ref="$6"

    {
        echo
        if [[ "$REDACT_PATHS" -eq 1 ]]; then
            echo "## Clip $clip_number"
        else
            echo "## $clip_id"
        fi
        echo
        echo "- Clip name: $([[ "$REDACT_PATHS" -eq 1 ]] && echo '<redacted>' || echo "$stem")"
        echo "- Source: $(path_label "$clip")"
        if [[ -f "$ref" ]]; then
            echo "- Reference: $(path_label "$ref") (WER enabled)"
        else
            echo "- Reference: missing (WER skipped)"
        fi
        echo
        echo '```text'
    } >>"$report"
}

assert_contains() {
    local file="$1"
    local needle="$2"
    if ! grep -Fq -- "$needle" "$file"; then
        echo "self-test expected report to contain: $needle" >&2
        exit 1
    fi
}

assert_not_contains() {
    local file="$1"
    local needle="$2"
    if grep -Fq -- "$needle" "$file"; then
        echo "self-test found private value in report: $needle" >&2
        exit 1
    fi
}

run_self_test() {
    local tmpdir
    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/parakey-real-self-test.XXXXXX")"
    trap 'rm -rf "$tmpdir"' EXIT INT TERM

    local secret_dir="$tmpdir/Private Client Project"
    local secret_stem="confidential-medical-note"
    local secret_transcript="patient alpha private transcript"
    mkdir -p "$secret_dir"
    touch "$secret_dir/$secret_stem.wav"
    printf '%s\n' "$secret_transcript" >"$secret_dir/$secret_stem.txt"

    INPUT_DIR="$secret_dir"
    OUTDIR="$tmpdir/out"
    BACKEND="v3"
    TRIALS="2"
    REDACT_TRANSCRIPTS=1
    REDACT_PATHS=1

    local report="$tmpdir/report.md"
    local clip_number="001"
    local clip_id
    clip_id="$(clip_id_for 1 "$secret_stem")"
    write_report_header "$report" "20260101T000000Z" 1
    write_clip_section_header "$report" "$clip_number" "$clip_id" "$secret_stem" "$secret_dir/$secret_stem.wav" "$secret_dir/$secret_stem.txt"
    {
        echo "parakey-bench: $clip_id.wav, 1 trials, backend=v3"
        echo "reference: <redacted ${#secret_transcript} chars>"
        echo "transcript: [WER 0.0%] <redacted ${#secret_transcript} chars>"
        echo '```'
    } >>"$report"

    assert_contains "$report" "- Input directory: <redacted path>"
    assert_contains "$report" "- Clip name: <redacted>"
    assert_contains "$report" "parakey-bench: 001.wav"
    assert_not_contains "$report" "Private Client Project"
    assert_not_contains "$report" "$secret_stem"
    assert_not_contains "$report" "$secret_transcript"

    local missing_value_log="$tmpdir/missing-value.log"
    if bash "$SCRIPT_PATH" --trials >"$missing_value_log" 2>&1; then
        echo "self-test expected --trials without a value to fail" >&2
        exit 1
    fi
    assert_contains "$missing_value_log" "--trials requires a value"

    rm -rf "$tmpdir"
    trap - EXIT INT TERM
    echo "real-dictation regression self-test passed"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --input-dir)
            need_value "$@"
            INPUT_DIR="$2"
            shift 2
            ;;
        --out-dir)
            need_value "$@"
            OUTDIR="$2"
            shift 2
            ;;
        --backend)
            need_value "$@"
            BACKEND="$2"
            shift 2
            ;;
        --trials)
            need_value "$@"
            TRIALS="$2"
            shift 2
            ;;
        --allow-missing-ref)
            ALLOW_MISSING_REF=1
            shift
            ;;
        --show-transcripts)
            REDACT_TRANSCRIPTS=0
            shift
            ;;
        --show-paths)
            REDACT_PATHS=0
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

if [[ ! -d "$INPUT_DIR" ]]; then
    cat >&2 <<MSG
input directory not found: $INPUT_DIR

Create it and add private audio files plus matching .txt reference files.
See real-audio/README.md.
MSG
    exit 1
fi

if ! [[ "$TRIALS" =~ ^[0-9]+$ ]] || [[ "$TRIALS" -lt 1 ]]; then
    echo "--trials must be a positive integer" >&2
    exit 2
fi

if ! command -v afconvert >/dev/null 2>&1; then
    echo "afconvert is required to normalize audio" >&2
    exit 1
fi

clips=()
while IFS= read -r clip; do
    clips+=( "$clip" )
done < <(
    find "$INPUT_DIR" -type f \
        \( -iname '*.wav' -o -iname '*.aiff' -o -iname '*.aif' -o -iname '*.caf' -o -iname '*.m4a' -o -iname '*.mp3' \) \
        | sort
)

if [[ "${#clips[@]}" -eq 0 ]]; then
    echo "no supported audio files found in $INPUT_DIR" >&2
    exit 1
fi

missing_refs=()
for clip in "${clips[@]}"; do
    ref="${clip%.*}.txt"
    if [[ ! -f "$ref" ]]; then
        missing_refs+=( "$ref" )
    fi
done

if [[ "${#missing_refs[@]}" -gt 0 && "$ALLOW_MISSING_REF" -eq 0 ]]; then
    echo "missing reference transcript sidecars:" >&2
    printf '  %s\n' "${missing_refs[@]}" >&2
    echo "add .txt sidecars or pass --allow-missing-ref to skip WER for those clips" >&2
    exit 1
fi

mkdir -p "$OUTDIR"
tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/parakey-real-dictation.XXXXXX")"
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT INT TERM

echo "building parakey-bench..."
swift build -c release >/dev/null

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
safe_backend="$(printf '%s' "$BACKEND" | tr -c '[:alnum:]_.-' '-')"
report="$OUTDIR/$timestamp-$safe_backend.md"

write_report_header "$report" "$timestamp" "${#clips[@]}"

clip_index=0
for clip in "${clips[@]}"; do
    clip_index=$((clip_index + 1))
    clip_number="$(printf '%03d' "$clip_index")"
    stem="$(basename "$clip")"
    stem="${stem%.*}"
    clip_id="$(clip_id_for "$clip_index" "$stem")"
    normalized="$tmpdir/$clip_id.wav"
    ref="${clip%.*}.txt"

    echo "normalizing clip $clip_number..."
    afconvert -f WAVE -d LEF32@16000 "$clip" "$normalized"
    if [[ -f "$ref" ]]; then
        cp "$ref" "$tmpdir/$clip_id.txt"
    fi

    bench_args=( ".build/release/parakey-bench" "--file" "$normalized" "--backend" "$BACKEND" "--trials" "$TRIALS" )
    if [[ "$REDACT_TRANSCRIPTS" -eq 1 ]]; then
        bench_args+=( "--redact-transcripts" )
    fi

    write_clip_section_header "$report" "$clip_number" "$clip_id" "$stem" "$clip" "$ref"

    echo "benchmarking clip $clip_number..."
    if ! "${bench_args[@]}" >>"$report" 2>&1; then
        {
            echo '```'
            echo
            echo "Benchmark failed for clip $clip_number."
        } >>"$report"
        echo "benchmark failed for clip $clip_number; see $report" >&2
        exit 1
    fi

    echo '```' >>"$report"
done

echo "report: $report"
