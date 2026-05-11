# swift-bench

Head-to-head ASR benchmark of three transcription backends running
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
| **`fluid`** | FluidAudio Swift SDK → Parakeet TDT 0.6 B **v3** → CoreML | Apple Neural Engine |
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

# 3a. Swift backends (fluid + apple — apple is currently blocked, see
#     "Known limitations" below).
./.build/debug/parakey-bench --file test-audio/short-clean.wav --backend fluid --trials 5

# 3b. Python / MLX backend, same audio.
../../.venv/bin/python bench-py.py --file test-audio/short-clean.wav --trials 5
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
  draws materially less power than GPU. This benchmark doesn't
  quantify that — `powermetrics` integration is a future addition.

**Transcript samples (best of 5 per backend):**

| Clip | Reference (TTS input) | Both backends |
|---|---|---|
| `short-clean` | "The quick brown fox jumps over the lazy dog." | ✓ exact |
| `medium-clean` | "Parakey is a lightweight push-to-talk dictation app for Apple Silicon Macs." | "push-to-tock", "Max" (TTS artifacts) |
| `disfluent` | "So, um, I was going to send, like, maybe a quick note about the thing we discussed earlier, you know." | ✓ exact, fillers preserved |
| `longer-technical` | "When you press the dictation key, the audio buffer is captured at sixteen kilohertz, run through Parakeet's encoder on the neural engine, and the resulting tokens are pasted at the cursor location." | "16 kHz" (correctly normalised), `fluid` lowercases "parakeet", `parakey-mlx` capitalises |

## Known limitations

### Apple `SpeechAnalyzer` backend currently blocked

The `apple` backend wiring is in `main.swift`, but the bench traps
inside `Speech.framework` during `DictationTranscriber` preparation
(exit 133 / SIGTRAP). Most likely cause is missing
`NSSpeechRecognitionUsageDescription` in Info.plist and/or a
Speech-Recognition privacy entitlement — SwiftPM-built CLI
executables don't get an Info.plist by default.

Two ways to fix when we want this data:

1. Embed an Info.plist into the executable via linker flag
   (`-Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist
   -Xlinker $(realpath Info.plist)`).
2. Wrap the executable in a minimal `.app` bundle with proper
   Info.plist + signing.

Until that's done, we're benchmarking `fluid` vs `parakey-mlx` only.
Apple's SpeechAnalyzer accuracy / latency numbers on the same audio
are a missing data point.

### TTS audio is not real dictation

`say` produces clean, expressionless audio with no breathing, no
overlapping noise, no real prosody. Latency results are realistic;
accuracy numbers measure how the engines handle synthetic speech,
which both engines are slightly worse at than the real thing they
were trained on. To get real accuracy numbers, drop your own
recordings into `test-audio/` — the bench loads any 16 kHz mono WAV
by filename.

### Power not measured (yet)

We measure compute latency, not energy. The latency gap is real but
already below human perception. The argument for `fluid` rests
mostly on power-per-inference, which we haven't quantified. A
`powermetrics`-based companion script could capture that; it's not
done.

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

`powermetrics` integration would let it answer the
power-on-battery question, which the latency numbers leave
unanswered. Not done.
