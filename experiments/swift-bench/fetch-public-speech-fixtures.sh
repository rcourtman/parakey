#!/usr/bin/env bash
# Fetch licensed public speech fixtures for Parakey ASR benchmarks.
#
# The script intentionally imports a bounded subset into public-audio/
# rather than checking audio into git. Generated clips are local benchmark
# fixtures with same-stem .txt references, matching the private real-audio
# layout used by the existing comparison scripts.

set -euo pipefail

SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$SCRIPT_PATH")"

SOURCE="librispeech"
SPLIT="dev-clean"
COUNT="25"
START_INDEX="0"
OUT_ROOT="public-audio"
FIXTURE_DIR_OVERRIDE=""
CACHE_DIR="public-downloads"
FORCE=0
SELF_TEST=0

usage() {
    cat <<'USAGE'
usage: ./fetch-public-speech-fixtures.sh [options]

Options:
  --source <name>       public corpus to fetch: librispeech (default: librispeech)
  --split <name>        LibriSpeech split: dev-clean, dev-other, test-clean, test-other (default: dev-clean)
  --count <n>           number of clips to import (default: 25)
  --start-index <n>     zero-based offset into sorted transcript rows (default: 0)
  --out-dir <path>      generated fixture root (default: public-audio)
  --fixture-dir <path>  exact generated fixture directory; overrides --out-dir
  --cache-dir <path>    download cache for upstream archives (default: public-downloads)
  --force               replace an existing generated fixture directory
  --self-test           run parser and selection self-tests only
  -h, --help            show this help

The default source downloads the LibriSpeech dev-clean archive from
OpenSLR, verifies the upstream MD5 checksum, extracts the selected FLAC
clips, converts them to 16 kHz Float32 WAV with afconvert, and writes
same-stem .txt reference sidecars plus manifest.tsv.

Generated audio, download archives, and reports are ignored by git.
USAGE
}

need_value() {
    if [[ $# -lt 2 || -z "$2" || "$2" == --* ]]; then
        echo "$1 requires a value" >&2
        usage >&2
        exit 2
    fi
}

is_positive_integer() {
    [[ "$1" =~ ^[0-9]+$ ]] && [[ "$1" -ge 1 ]]
}

is_nonnegative_integer() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

is_supported_librispeech_split() {
    case "$1" in
        dev-clean|dev-other|test-clean|test-other) return 0 ;;
        *) return 1 ;;
    esac
}

librispeech_archive_name() {
    local split="$1"
    printf '%s.tar.gz' "$split"
}

librispeech_archive_url() {
    local split="$1"
    printf 'https://www.openslr.org/resources/12/%s' "$(librispeech_archive_name "$split")"
}

librispeech_md5_url() {
    printf 'https://www.openslr.org/resources/12/md5sum.txt'
}

compute_md5() {
    local file="$1"
    if command -v md5 >/dev/null 2>&1; then
        md5 -q "$file"
    elif command -v md5sum >/dev/null 2>&1; then
        md5sum "$file" | awk '{ print $1 }'
    else
        echo "md5 or md5sum is required for archive verification" >&2
        exit 1
    fi
}

expected_md5_for_archive() {
    local md5_file="$1"
    local archive_name="$2"
    awk -v name="$archive_name" '$2 == name { print $1 }' "$md5_file" | head -n 1
}

verify_md5() {
    local file="$1"
    local expected="$2"
    local actual
    actual="$(compute_md5 "$file")"
    if [[ "$actual" != "$expected" ]]; then
        cat >&2 <<MSG
checksum mismatch for $file
expected: $expected
actual:   $actual

Delete the cached archive and rerun the fetcher.
MSG
        exit 1
    fi
}

download_file() {
    local url="$1"
    local dest="$2"

    mkdir -p "$(dirname "$dest")"
    if [[ -f "$dest" ]]; then
        echo "using cached download: $dest"
        return
    fi

    echo "downloading $url"
    curl -fL --retry 3 --continue-at - --output "$dest" "$url"
}

select_librispeech_entries() {
    local transcript_root="$1"
    local split="$2"
    local start_index="$3"
    local count="$4"
    local out_tsv="$5"
    local seen=0
    local selected=0

    : >"$out_tsv"
    while IFS= read -r transcript_file; do
        while IFS= read -r line; do
            [[ -n "${line//[[:space:]]/}" ]] || continue
            if [[ "$line" != *" "* ]]; then
                echo "malformed transcript row in $transcript_file: $line" >&2
                exit 1
            fi

            local original_id="${line%% *}"
            local text="${line#* }"
            local speaker="${original_id%%-*}"
            local rest="${original_id#*-}"
            local chapter="${rest%%-*}"
            local member="LibriSpeech/$split/$speaker/$chapter/$original_id.flac"

            if [[ "$seen" -ge "$start_index" && "$selected" -lt "$count" ]]; then
                printf '%s\t%s\t%s\n' "$original_id" "$member" "$text" >>"$out_tsv"
                selected=$((selected + 1))
            fi

            seen=$((seen + 1))
            if [[ "$selected" -ge "$count" ]]; then
                break
            fi
        done <"$transcript_file"

        if [[ "$selected" -ge "$count" ]]; then
            break
        fi
    done < <(find "$transcript_root" -type f -name '*.trans.txt' | LC_ALL=C sort)

    if [[ "$selected" -lt "$count" ]]; then
        echo "requested $count clip(s), but only selected $selected from $transcript_root" >&2
        exit 1
    fi
}

