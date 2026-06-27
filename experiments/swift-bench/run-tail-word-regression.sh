#!/usr/bin/env bash
# Reproduce and measure final-word retention on short push-to-talk clips.
#
# The script uses synthetic local TTS so the report can be shared without
# private dictation audio. It trims trailing silence, cuts the end of each
# phrase to simulate an early key release, then runs parakey-bench with
# configurable Unified trailing-silence padding.

set -euo pipefail

SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$SCRIPT_PATH")"

OUTDIR="tail-results"
VOICE="Samantha"
TRIALS="1"
CUT_MS_LIST="100 150 200"
CAPTURE_GRACE_MS_LIST="0"
UNIFIED_TRAILING_MS_LIST="0 250"
INCLUDE_V3_BASELINE=1
REQUIRE_CANDIDATE_PASS=1
CANDIDATE_UNIFIED_TRAILING_MS="250"
MAX_CANDIDATE_WER="20.0"
SELF_TEST=0
KEEP_TEMP=0
tmpdir=""

usage() {
    cat <<'USAGE'
usage: ./run-tail-word-regression.sh [options]

Options:
  --out-dir <path>              report directory (default: tail-results)
  --voice <name>                macOS say voice (default: Samantha)
  --trials <n>                  measured trials per case (default: 1)
  --cut-ms-list <list>          simulated early-release cuts, comma or space separated (default: 100 150 200)
  --capture-grace-ms-list <list>
                                post-release capture grace to simulate, comma or space separated (default: 0)
  --unified-trailing-ms-list <list>
                                Unified silence padding sweep, comma or space separated (default: 0 250)
  --skip-v3-baseline            do not run the v3 baseline rows
  --no-threshold                write the report but do not fail on candidate-threshold misses
  --keep-temp                   keep generated audio and raw bench logs
  --self-test                   run parser and threshold self-tests only
  -h, --help                    show this help

The candidate threshold is checked for the Unified evaluation setting:
250 ms synthetic trailing silence, 0 ms capture grace, final word retained,
and max WER <= 20.0% on the known regression cases.
USAGE
}

