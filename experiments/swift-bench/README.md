# swift-bench

Head-to-head ASR benchmark of production and candidate transcription backends running
against the same WAV files on the same Mac, so they can be compared
in like-for-like units.

Originally built to answer "should Parakey port from Python+MLX to
native Swift?" — the answer turned out to be yes, and the production
app now runs on FluidAudio (see [`../../swift/`](../../swift/) and
the [main README](../../README.md)). The bench stays in
`experiments/` because it's still the cleanest way to validate any
future backend / model / FluidAudio-version change without touching
the production app.

## Backends

| Tag | Stack | Where it runs |
|---|---|---|
| **`v3`** | FluidAudio Swift SDK → Parakeet TDT 0.6 B **v3** → CoreML | Apple Neural Engine |
| **`unified`** | FluidAudio Swift SDK → Parakeet Unified 0.6 B offline batch → CoreML | Apple Neural Engine |
| **`nemotron-en`** | FluidAudio Swift SDK → Nemotron Speech Streaming English 0.6 B, 1120 ms tier → CoreML | Apple Neural Engine |
| **`apple`** | `Speech.SpeechAnalyzer` + `DictationTranscriber` (built into macOS 26 Tahoe) | Apple Neural Engine |
| **`parakey-mlx`** | parakey's current path: `parakeet_mlx` → MLX → Metal | GPU |

## How to run

```sh
cd experiments/swift-bench

# 1. Generate test audio (4 clips: short-clean, medium-clean, disfluent,
#    longer-technical). Uses macOS `say` for TTS, `afconvert` for 16 kHz
#    mono Float32 WAV.
./generate-test-audio.sh

# 2. Build the Swift CLI (downloads FluidAudio dep + Parakeet v3 CoreML
#    weights on first run — model is ~600 MB, cached in
#    ~/Library/Application Support/FluidAudio/).
swift build

# 3a. Swift backends.
./.build/debug/parakey-bench --file test-audio/short-clean.wav --backend v3 --trials 5
./.build/debug/parakey-bench --file test-audio/short-clean.wav --backend unified --trials 5

# Unified uses a 250 ms candidate padding default in this benchmark.
# Set it to 0 to measure the raw model, or sweep values with
# run-tail-word-regression.sh when evaluating a future model.
./.build/debug/parakey-bench --file test-audio/short-clean.wav --backend unified --trials 5 --unified-trailing-silence-ms 0

# 3b. Python / MLX backend, same audio.
../../.venv/bin/python bench-py.py --file test-audio/short-clean.wav --trials 5
```

The Swift benchmark pins FluidAudio to the same revision as the
production app. Temporarily change `Package.swift` only when evaluating
an upstream FluidAudio bump, then restore or intentionally update both
manifests together.

`Package.resolved` is committed for the benchmark for the same reason
as the app: dependency changes should be visible in review. When
updating FluidAudio, commit the app and benchmark manifests plus both
resolved files together.

## Private real-dictation regression

TTS is useful for latency and smoke testing, but it is not a substitute
for human dictation. For local accuracy checks, put private clips under
`real-audio/` with matching `.txt` reference sidecars:

```text
real-audio/
  short-note.wav
  short-note.txt
  noisy-room.m4a
  noisy-room.txt
```

Then run:

```sh
./run-real-model-comparison.sh --trials 3
```

The comparison script normalizes audio through `afconvert`, runs v3 and
Unified against every clip, and writes ignored Markdown/TSV reports under
`real-results/` with average WER, worst WER, final-word failures, and p50
latency by backend. Transcript text, fixture filenames, and local paths are
redacted by default while WER, latency, and retention numbers remain
visible. Pass `--show-transcripts` and `--show-paths` only for local
reports you do not intend to share.

To add a local recording and reference sidecar without hand-copying files:

```sh
./add-real-dictation-fixture.sh --id short-note-001 --audio ~/Desktop/short-note.m4a --reference-file ~/Desktop/short-note.txt
```

For single-backend debugging:

```sh
./run-real-dictation-regression.sh --backend v3 --trials 5
./run-real-dictation-regression.sh --backend unified --trials 5 --unified-trailing-silence-ms 250
```

For a quick non-ASR check of argument parsing and report redaction:

```sh
./add-real-dictation-fixture.sh --self-test
./run-real-model-comparison.sh --self-test
./run-real-dictation-regression.sh --self-test
```

## Public speech regression

Private clips are the best product signal, but they cannot be shared or
reproduced by another maintainer. For a reproducible public check, fetch a
bounded LibriSpeech subset into ignored local fixtures:

