#!/usr/bin/env bash
# Run parakey-bench while sampling SoC power rails with powermetrics.
#
# powermetrics requires sudo and reports estimates, not lab-grade energy
# numbers. Treat these reports as same-Mac, same-OS comparisons between
# backends or dependency versions, not as cross-device measurements.

set -euo pipefail

SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$SCRIPT_PATH")"

FILE=""
BACKEND="v3"
TRIALS="20"
UNIFIED_TRAILING_SILENCE_MS="250"
SAMPLE_MS="250"
OUTDIR="power-results"
REDACT_TRANSCRIPTS=1
REDACT_PATHS=1
SELF_TEST=0
power_pid=""
tmpdir=""
bench_file=""

usage() {
    cat <<'USAGE'
usage: ./bench-power.sh --file <audio> [options]

Options:
  --backend <name>       parakey-bench backend: v3, unified, apple, 110m, fluid, both (default: v3)
  --trials <n>           measured transcription trials (default: 20)
  --unified-trailing-silence-ms <n>
                         Unified-only trailing silence in ms (default: 250)
  --sample-ms <n>        powermetrics sample interval in ms (default: 250)
  --out-dir <path>       report directory (default: power-results)
  --show-transcripts     include reference/hypothesis text in the bench log
  --show-paths           include local audio filenames and paths in the report
  --self-test            run parser and report-redaction self-tests
  -h, --help             show this help

The script writes:
  <out-dir>/*.md                 human-readable summary
  <out-dir>/*.bench.txt          raw parakey-bench output
  <out-dir>/*.powermetrics.txt   raw powermetrics output
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

report_stem_for() {
    local stem="$1"
    if [[ "$REDACT_PATHS" -eq 1 ]]; then
        printf 'audio'
    else
        printf '%s' "$stem"
    fi
}

prepare_bench_file() {
    bench_file="$FILE"
    if [[ "$REDACT_PATHS" -eq 1 ]]; then
        tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/parakey-power.XXXXXX")"
        local extension="${FILE##*.}"
        if [[ "$extension" == "$FILE" ]]; then
            bench_file="$tmpdir/audio"
        else
            bench_file="$tmpdir/audio.$extension"
        fi
        local file_dir
        file_dir="$(cd "$(dirname "$FILE")" && pwd)"
        ln -s "$file_dir/$(basename "$FILE")" "$bench_file"
        local ref="${FILE%.*}.txt"
        if [[ -f "$ref" ]]; then
            cp "$ref" "${bench_file%.*}.txt"
        fi
    fi
}

cleanup() {
    if [[ -n "$power_pid" ]] && kill -0 "$power_pid" >/dev/null 2>&1; then
        sudo kill -TERM "$power_pid" >/dev/null 2>&1 || true
        wait "$power_pid" 2>/dev/null || true
    fi
    if [[ -n "$tmpdir" ]]; then
        rm -rf "$tmpdir"
    fi
}

write_power_report() {
    local report="$1"
    local timestamp="$2"
    local power_summary="$3"
    local bench_log="$4"
    {
        echo "# Parakey Power Benchmark"
        echo
        echo "- Date: $timestamp"
        echo "- Audio: $(path_label "$FILE")"
        echo "- Backend: $BACKEND"
        echo "- Trials: $TRIALS"
        echo "- Unified trailing silence: ${UNIFIED_TRAILING_SILENCE_MS} ms"
        echo "- powermetrics sample interval: ${SAMPLE_MS} ms"
        echo "- Transcript output: $(transcript_output_label)"
        echo "- Fixture paths: $(fixture_paths_label)"
        echo
        echo "## Power Summary"
        echo
        echo '```text'
        printf '%s\n' "$power_summary"
        echo '```'
        echo
        echo "## Benchmark Output"
        echo
        echo '```text'
        cat "$bench_log"
        echo '```'
        echo
        echo "Raw files:"
        echo
        echo "- $bench_log"
        echo "- $power_log"
    } >"$report"
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
    local self_tmp
    self_tmp="$(mktemp -d "${TMPDIR:-/tmp}/parakey-power-self-test.XXXXXX")"
    trap 'rm -rf "$self_tmp"; cleanup' EXIT INT TERM

    local secret_dir="$self_tmp/Private Battery Client"
    local secret_stem="confidential-board-demo"
    local secret_transcript="private battery transcript"
    mkdir -p "$secret_dir" "$self_tmp/out"
    touch "$secret_dir/$secret_stem.wav"
    printf '%s\n' "$secret_transcript" >"$secret_dir/$secret_stem.txt"

    FILE="$secret_dir/$secret_stem.wav"
    OUTDIR="$self_tmp/out"
    BACKEND="v3"
    TRIALS="2"
    UNIFIED_TRAILING_SILENCE_MS="250"
    SAMPLE_MS="100"
    REDACT_TRANSCRIPTS=1
    REDACT_PATHS=1

    local timestamp="20260101T000000Z"
    local stem="$secret_stem"
    local safe_backend="v3"
    local prefix="$OUTDIR/$timestamp-$(report_stem_for "$stem")-$safe_backend"
    local report="$prefix.md"
    bench_log="$prefix.bench.txt"
    power_log="$prefix.powermetrics.txt"

    prepare_bench_file
    if [[ "$(basename "$bench_file")" != "audio.wav" ]]; then
        echo "self-test expected redacted bench filename, got: $bench_file" >&2
        exit 1
    fi

    {
        echo "parakey-bench: $(basename "$bench_file"), 1 trials, backend=v3"
        echo "reference: <redacted ${#secret_transcript} chars>"
        echo "transcript: [WER 0.0%] <redacted ${#secret_transcript} chars>"
    } >"$bench_log"
    printf 'CPU Power avg: 123.0 mW (2 samples)\n' >"$power_log"

    write_power_report "$report" "$timestamp" "CPU Power avg: 123.0 mW (2 samples)" "$bench_log"
    assert_contains "$report" "- Audio: <redacted path>"
    assert_contains "$report" "- Fixture paths: redacted"
    assert_contains "$report" "parakey-bench: audio.wav"
    assert_not_contains "$report" "Private Battery Client"
    assert_not_contains "$report" "$secret_stem"
    assert_not_contains "$report" "$secret_transcript"

    local missing_value_log="$self_tmp/missing-value.log"
    if bash "$SCRIPT_PATH" --out-dir >"$missing_value_log" 2>&1; then
        echo "self-test expected --out-dir without a value to fail" >&2
        exit 1
    fi
    assert_contains "$missing_value_log" "--out-dir requires a value"

    cleanup
    rm -rf "$self_tmp"
    trap - EXIT INT TERM
    echo "power benchmark self-test passed"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --file)
            need_value "$@"
            FILE="$2"
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
        --unified-trailing-silence-ms)
            need_value "$@"
            UNIFIED_TRAILING_SILENCE_MS="$2"
            shift 2
            ;;
        --sample-ms)
            need_value "$@"
            SAMPLE_MS="$2"
            shift 2
            ;;
        --out-dir)
            need_value "$@"
            OUTDIR="$2"
            shift 2
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

if [[ -z "$FILE" ]]; then
    echo "--file is required" >&2
    usage >&2
    exit 2
fi

if [[ ! -f "$FILE" ]]; then
    echo "audio file not found: $FILE" >&2
    exit 1
fi

if ! [[ "$TRIALS" =~ ^[0-9]+$ ]] || [[ "$TRIALS" -lt 1 ]]; then
    echo "--trials must be a positive integer" >&2
    exit 2
fi

if ! [[ "$UNIFIED_TRAILING_SILENCE_MS" =~ ^[0-9]+$ ]]; then
    echo "--unified-trailing-silence-ms must be a non-negative integer" >&2
    exit 2
fi

if ! [[ "$SAMPLE_MS" =~ ^[0-9]+$ ]] || [[ "$SAMPLE_MS" -lt 50 ]]; then
    echo "--sample-ms must be an integer >= 50" >&2
    exit 2
fi

if ! command -v powermetrics >/dev/null 2>&1; then
    echo "powermetrics is not available on this Mac" >&2
    exit 1
fi

if ! sudo -n true >/dev/null 2>&1; then
    cat >&2 <<'MSG'
powermetrics requires sudo. Run one of:

    sudo -v
    ./bench-power.sh --file <audio>

or invoke this script through sudo from a shell where you trust the repo.
MSG
    exit 1
fi

mkdir -p "$OUTDIR"

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
stem="$(basename "$FILE")"
stem="${stem%.*}"
report_stem="$(report_stem_for "$stem")"
safe_backend="$(printf '%s' "$BACKEND" | tr -c '[:alnum:]_.-' '-')"
prefix="$OUTDIR/$timestamp-$report_stem-$safe_backend"
bench_log="$prefix.bench.txt"
power_log="$prefix.powermetrics.txt"
report="$prefix.md"

echo "building parakey-bench..."
swift build -c release >/dev/null

trap cleanup EXIT INT TERM

prepare_bench_file

bench_args=( ".build/release/parakey-bench" "--file" "$bench_file" "--backend" "$BACKEND" "--trials" "$TRIALS" "--unified-trailing-silence-ms" "$UNIFIED_TRAILING_SILENCE_MS" )
if [[ "$REDACT_TRANSCRIPTS" -eq 1 ]]; then
    bench_args+=( "--redact-transcripts" )
fi

echo "sampling power to $power_log..."
sudo powermetrics \
    --sample-rate "$SAMPLE_MS" \
    --sample-count -1 \
    --buffer-size 1 \
    --samplers cpu_power,gpu_power,ane_power \
    --output-file "$power_log" &
power_pid="$!"

sleep 1
if ! kill -0 "$power_pid" >/dev/null 2>&1; then
    power_status=1
    wait "$power_pid" 2>/dev/null || power_status="$?"
    echo "powermetrics exited before the benchmark started; see $power_log" >&2
    exit "$power_status"
fi

echo "running benchmark..."
bench_status=0
"${bench_args[@]}" >"$bench_log" 2>&1 || bench_status="$?"

cleanup
trap - EXIT INT TERM

power_summary="$(
    awk '
        /^CPU Power:/ { cpu_sum += $3; cpu_n += 1 }
        /^GPU Power:/ { gpu_sum += $3; gpu_n += 1 }
        /^ANE Power:/ { ane_sum += $3; ane_n += 1 }
        END {
            if (cpu_n > 0) printf("CPU Power avg: %.1f mW (%d samples)\n", cpu_sum / cpu_n, cpu_n);
            if (gpu_n > 0) printf("GPU Power avg: %.1f mW (%d samples)\n", gpu_sum / gpu_n, gpu_n);
            if (ane_n > 0) printf("ANE Power avg: %.1f mW (%d samples)\n", ane_sum / ane_n, ane_n);
            if (cpu_n + gpu_n + ane_n == 0) print "No CPU/GPU/ANE power lines parsed; inspect raw powermetrics output.";
        }
    ' "$power_log"
)"

write_power_report "$report" "$timestamp" "$power_summary" "$bench_log"

echo "report: $report"
if [[ "$bench_status" -ne 0 ]]; then
    echo "benchmark failed with status $bench_status; see $bench_log" >&2
    exit "$bench_status"
fi