need_value() {
    if [[ $# -lt 2 || -z "$2" || "$2" == --* ]]; then
        echo "$1 requires a value" >&2
        usage >&2
        exit 2
    fi
}

normalize_list() {
    printf '%s' "$1" | tr ',' ' '
}

validate_ms_list() {
    local label="$1"
    local raw="$2"
    local value
    for value in $(normalize_list "$raw"); do
        if ! [[ "$value" =~ ^[0-9]+$ ]]; then
            echo "$label must contain only non-negative integer millisecond values" >&2
            exit 2
        fi
    done
}

effective_cut_ms() {
    local cut_ms="$1"
    local grace_ms="$2"
    if [[ "$grace_ms" -ge "$cut_ms" ]]; then
        printf '0'
    else
        printf '%d' $((cut_ms - grace_ms))
    fi
}

float_le() {
    awk -v a="$1" -v b="$2" 'BEGIN { exit(a <= b ? 0 : 1) }'
}

extract_final_word_retained() {
    local log_file="$1"
    if grep -Eq 'final-word retained=false' "$log_file"; then
        printf 'false'
    elif grep -Eq 'final-word retained=true' "$log_file"; then
        printf 'true'
    else
        printf 'unknown'
    fi
}

extract_max_wer_percent() {
    local log_file="$1"
    grep -Eo 'WER [0-9]+([.][0-9]+)?%' "$log_file" \
        | sed -E 's/WER ([0-9.]+)%/\1/' \
        | awk 'BEGIN { max = "" } { if (max == "" || $1 > max) max = $1 } END { if (max == "") print "unknown"; else print max }'
}

extract_p50_ms() {
    local log_file="$1"
    sed -nE 's/.*latency:[[:space:]]+p50=[[:space:]]*([0-9.]+) ms.*/\1/p' "$log_file" | head -n 1
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

is_required_candidate_case() {
    local phrase="$1"
    local cut_ms="$2"
    local grace_ms="$3"
    local backend="$4"
    local trailing_ms="$5"

    [[ "$backend" == "unified" ]] || return 1
    [[ "$trailing_ms" == "$CANDIDATE_UNIFIED_TRAILING_MS" ]] || return 1
    [[ "$grace_ms" == "0" ]] || return 1

    case "$phrase:$cut_ms" in
        why:100|why:150|why:200|done:150|done:200)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

write_wav_variant() {
    local input="$1"
    local output="$2"
    local cut_ms="$3"
    local trim_mode="$4"

    python3 - "$input" "$output" "$cut_ms" "$trim_mode" <<'PY'
import array
import struct
import sys
from pathlib import Path

input_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])
cut_ms = int(sys.argv[3])
trim_mode = sys.argv[4] == "trim"

blob = input_path.read_bytes()
if blob[:4] != b"RIFF" or blob[8:12] != b"WAVE":
    raise SystemExit(f"{input_path} is not a RIFF/WAVE file")

pos = 12
fmt = None
data = None
while pos + 8 <= len(blob):
    chunk_id = blob[pos:pos + 4]
    size = struct.unpack_from("<I", blob, pos + 4)[0]
    start = pos + 8
    end = start + size
    chunk = blob[start:end]
    if chunk_id == b"fmt ":
        fmt = chunk
    elif chunk_id == b"data":
        data = chunk
    pos = end + (size % 2)

if fmt is None or data is None:
    raise SystemExit(f"{input_path} is missing fmt or data chunks")

audio_format, channels, sample_rate, _, _, bits_per_sample = struct.unpack_from("<HHIIHH", fmt, 0)
if audio_format not in (3, 65534) or channels != 1 or bits_per_sample != 32:
    raise SystemExit(
        f"{input_path} must be 16 kHz mono Float32 WAV; got format={audio_format}, "
        f"channels={channels}, bits={bits_per_sample}"
    )

samples = array.array("f")
samples.frombytes(data[:len(data) - (len(data) % 4)])
if sys.byteorder != "little":
    samples.byteswap()

if trim_mode and samples:
    threshold = 0.0001
    active = [i for i, sample in enumerate(samples) if abs(sample) > threshold]
    if active:
        keep_before = int(sample_rate * 0.050)
        keep_after = int(sample_rate * 0.020)
        start = max(0, active[0] - keep_before)
        end = min(len(samples), active[-1] + 1 + keep_after)
        samples = samples[start:end]

if cut_ms > 0 and samples:
    cut_samples = int(round(sample_rate * cut_ms / 1000.0))
    if cut_samples >= len(samples):
        samples = array.array("f")
    else:
        samples = samples[:-cut_samples]

if sys.byteorder != "little":
    samples.byteswap()
data_out = samples.tobytes()
fmt_out = struct.pack("<HHIIHH", 3, 1, sample_rate, sample_rate * 4, 4, 32)
riff_size = 4 + (8 + len(fmt_out)) + (8 + len(data_out))
output_path.write_bytes(
    b"RIFF" + struct.pack("<I", riff_size) + b"WAVE" +
    b"fmt " + struct.pack("<I", len(fmt_out)) + fmt_out +
    b"data" + struct.pack("<I", len(data_out)) + data_out
)
PY
}

run_self_test() {
    local self_tmp
    self_tmp="$(mktemp -d "${TMPDIR:-/tmp}/parakey-tail-self-test.XXXXXX")"
    trap 'rm -rf "$self_tmp"' EXIT INT TERM

    local mock="$self_tmp/mock.log"
    {
        echo 'latency:  p50=  123.4 ms  min=  120.0 ms  max=  130.0 ms'
        echo 'transcript: [WER 16.7%] [final-word retained=false expected="sure" actual-last="not"] "Why would anyone be not"'
    } >"$mock"

    assert_eq "$(extract_final_word_retained "$mock")" "false" "retention parser"
    assert_eq "$(extract_max_wer_percent "$mock")" "16.7" "WER parser"
    assert_eq "$(extract_p50_ms "$mock")" "123.4" "latency parser"
    assert_eq "$(effective_cut_ms 150 50)" "100" "effective cut"
    assert_eq "$(effective_cut_ms 50 150)" "0" "grace caps at full tail"

    if ! is_required_candidate_case "why" "100" "0" "unified" "250"; then
        echo "self-test expected why/100 to be a required candidate case" >&2
        exit 1
    fi
    if is_required_candidate_case "done" "100" "0" "unified" "250"; then
        echo "self-test did not expect done/100 to be a required candidate case" >&2
        exit 1
    fi

    validate_ms_list "--cut-ms-list" "0,100 250"

    local bad_list_log="$self_tmp/bad-list.log"
    if bash "$SCRIPT_PATH" --cut-ms-list nope --self-test >"$bad_list_log" 2>&1; then
        echo "self-test expected bad --cut-ms-list to fail" >&2
        exit 1
    fi
    if ! grep -Fq -- "--cut-ms-list must contain only non-negative integer" "$bad_list_log"; then
        echo "self-test expected bad-list error message" >&2
        exit 1
    fi

    rm -rf "$self_tmp"
    trap - EXIT INT TERM
    echo "tail-word regression self-test passed"
}

cleanup() {
    if [[ "$KEEP_TEMP" -eq 0 && -n "$tmpdir" ]]; then
        rm -rf "$tmpdir"
    elif [[ -n "$tmpdir" ]]; then
        echo "kept temp files: $tmpdir"
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --out-dir)
            need_value "$@"
            OUTDIR="$2"
            shift 2
            ;;
        --voice)
            need_value "$@"
            VOICE="$2"
            shift 2
            ;;
        --trials)
            need_value "$@"
            TRIALS="$2"
            shift 2
            ;;
        --cut-ms-list)
            need_value "$@"
            CUT_MS_LIST="$2"
            shift 2
            ;;
        --capture-grace-ms-list)
            need_value "$@"
            CAPTURE_GRACE_MS_LIST="$2"
            shift 2
            ;;
        --unified-trailing-ms-list)
            need_value "$@"
            UNIFIED_TRAILING_MS_LIST="$2"
            shift 2
            ;;
        --skip-v3-baseline)
            INCLUDE_V3_BASELINE=0
            shift
            ;;
        --no-threshold)
            REQUIRE_CANDIDATE_PASS=0
            shift
            ;;
        --keep-temp)
            KEEP_TEMP=1
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