```sh
./fetch-public-speech-fixtures.sh --source librispeech --split dev-clean --count 25
```

The fetcher downloads the OpenSLR archive, verifies the upstream MD5 checksum,
extracts the selected FLAC clips, converts them to 16 kHz Float32 WAV with
`afconvert`, and writes same-stem `.txt` references plus `manifest.tsv` under
`public-audio/librispeech-dev-clean/`.

Then run the production v3 regression with public-corpus reporting:

```sh
./run-real-dictation-regression.sh --input-dir public-audio/librispeech-dev-clean --out-dir public-results --backend v3 --public-corpus --show-transcripts --show-paths --trials 3
```

For candidate-model evaluation, run the same v3-vs-Unified comparison
with public-corpus reporting:

```sh
./run-public-model-comparison.sh --trials 3
```

Or run a specific candidate backend against the public fixtures:

```sh
./run-real-dictation-regression.sh --input-dir public-audio/librispeech-dev-clean --out-dir public-results --backend apple --public-corpus --show-transcripts --show-paths --trials 3
./run-real-dictation-regression.sh --input-dir public-audio/librispeech-dev-clean --out-dir public-results --backend nemotron-en --public-corpus --show-transcripts --show-paths --trials 3
```

Or fetch and compare in one command:

```sh
./run-public-model-comparison.sh --fetch --count 50 --trials 3
```

Reports land under ignored `public-results/` and include source paths and
transcripts by default because the fixture corpus is public. LibriSpeech is
read English audiobook speech under CC BY 4.0, so treat it as a stable
reproducible benchmark, not as a replacement for local push-to-talk dictation
clips.

### 2026-06-23 candidate smoke results

Five LibriSpeech dev-clean clips, three trials per clip:

| Backend | Avg WER | Worst WER | Final-word failures | Avg p50 |
|---|---:|---:|---:|---:|
| `v3` | 1.4% | 7.0% | 0 | 100.7 ms |
| `apple` | 11.7% | 18.2% | 0 | 384.8 ms |
| `nemotron-en` | 5.3% | 11.3% | 0 | 1032.7 ms |

Neither Apple SpeechAnalyzer nor Nemotron English beat Parakeet TDT v3 on
this public smoke corpus. Nemotron also emitted a CoreML shape-inference
warning on each clip, so it should remain candidate-only unless a future
FluidAudio/model revision changes those numbers.

## Tail-word retention regression

The Unified candidate model has a specific failure mode worth tracking separately:
short push-to-talk clips can lose the final word when the recording stops
close to the last phoneme. The app no longer exposes Unified, but this
script remains useful when evaluating whether a future English model should
become user-facing.

```sh
./run-tail-word-regression.sh
```

The default run synthesizes two local TTS phrases, trims natural trailing
silence, cuts 100 ms, 150 ms, and 200 ms from the end, and compares v3
against Unified with 0 ms and 250 ms trailing silence. It writes ignored
Markdown and TSV reports under `tail-results/`. The candidate threshold
requires Unified at 250 ms to retain the final word on the known
regression cases and keep max WER at or below 20% before further evaluation.

To tune the number instead of only checking the current candidate value:

```sh
./run-tail-word-regression.sh --unified-trailing-ms-list 0,100,150,200,250,300,500
```

To test a post-release capture grace experiment, sweep grace separately
from synthetic model padding. A 100 ms grace means the generated fixture
puts 100 ms of the cut tail back into the recording before inference.

```sh
./run-tail-word-regression.sh --capture-grace-ms-list 0,50,100,150 --unified-trailing-ms-list 250
```

For a quick non-ASR check of parser and threshold logic:

```sh
./run-tail-word-regression.sh --self-test
```

## Release ASR checks

Before a release that changes ASR code, FluidAudio, audio
capture, or transcription post-processing, run the release wrapper:

```sh
./run-release-asr-checks.sh
```

It runs helper self-tests, production v3 private real-dictation regressions
if `real-audio/` contains local clips, and production v3 public speech
regressions if `public-audio/librispeech-dev-clean/` has been fetched.
If you want the release check to fail when no local corpus is available:

```sh
./run-release-asr-checks.sh --require-real-audio
./run-release-asr-checks.sh --require-public-audio
```

To also run Unified candidate tail-word and v3-vs-Unified comparisons:

```sh
./run-release-asr-checks.sh --include-candidate-models
```

## Power measurement

Latency is already below the threshold where another few milliseconds are
likely to matter. To compare energy impact on the same Mac, run:

