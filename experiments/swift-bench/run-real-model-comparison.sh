#!/usr/bin/env bash
# Compare v3 and Unified on the same audio fixture directory.
#
# Reports are private/redacted by default: clip names, paths, references,
# and transcripts stay out of generated Markdown while WER, final-word
# retention, and latency remain visible. Public-corpus wrappers can opt
# into source/report visibility.

set -euo pipefail

SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$SCRIPT_PATH")"

INPUT_DIR="real-audio"
OUTDIR="real-results"
TRIALS="3"
UNIFIED_TRAILING_SILENCE_MS="250"
REDACT_TRANSCRIPTS=1
REDACT_PATHS=1
CORPUS_KIND="private"
SELF_TEST=0

usage() {
    cat <<'USAGE'
usage: ./run-real-model-comparison.sh [options]

Options:
  --input-dir <path>       directory with audio + .txt sidecars (default: real-audio)
  --out-dir <path>         report directory (default: real-results)
  --trials <n>             measured trials per clip/backend (default: 3)
  --unified-trailing-silence-ms <n>
                           Unified-only trailing silence in ms (default: 250)
  --show-transcripts       include reference/hypothesis text in raw bench logs
  --show-paths             include local fixture filenames and paths in the report
  --public-corpus          label the report as licensed public speech instead of private fixtures
  --self-test              run parser, aggregation, and redaction self-tests
  -h, --help               show this help

Supported input extensions: wav, aiff, aif, caf, m4a, mp3, flac.
Each audio file must have a same-stem .txt reference sidecar.
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

clip_id_for() {
    local index="$1"
    local stem="$2"
    if [[ "$REDACT_PATHS" -eq 1 ]]; then
        printf '%03d' "$index"
    else
        printf '%03d-%s' "$index" "$stem" | tr -c '[:alnum:]_.-' '-'
    fi
}

redacted_log_name() {
    local clip_id="$1"
    local backend="$2"
    if [[ "$REDACT_PATHS" -eq 1 ]]; then
        printf '%s-%s.bench.txt' "$clip_id" "$backend"
    else
        printf '%s-%s.bench.txt' "$clip_id" "$backend"
    fi
}

report_title() {
    if [[ "$CORPUS_KIND" == "public" ]]; then
        printf 'Parakey Public-Speech Model Comparison'
    else
        printf 'Parakey Real-Dictation Model Comparison'
    fi
}

report_note() {
    if [[ "$CORPUS_KIND" == "public" ]]; then
        cat <<'MSG'
> This report is generated from licensed public speech fixtures. References,
> hypotheses, fixture filenames, and paths may be included because the corpus
> is intentionally public; use private real-dictation fixtures for product-
> specific push-to-talk behavior.
MSG
    else
        cat <<'MSG'
> This report is generated from private local fixtures. Default
> redaction keeps reference text, hypothesis text, filenames, and
> local paths out of the report while preserving model-decision metrics.
MSG
    fi
}

raw_logs_label() {
    if [[ "$REDACT_TRANSCRIPTS" -eq 1 || "$REDACT_PATHS" -eq 1 ]]; then
        printf 'Raw redacted bench logs'
    else
        printf 'Raw bench logs'
    fi
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

backend_summary_row() {
    local tsv="$1"
    local backend="$2"
    awk -F '\t' -v backend="$backend" '
        NR > 1 && $2 == backend {
            count += 1
            if ($4 == "unknown") {
                unknown_wer += 1
            } else {
                wer_sum += $4
                if (wer_seen == 0 || $4 > worst_wer) {
                    worst_wer = $4
                }
                wer_seen += 1
            }
            if ($5 == "false") {
                final_fail += 1
            }
            if ($6 != "unknown") {
                p50_sum += $6
                p50_seen += 1
            }
        }
        END {
            if (count == 0) {
                printf("| `%s` | 0 | unknown | unknown | unknown | unknown |\n", backend)
                exit
            }
            avg_wer = wer_seen > 0 ? sprintf("%.1f", wer_sum / wer_seen) : "unknown"
            worst = wer_seen > 0 ? sprintf("%.1f", worst_wer) : "unknown"
            avg_p50 = p50_seen > 0 ? sprintf("%.1f", p50_sum / p50_seen) : "unknown"
            printf("| `%s` | %d | %s | %s | %d | %s |\n", backend, count, avg_wer, worst, final_fail, avg_p50)
        }
    ' "$tsv"
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
        echo "self-test expected file to contain: $needle" >&2
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
    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/parakey-real-compare-self-test.XXXXXX")"
    trap 'rm -rf "$tmpdir"' EXIT INT TERM

    local log="$tmpdir/mock.log"
    {
        echo 'latency:  p50=  123.4 ms  min=  120.0 ms  max=  130.0 ms'
        echo 'transcript: [WER 16.7%] [final-word retained=false expected="sure" actual-last="not"] <redacted 23 chars>'
    } >"$log"
    assert_eq "$(extract_final_word_retained "$log")" "false" "final-word parser"
    assert_eq "$(extract_max_wer_percent "$log")" "16.7" "WER parser"
    assert_eq "$(extract_p50_ms "$log")" "123.4" "latency parser"

    local tsv="$tmpdir/results.tsv"
    {
        printf 'clip_id\tbackend\tunified_trailing_ms\tmax_wer_percent\tfinal_word_retained\tp50_ms\n'
        printf '001\tv3\tna\t0.0\ttrue\t50.0\n'
        printf '002\tv3\tna\t10.0\tfalse\t70.0\n'
        printf '001\tunified\t250\t5.0\ttrue\t40.0\n'
    } >"$tsv"
    local summary="$tmpdir/summary.md"
    backend_summary_row "$tsv" "v3" >"$summary"
    assert_contains "$summary" '| `v3` | 2 | 5.0 | 10.0 | 1 | 60.0 |'
    assert_not_contains "$summary" '\n'

    CORPUS_KIND="public"
    report_title >"$summary"
    assert_contains "$summary" "Public-Speech"

    local secret_dir="$tmpdir/Private Project"
    local secret_stem="secret-client-note"
    local secret_text="private dictated reference"
    mkdir -p "$secret_dir"
    touch "$secret_dir/$secret_stem.wav"
    printf '%s\n' "$secret_text" >"$secret_dir/$secret_stem.txt"

    REDACT_PATHS=1
    local clip_id
    clip_id="$(clip_id_for 1 "$secret_stem")"
    assert_eq "$clip_id" "001" "redacted clip id"

    {
        echo "# Report"
        echo "- Input directory: <redacted path>"
        echo "- Clip: $clip_id"
    } >"$summary"
    assert_not_contains "$summary" "Private Project"
    assert_not_contains "$summary" "$secret_stem"
    assert_not_contains "$summary" "$secret_text"

    local missing_value_log="$tmpdir/missing-value.log"
    if bash "$SCRIPT_PATH" --trials >"$missing_value_log" 2>&1; then
        echo "self-test expected --trials without a value to fail" >&2
        exit 1
    fi
    assert_contains "$missing_value_log" "--trials requires a value"

    rm -rf "$tmpdir"
    trap - EXIT INT TERM
    echo "real model comparison self-test passed"
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
        --show-transcripts)
            REDACT_TRANSCRIPTS=0
            shift
            ;;
        --show-paths)
            REDACT_PATHS=0
            shift
            ;;
        --public-corpus)
            CORPUS_KIND="public"
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