filter_librispeech_transcript_members() {
    local split_name="$1"
    awk -v split_name="$split_name" '$0 ~ "^LibriSpeech/" split_name "/.*\\.trans\\.txt$" { print }'
}

safe_remove_generated_dir() {
    local dir="$1"
    case "$dir" in
        ""|"/"|".") echo "refusing to remove unsafe fixture directory: $dir" >&2; exit 1 ;;
    esac
    rm -rf "$dir"
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
    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/parakey-public-fetch-self-test.XXXXXX")"
    trap 'rm -rf "$tmpdir"' EXIT INT TERM

    assert_success "supported split" is_supported_librispeech_split "dev-clean"
    assert_failure "unsupported split" is_supported_librispeech_split "train-clean-100"
    assert_success "positive integer" is_positive_integer "1"
    assert_failure "zero is not positive" is_positive_integer "0"
    assert_success "non-negative integer" is_nonnegative_integer "0"
    assert_eq "$(librispeech_archive_name dev-clean)" "dev-clean.tar.gz" "archive name"
    assert_eq "$(librispeech_archive_url test-other)" "https://www.openslr.org/resources/12/test-other.tar.gz" "archive URL"

    local member_list="$tmpdir/members.txt"
    {
        echo "LibriSpeech/dev-clean/1/2/1-2.trans.txt"
        echo "LibriSpeech/test-clean/1/2/1-2.trans.txt"
        echo "LibriSpeech/dev-clean/1/2/1-2-0000.flac"
    } | filter_librispeech_transcript_members "dev-clean" >"$member_list"
    assert_eq "$(wc -l <"$member_list" | tr -d '[:space:]')" "1" "transcript member filter count"
    assert_file_contains "$member_list" "LibriSpeech/dev-clean/1/2/1-2.trans.txt"

    local checksum_file="$tmpdir/md5sum.txt"
    local data_file="$tmpdir/data.bin"
    printf 'fixture bytes\n' >"$data_file"
    printf '%s  data.bin\n' "$(compute_md5 "$data_file")" >"$checksum_file"
    assert_eq "$(expected_md5_for_archive "$checksum_file" "data.bin")" "$(compute_md5 "$data_file")" "expected md5 parser"
    verify_md5 "$data_file" "$(compute_md5 "$data_file")"

    local transcript_root="$tmpdir/transcripts"
    mkdir -p "$transcript_root/1/2" "$transcript_root/3/4"
    {
        echo "1-2-0000 FIRST ROW"
        echo "1-2-0001 SECOND ROW"
    } >"$transcript_root/1/2/1-2.trans.txt"
    {
        echo "3-4-0000 THIRD ROW"
        echo "3-4-0001 FOURTH ROW"
    } >"$transcript_root/3/4/3-4.trans.txt"

    local selected="$tmpdir/selected.tsv"
    select_librispeech_entries "$transcript_root" "dev-clean" 1 2 "$selected"
    assert_file_contains "$selected" $'1-2-0001\tLibriSpeech/dev-clean/1/2/1-2-0001.flac\tSECOND ROW'
    assert_file_contains "$selected" $'3-4-0000\tLibriSpeech/dev-clean/3/4/3-4-0000.flac\tTHIRD ROW'

    local missing_value_log="$tmpdir/missing-value.log"
    if bash "$SCRIPT_PATH" --count >"$missing_value_log" 2>&1; then
        echo "self-test expected --count without a value to fail" >&2
        exit 1
    fi
    assert_file_contains "$missing_value_log" "--count requires a value"

    rm -rf "$tmpdir"
    trap - EXIT INT TERM
    echo "public speech fixture fetcher self-test passed"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --source)
            need_value "$@"
            SOURCE="$2"
            shift 2
            ;;
        --split)
            need_value "$@"
            SPLIT="$2"
            shift 2
            ;;
        --count)
            need_value "$@"
            COUNT="$2"
            shift 2
            ;;
        --start-index)
            need_value "$@"
            START_INDEX="$2"
            shift 2
            ;;
        --out-dir)
            need_value "$@"
            OUT_ROOT="$2"
            shift 2
            ;;
        --fixture-dir)
            need_value "$@"
            FIXTURE_DIR_OVERRIDE="$2"
            shift 2
            ;;
        --cache-dir)
            need_value "$@"
            CACHE_DIR="$2"
            shift 2
            ;;
        --force)
            FORCE=1
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

if [[ "$SOURCE" != "librispeech" ]]; then
    echo "unsupported source: $SOURCE" >&2
    exit 2
fi