```sh
sudo -v
./bench-power.sh --file test-audio/medium-clean.wav --backend v3 --trials 20
```

This samples `cpu_power,gpu_power,ane_power` with `powermetrics` while
`parakey-bench` runs, then writes a Markdown summary plus raw logs under
`power-results/`. Transcript text, fixture filenames, and local paths are
redacted by default; pass `--show-transcripts` or `--show-paths` only for
local reports you do not intend to share. `powermetrics` values are
estimates, so use them only for same-machine comparisons across backends,
dependency versions, or model changes.

For a quick no-sudo check of argument parsing, path redaction, and report
generation:

```sh
./bench-power.sh --self-test
```

## Results

Mac mini M4, 10 cores, 16 GB, macOS 26.4.1, Xcode/Swift 6.3.
5 trials per backend per clip, p50 reported below. First inference
(after model load) excluded from each row's p50 — that's the warmup.

| Clip | Duration | `fluid` (ANE) | `parakey-mlx` (GPU) | Speed ratio |
|---|---:|---:|---:|---:|
| `short-clean` | 2.50 s | **92.4 ms** | 145.4 ms | 1.57× |
| `medium-clean` | 3.99 s | **96.1 ms** | 176.3 ms | 1.83× |
| `disfluent` | 5.31 s | **94.1 ms** | 185.9 ms | 1.97× |
| `longer-technical` | 9.49 s | **152.4 ms** | 300.9 ms | 1.97× |

**Key findings:**

- **`fluid` (ANE) is consistently ~1.5–2× faster than `parakey-mlx`
  (GPU)** — the gap widens with clip length, as expected for an
  encoder-bound workload.
- **Both backends produce essentially identical transcripts.** They
  even agreed on the TTS-induced quirks ("push-to-tock" instead of
  "push-to-talk", "Max" instead of "Macs") — neither backend has an
  accuracy advantage on this material. Real human dictation would
  likely be slightly more forgiving to both.
- **Both backends are well below the human-perception threshold for
  "instant".** 90 ms vs 180 ms for a typical 3-second clip is a
  measurable improvement but not a felt one — both finish before the
  user has finished releasing the dictation key.
- **The likely real win for `fluid` is power, not latency.** ANE
  draws materially less power than GPU. Use `bench-power.sh` for
  same-machine power comparisons when evaluating backend or dependency
  changes.

**Transcript samples (best of 5 per backend):**

| Clip | Reference (TTS input) | Both backends |
|---|---|---|
| `short-clean` | "The quick brown fox jumps over the lazy dog." | ✓ exact |
| `medium-clean` | "Parakey is a lightweight push-to-talk dictation app for Apple Silicon Macs." | "push-to-tock", "Max" (TTS artifacts) |
| `disfluent` | "So, um, I was going to send, like, maybe a quick note about the thing we discussed earlier, you know." | ✓ exact, fillers preserved |
| `longer-technical` | "When you press the dictation key, the audio buffer is captured at sixteen kilohertz, run through Parakeet's encoder on the neural engine, and the resulting tokens are pasted at the cursor location." | "16 kHz" (correctly normalised), `fluid` lowercases "parakeet", `parakey-mlx` capitalises |

### Re-run post-v0.14.5 FluidAudio pin + Apple SpeechAnalyzer unblock