if ! [[ "$UNIFIED_TRAILING_SILENCE_MS" =~ ^[0-9]+$ ]]; then
    echo "--unified-trailing-silence-ms must be a non-negative integer" >&2
    exit 2
fi

if [[ ! -d "$INPUT_DIR" ]]; then
    echo "input directory not found: $INPUT_DIR" >&2
    exit 1
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
        \( -iname '*.wav' -o -iname '*.aiff' -o -iname '*.aif' -o -iname '*.caf' -o -iname '*.m4a' -o -iname '*.mp3' -o -iname '*.flac' \) \
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

if [[ "${#missing_refs[@]}" -gt 0 ]]; then
    echo "missing reference transcript sidecars:" >&2
    printf '  %s\n' "${missing_refs[@]}" >&2
    exit 1
fi

mkdir -p "$OUTDIR"
tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/parakey-real-compare.XXXXXX")"
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT INT TERM

echo "building parakey-bench..."
swift build -c release >/dev/null

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
report="$OUTDIR/$timestamp-model-comparison.md"
tsv="$OUTDIR/$timestamp-model-comparison.tsv"
raw_dir="$OUTDIR/$timestamp-model-comparison-logs"
mkdir -p "$raw_dir"

printf 'clip_id\tbackend\tunified_trailing_ms\tmax_wer_percent\tfinal_word_retained\tp50_ms\n' >"$tsv"

