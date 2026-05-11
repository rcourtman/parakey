#!/usr/bin/env python3
"""
bench-py.py — Python-side companion to ``parakey-bench`` (Swift CLI).

Runs the *current* parakey-mlx pipeline against the same WAV files
the Swift bench targets, so the three backends — parakey-mlx (here),
FluidAudio's Parakeet TDT v3 (parakey-bench --backend fluid), and
Apple's DictationTranscriber (parakey-bench --backend apple) — can
be compared head-to-head in the same units.

Usage:
    .venv/bin/python experiments/swift-bench/bench-py.py \\
        --file experiments/swift-bench/test-audio/short-clean.wav \\
        --trials 5
"""
from __future__ import annotations

import argparse
import statistics
import sys
import time
from pathlib import Path

import mlx.core as mx
import numpy as np
import soundfile as sf
from parakeet_mlx import from_pretrained
from parakeet_mlx.audio import get_logmel

MODEL_ID = "mlx-community/parakeet-tdt-0.6b-v2"
SAMPLE_RATE = 16_000


def load_16k_mono(path: Path) -> np.ndarray:
    audio, sr = sf.read(str(path), dtype="float32", always_2d=False)
    if audio.ndim > 1:
        audio = audio.mean(axis=1)
    if sr != SAMPLE_RATE:
        # Lazy resample with linear interp — fine for benchmark prep.
        ratio = SAMPLE_RATE / sr
        new_len = int(len(audio) * ratio)
        x_old = np.linspace(0.0, 1.0, num=len(audio), endpoint=False, dtype=np.float32)
        x_new = np.linspace(0.0, 1.0, num=new_len, endpoint=False, dtype=np.float32)
        audio = np.interp(x_new, x_old, audio).astype(np.float32)
    return audio


def transcribe_once(model, audio: np.ndarray) -> tuple[str, float]:
    t0 = time.perf_counter()
    audio_mx = mx.array(audio)
    mel = get_logmel(audio_mx, model.preprocessor_config)
    result = model.generate(mel)[0]
    elapsed = time.perf_counter() - t0
    return result.text.strip(), elapsed


def fmt_ms(s: float) -> str:
    return f"{s * 1000:7.1f} ms"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--file", type=Path, required=True)
    parser.add_argument("--trials", type=int, default=5)
    args = parser.parse_args()

    print(f"bench-py: {args.file.name}, {args.trials} trials, backend=parakey-mlx",
          file=sys.stderr)
    audio = load_16k_mono(args.file)
    print(f"audio: {len(audio)} samples (~{len(audio)/SAMPLE_RATE:.2f} s @ 16 kHz mono)",
          file=sys.stderr)

    print("preparing parakey-mlx (parakeet-tdt-0.6b-v2 via MLX)…", file=sys.stderr)
    t_prep = time.perf_counter()
    model = from_pretrained(MODEL_ID)
    _ = transcribe_once(model, audio)  # warmup, untimed below
    print(f"  ready in {fmt_ms(time.perf_counter() - t_prep)} "
          f"(model load + 1 warmup inference)", file=sys.stderr)

    times: list[float] = []
    texts: set[str] = set()
    for i in range(args.trials):
        text, dt = transcribe_once(model, audio)
        times.append(dt)
        texts.add(text)
        print(f"    parakey-mlx trial {i+1}/{args.trials}: {fmt_ms(dt)}",
              file=sys.stderr)

    p50 = statistics.median(times)
    mn, mx_ = min(times), max(times)
    print()
    print("  parakey-mlx")
    print(f"    latency:  p50={fmt_ms(p50)}  min={fmt_ms(mn)}  max={fmt_ms(mx_)}")
    if len(texts) == 1:
        print(f"    transcript: \"{next(iter(texts))}\"")
    else:
        print(f"    transcripts ({len(texts)} distinct):")
        for t in sorted(texts):
            print(f"      • \"{t}\"")
    return 0


if __name__ == "__main__":
    sys.exit(main())