Mac mini M4, 10 cores, 16 GB, macOS 26.4.1, Swift 6.3. 5 trials per
backend per clip, p50 reported below. Apple backend now runs
end-to-end after embedding a minimal `Info.plist` into the executable
and using the fresh-analyzer-per-call pattern (see "Apple backend
notes" below).

| Clip | Duration | `fluid` (ANE) | `apple-SpeechAnalyzer` | Apple/Fluid |
|---|---:|---:|---:|---:|
| `short-clean` | 2.50 s | **66.7 ms** | 173.8 ms | 2.6x slower |
| `medium-clean` | 4.29 s | **84.0 ms** | 368.3 ms | 4.4x slower |
| `disfluent` | 6.53 s | **80.6 ms** | 240.2 ms | 3.0x slower |
| `longer-technical` | 10.94 s | **119.8 ms** | 408.5 ms | 3.4x slower |

**Key findings (`fluid` vs `apple`):**

- **`fluid` is 2.6-4.4x faster than `apple` on this Mac**, across every
  clip. The gap widens with clip length.
- **`apple` drops punctuation** ("So I was going to send like maybe a
  quick note about the thing we discussed earlier you know") whereas
  `fluid` produces commas and periods.
- **Both have minor word-segmentation errors** on "Parakey"
  ("push-to-tock" for `fluid`, "Para key" for `apple`) and
  "Macs"->"Max" (TTS artifact, both backends).
- **Apple's first-time model is also downloaded**, not preinstalled
  for every user — the "no download" pitch for SpeechAnalyzer applies
  only on machines where the en-US dictation locale was already
  fetched for system Dictation. The download is smaller than
  FluidAudio's 600 MB but non-zero.

**`apple-SpeechAnalyzer` transcripts:**

| Clip | `apple` transcript |
|---|---|
| `short-clean` | "The quick brown fox jumps over the lazy dog" (no trailing period) |
| `medium-clean` | "Para key is a lightweight push to talk dictation app for Apple Silicon Max" ("Para key", no punctuation) |
| `disfluent` | "So I was going to send like maybe a quick note about the thing we discussed earlier you know" (fillers preserved, no punctuation) |
| `longer-technical` | "When you press the dictation key the audio buffer is captured at 16 kHz run through parakeets encoder on the neural engine and the resulting tokens are pasted at the cursor location" (no punctuation) |

## Apple backend notes

Once-blocking gaps that have been resolved:

1. **Info.plist** — Embedded into the executable via a linker
   `-sectcreate __TEXT __info_plist` flag (see `Package.swift`).
   `NSSpeechRecognitionUsageDescription` and `CFBundleIdentifier` are
   what Speech.framework checks; without them
   `DictationTranscriber.prepare` traps with exit 133 / SIGTRAP.
2. **Audio format** — `DictationTranscriber` rejects Float32 with
   "Audio sample data must be 16-bit signed integers". The bench now
   converts the load-time float buffer to Int16 in `makePCMBuffer`.
3. **Analyzer lifecycle** — `analyzer.finalizeAndFinishThroughEndOfInput()`
   puts the analyzer into a terminal state; subsequent transcribe calls
   on the same instance produce empty output instantly. The bench now
   recreates analyzer + transcriber per call (matches Parakey's
   push-to-talk pattern: one utterance, one session).
4. **Results draining** — Reading `transcriber.results` sequentially
   after finalize loses events. The bench drains results in a child
   task started *before* `analyzer.start(...)`, mirroring
   FluidInference's `swift-scribe` reference app.
5. **isFinal semantics** — For a single-shot push-to-talk utterance,
   `DictationTranscriber` emits the entire transcript as a single
   `isFinal=false` (volatile) event. The "final" text the user sees is
   therefore `finalized + last-volatile`, not just `finalized`.

### TTS audio is not real dictation

`say` produces clean, expressionless audio with no breathing, no
overlapping noise, no real prosody. Latency results are realistic;
accuracy numbers measure how the engines handle synthetic speech,
which both engines are slightly worse at than the real thing they
were trained on. To get real accuracy numbers, drop your own
recordings into `test-audio/` — the bench loads any 16 kHz mono WAV
by filename.

### Power measurement

The core bench measures compute latency. Use `bench-power.sh` when the
question is battery impact or ANE/GPU power draw. `powermetrics` is noisy,
so compare runs on the same Mac, OS build, power source, and thermal state.

## What this benchmark drove

The original questions and where they landed:

- **"Is ANE meaningfully faster than MLX for our workload?"** —
  Yes, consistently 1.5–2× depending on clip length.

- **"Would users perceive the difference?"** — At the bench's
  granularity, no; both backends finish in well under 200 ms for a
  3-second clip. But the ANE path **does** finish before the user
  has released the dictation key on typical clips, which makes
  end-to-end "press → text" feel measurably snappier in real use.

- **"Is it worth porting Parakey to Swift to capture the win?"** —
  Yes. Beyond the latency win, going native removed the embedded
  Python interpreter (149 MB → 2.2 MB zip), shrank the hardened-
  runtime entitlement set from six keys to two, and sidestepped the
  whole class of TCC/codesigning bugs that plagued the
  PyInstaller-bundled `.app`. The port shipped as Parakey 0.2.0.

## Future use

The bench is kept as the "is the inference path still healthy?"
sanity check. Re-run it whenever:

- FluidAudio publishes a new release and you want to confirm the
  latency curve hasn't regressed.
- Apple ships a new SpeechAnalyzer revision (or someone unblocks
  the entitlements gap so the `apple` backend runs end-to-end).
- A future Parakeet / MLX / WhisperKit model arrives and you want
  to evaluate it against the current numbers.
- A latency-equivalent change might still affect battery life; use
  `bench-power.sh` to compare power on the same machine.