{
    echo "# $(report_title)"
    echo
    echo "- Date: $timestamp"
    echo "- Input directory: $(path_label "$INPUT_DIR")"
    echo "- Trials per clip/backend: $TRIALS"
    echo "- Unified trailing silence: ${UNIFIED_TRAILING_SILENCE_MS} ms"
    echo "- Transcript output: $([[ "$REDACT_TRANSCRIPTS" -eq 1 ]] && echo redacted || echo included)"
    echo "- Fixture paths: $([[ "$REDACT_PATHS" -eq 1 ]] && echo redacted || echo included)"
    echo "- Clips: ${#clips[@]}"
    echo
    report_note
    echo
    echo "## Per-Clip Results"
    echo
    echo "| Clip | Backend | Unified trailing ms | Max WER % | Final word retained | p50 ms |"
    echo "|---|---|---:|---:|---|---:|"
} >"$report"

clip_index=0
for clip in "${clips[@]}"; do
    clip_index=$((clip_index + 1))
    stem="$(basename "$clip")"
    stem="${stem%.*}"
    clip_id="$(clip_id_for "$clip_index" "$stem")"
    normalized="$tmpdir/$clip_id.wav"
    ref="${clip%.*}.txt"

    echo "normalizing clip $clip_id..."
    afconvert -f WAVE -d LEF32@16000 "$clip" "$normalized"
    cp "$ref" "$tmpdir/$clip_id.txt"

    for backend in v3 unified; do
        log_file="$raw_dir/$(redacted_log_name "$clip_id" "$backend")"
        bench_args=( ".build/release/parakey-bench" "--file" "$normalized" "--backend" "$backend" "--trials" "$TRIALS" )
        if [[ "$backend" == "unified" ]]; then
            bench_args+=( "--unified-trailing-silence-ms" "$UNIFIED_TRAILING_SILENCE_MS" )
        fi
        if [[ "$REDACT_TRANSCRIPTS" -eq 1 ]]; then
            bench_args+=( "--redact-transcripts" )
        fi

        echo "benchmarking clip $clip_id backend=$backend..."
        if ! "${bench_args[@]}" >"$log_file" 2>&1; then
            cat "$log_file" >&2
            echo "benchmark failed for clip $clip_id backend=$backend; see $log_file" >&2
            exit 1
        fi

        wer="$(extract_max_wer_percent "$log_file")"
        retained="$(extract_final_word_retained "$log_file")"
        p50="$(extract_p50_ms "$log_file")"
        [[ -n "$p50" ]] || p50="unknown"
        trailing="na"
        if [[ "$backend" == "unified" ]]; then
            trailing="$UNIFIED_TRAILING_SILENCE_MS"
        fi

        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$clip_id" "$backend" "$trailing" "$wer" "$retained" "$p50" >>"$tsv"
        printf '| `%s` | `%s` | %s | %s | %s | %s |\n' \
            "$clip_id" "$backend" "$trailing" "$wer" "$retained" "$p50" >>"$report"
    done
done

{
    echo
    echo "## Summary"
    echo
    echo "| Backend | Clip rows | Average WER % | Worst WER % | Final-word failures | Average p50 ms |"
    echo "|---|---:|---:|---:|---:|---:|"
    backend_summary_row "$tsv" "v3"
    backend_summary_row "$tsv" "unified"
    echo
    echo "$(raw_logs_label): $(path_label "$raw_dir")"
    echo "Machine-readable TSV: $(path_label "$tsv")"
} >>"$report"

echo "report: $report"
echo "tsv: $tsv"