if ! is_supported_librispeech_split "$SPLIT"; then
    echo "unsupported LibriSpeech split: $SPLIT" >&2
    exit 2
fi

if ! is_positive_integer "$COUNT"; then
    echo "--count must be a positive integer" >&2
    exit 2
fi

if ! is_nonnegative_integer "$START_INDEX"; then
    echo "--start-index must be a non-negative integer" >&2
    exit 2
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "curl is required to download public fixtures" >&2
    exit 1
fi

if ! command -v tar >/dev/null 2>&1; then
    echo "tar is required to extract public fixtures" >&2
    exit 1
fi

if ! command -v afconvert >/dev/null 2>&1; then
    echo "afconvert is required to convert public fixtures to WAV" >&2
    exit 1
fi

archive_name="$(librispeech_archive_name "$SPLIT")"
archive_url="$(librispeech_archive_url "$SPLIT")"
archive_path="$CACHE_DIR/$archive_name"
md5_path="$CACHE_DIR/librispeech-md5sum.txt"
if [[ -n "$FIXTURE_DIR_OVERRIDE" ]]; then
    fixture_dir="$FIXTURE_DIR_OVERRIDE"
else
    fixture_dir="$OUT_ROOT/librispeech-$SPLIT"
fi

if [[ -e "$fixture_dir" ]]; then
    if [[ "$FORCE" -eq 1 ]]; then
        safe_remove_generated_dir "$fixture_dir"
    else
        cat >&2 <<MSG
fixture directory already exists: $fixture_dir

Use --force to replace it, or choose a different --out-dir.
MSG
        exit 1
    fi
fi

mkdir -p "$CACHE_DIR" "$OUT_ROOT"
download_file "$(librispeech_md5_url)" "$md5_path"
expected_md5="$(expected_md5_for_archive "$md5_path" "$archive_name")"
if [[ -z "$expected_md5" ]]; then
    echo "no upstream MD5 entry found for $archive_name" >&2
    exit 1
fi

download_file "$archive_url" "$archive_path"
echo "verifying $archive_name..."
verify_md5 "$archive_path" "$expected_md5"

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/parakey-public-fetch.XXXXXX")"
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT INT TERM

echo "reading LibriSpeech transcripts..."
transcript_members="$tmpdir/transcript-members.txt"
tar -tzf "$archive_path" \
    | filter_librispeech_transcript_members "$SPLIT" \
    | LC_ALL=C sort >"$transcript_members"
if [[ ! -s "$transcript_members" ]]; then
    echo "no transcript files found in $archive_name for split $SPLIT" >&2
    exit 1
fi

mkdir -p "$tmpdir/transcripts"
tar -xzf "$archive_path" -C "$tmpdir/transcripts" -T "$transcript_members"

selected="$tmpdir/selected.tsv"
select_librispeech_entries "$tmpdir/transcripts/LibriSpeech/$SPLIT" "$SPLIT" "$START_INDEX" "$COUNT" "$selected"

audio_members="$tmpdir/audio-members.txt"
cut -f2 "$selected" >"$audio_members"
mkdir -p "$tmpdir/audio"
echo "extracting selected audio..."
tar -xzf "$archive_path" -C "$tmpdir/audio" -T "$audio_members"

mkdir -p "$fixture_dir"
manifest="$fixture_dir/manifest.tsv"
{
    printf 'clip_id\tsource\tsplit\toriginal_id\toriginal_audio\tlicense\treference\n'
} >"$manifest"

ordinal=0
while IFS=$'\t' read -r original_id original_member reference; do
    ordinal=$((ordinal + 1))
    clip_id="$(printf 'librispeech-%s-%04d-%s' "$SPLIT" "$ordinal" "$original_id")"
    source_flac="$tmpdir/audio/$original_member"
    out_wav="$fixture_dir/$clip_id.wav"
    out_ref="$fixture_dir/$clip_id.txt"

    if [[ ! -f "$source_flac" ]]; then
        echo "selected audio missing from archive extraction: $original_member" >&2
        exit 1
    fi

    echo "importing $clip_id..."
    afconvert -f WAVE -d LEF32@16000 "$source_flac" "$out_wav"
    printf '%s\n' "$reference" >"$out_ref"
    printf '%s\tLibriSpeech\t%s\t%s\t%s\tCC BY 4.0\t%s\n' \
        "$clip_id" "$SPLIT" "$original_id" "$original_member" "$reference" >>"$manifest"
done <"$selected"

cat >"$fixture_dir/README.txt" <<MSG
Generated public Parakey benchmark fixtures.

Source: LibriSpeech ASR corpus, split $SPLIT
License: CC BY 4.0
Upstream: https://www.openslr.org/12
Archive: $archive_url
Imported clips: $COUNT
Start index: $START_INDEX

These files are ignored by git. Recreate them with:
  ./fetch-public-speech-fixtures.sh --source librispeech --split $SPLIT --count $COUNT --start-index $START_INDEX
MSG

echo "fixtures: $fixture_dir"
echo "manifest: $manifest"