validate_ms_list "--cut-ms-list" "$CUT_MS_LIST"
validate_ms_list "--capture-grace-ms-list" "$CAPTURE_GRACE_MS_LIST"
validate_ms_list "--unified-trailing-ms-list" "$UNIFIED_TRAILING_MS_LIST"

if [[ "$SELF_TEST" -eq 1 ]]; then
    run_self_test
    exit 0
fi

if ! [[ "$TRIALS" =~ ^[0-9]+$ ]] || [[ "$TRIALS" -lt 1 ]]; then
    echo "--trials must be a positive integer" >&2
    exit 2
fi

if ! command -v say >/dev/null 2>&1; then
    echo "macOS say is required to synthesize fixtures" >&2
    exit 1
fi

if ! command -v afconvert >/dev/null 2>&1; then
    echo "afconvert is required to normalize fixtures" >&2
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required to trim and cut Float32 WAV fixtures" >&2
    exit 1
fi

mkdir -p "$OUTDIR"
tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/parakey-tail-word.XXXXXX")"
trap cleanup EXIT INT TERM

echo "building parakey-bench..."
swift build -c release >/dev/null

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
report="$OUTDIR/$timestamp-tail-word.md"
tsv="$OUTDIR/$timestamp-tail-word.tsv"

{
    echo "# Parakey Tail-Word Regression"
    echo
    echo "- Date: $timestamp"
    echo "- Voice: $VOICE"
    echo "- Trials per case: $TRIALS"
    echo "- Cut ms list: $CUT_MS_LIST"
    echo "- Capture grace ms list: $CAPTURE_GRACE_MS_LIST"
    echo "- Unified trailing silence ms list: $UNIFIED_TRAILING_MS_LIST"
    echo "- v3 baseline: $([[ "$INCLUDE_V3_BASELINE" -eq 1 ]] && echo included || echo skipped)"
    echo
    echo "The cut column simulates releasing the key before the phrase finishes."
    echo "Capture grace simulates Parakey continuing to record briefly after release."
    echo "Unified trailing silence is synthetic zero padding added before the Unified model sees the audio."
    echo
    echo "Candidate threshold: Unified @ ${CANDIDATE_UNIFIED_TRAILING_MS} ms, 0 ms capture grace, final word retained, max WER <= ${MAX_CANDIDATE_WER}% on the known regression cases."
    echo
    echo "| Phrase | Cut ms | Grace ms | Effective cut ms | Backend | Unified trailing ms | Max WER % | Final word retained | p50 ms |"
    echo "|---|---:|---:|---:|---|---:|---:|---|---:|"
} >"$report"

printf 'phrase\tcut_ms\tcapture_grace_ms\teffective_cut_ms\tbackend\tunified_trailing_ms\tmax_wer_percent\tfinal_word_retained\tp50_ms\n' >"$tsv"

declare -a CLIPS=(
    "why|Why would anyone be not sure."
    "done|Okay, let's get that done."
)

failures=0
failure_details=()

