#!/usr/bin/env bash
# generate-test-audio.sh — synthesise the same set of test clips both
# backends will run against. Uses macOS's built-in `say` for the TTS
# and `afconvert` to land at 16 kHz / mono / Float32 WAV, which is
# what FluidAudio's AsrManager and parakey-mlx both want.
#
# Caveat: TTS audio is "too clean" — no real prosody, no breath, no
# overlapping noise — so the accuracy column from this run is a
# weaker signal than testing against real recordings would be. Good
# for latency comparisons, good enough for sniffing relative
# transcription quality, but not a replacement for a real test set.
# Drop your own recordings into test-audio/ and the bench will pick
# them up by filename.

set -euo pipefail
cd "$(dirname "$0")"

VOICE="Samantha"
OUTDIR="test-audio"
mkdir -p "$OUTDIR"

declare -a CLIPS=(
    "short-clean|The quick brown fox jumps over the lazy dog."
    "medium-clean|Parakey is a lightweight push-to-talk dictation app for Apple Silicon Macs."
    "disfluent|So, um, I was going to send, like, maybe a quick note about the thing we discussed earlier, you know."
    "longer-technical|When you press the dictation key, the audio buffer is captured at sixteen kilohertz, run through Parakeet's encoder on the neural engine, and the resulting tokens are pasted at the cursor location."
)

for entry in "${CLIPS[@]}"; do
    name="${entry%%|*}"
    text="${entry#*|}"
    aiff="$OUTDIR/$name.aiff"
    wav="$OUTDIR/$name.wav"
    echo "→ $name.wav"
    say -v "$VOICE" -o "$aiff" "$text"
    afconvert -f WAVE -d LEF32@16000 "$aiff" "$wav"
    rm -f "$aiff"
done

echo
echo "Generated:"
ls -la "$OUTDIR"/*.wav