for entry in "${CLIPS[@]}"; do
    phrase="${entry%%|*}"
    text="${entry#*|}"
    raw_aiff="$tmpdir/$phrase.raw.aiff"
    raw_wav="$tmpdir/$phrase.raw.wav"
    trimmed_wav="$tmpdir/$phrase.trimmed.wav"

    echo "synthesizing $phrase..."
    say -v "$VOICE" -o "$raw_aiff" "$text"
    afconvert -f WAVE -d LEF32@16000 "$raw_aiff" "$raw_wav"
    write_wav_variant "$raw_wav" "$trimmed_wav" "0" "trim"

    for cut_ms in $(normalize_list "$CUT_MS_LIST"); do
        for grace_ms in $(normalize_list "$CAPTURE_GRACE_MS_LIST"); do
            effective_cut="$(effective_cut_ms "$cut_ms" "$grace_ms")"
            case_wav="$tmpdir/$phrase-cut${cut_ms}-grace${grace_ms}.wav"
            write_wav_variant "$trimmed_wav" "$case_wav" "$effective_cut" "notrim"

            backends=()
            if [[ "$INCLUDE_V3_BASELINE" -eq 1 ]]; then
                backends+=( "v3:na" )
            fi
            for trailing_ms in $(normalize_list "$UNIFIED_TRAILING_MS_LIST"); do
                backends+=( "unified:$trailing_ms" )
            done

            for backend_entry in "${backends[@]}"; do
                backend="${backend_entry%%:*}"
                trailing_ms="${backend_entry#*:}"
                log_file="$tmpdir/$phrase-cut${cut_ms}-grace${grace_ms}-${backend}-${trailing_ms}.log"
                bench_args=( ".build/release/parakey-bench" "--file" "$case_wav" "--backend" "$backend" "--trials" "$TRIALS" "--ref" "$text" )
                if [[ "$backend" == "unified" ]]; then
                    bench_args+=( "--unified-trailing-silence-ms" "$trailing_ms" )
                fi

                echo "benchmarking $phrase cut=${cut_ms}ms grace=${grace_ms}ms backend=$backend trailing=${trailing_ms}..."
                if ! "${bench_args[@]}" >"$log_file" 2>&1; then
                    cat "$log_file" >&2
                    echo "benchmark failed for $phrase cut=$cut_ms grace=$grace_ms backend=$backend trailing=$trailing_ms" >&2
                    exit 1
                fi

                wer="$(extract_max_wer_percent "$log_file")"
                retained="$(extract_final_word_retained "$log_file")"
                p50="$(extract_p50_ms "$log_file")"
                [[ -n "$p50" ]] || p50="unknown"

                printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                    "$phrase" "$cut_ms" "$grace_ms" "$effective_cut" "$backend" "$trailing_ms" "$wer" "$retained" "$p50" >>"$tsv"
                printf '| `%s` | %s | %s | %s | `%s` | %s | %s | %s | %s |\n' \
                    "$phrase" "$cut_ms" "$grace_ms" "$effective_cut" "$backend" "$trailing_ms" "$wer" "$retained" "$p50" >>"$report"

                if [[ "$REQUIRE_CANDIDATE_PASS" -eq 1 ]] \
                    && is_required_candidate_case "$phrase" "$cut_ms" "$grace_ms" "$backend" "$trailing_ms"; then
                    if [[ "$retained" != "true" ]]; then
                        failures=$((failures + 1))
                        failure_details+=( "$phrase cut=${cut_ms}ms did not retain final word" )
                    elif [[ "$wer" == "unknown" ]] || ! float_le "$wer" "$MAX_CANDIDATE_WER"; then
                        failures=$((failures + 1))
                        failure_details+=( "$phrase cut=${cut_ms}ms WER ${wer}% exceeded ${MAX_CANDIDATE_WER}%" )
                    fi
                fi
            done
        done
    done
done

if [[ "$failures" -gt 0 ]]; then
    {
        echo
        echo "## Threshold Failures"
        echo
        printf -- '- %s\n' "${failure_details[@]}"
    } >>"$report"
    printf 'tail-word regression failed %d candidate threshold(s):\n' "$failures" >&2
    printf '  %s\n' "${failure_details[@]}" >&2
    echo "report: $report" >&2
    echo "tsv: $tsv" >&2
    exit 1
fi

{
    echo
    echo "## Threshold Result"
    echo
    echo "Candidate threshold passed."
} >>"$report"

echo "report: $report"
echo "tsv: $tsv"
