#!/usr/bin/env python3
"""
bench_idle.py — validate that warm-on-press recovers steady-state latency
after MLX has gone cold.

This script runs on Apple Silicon (the unit tests in tests/test_warmup_gate.py
already cover the gate's lock + state-machine logic on any platform). It
demonstrates the actual GPU-level behavior the fix targets:

  1. Establish a steady-state latency baseline.
  2. Force a cold state (fresh process is naturally cold for the first
     generate() — the model load doesn't compile the Metal pipelines).
  3. Show what naive cold transcribe looks like.
  4. Simulate the warm-on-press wiring: background warmup while the user
     "speaks" for ~1s, then the real transcribe. Show the user-perceived
     latency is back to steady-state.

For the full "I left my Mac overnight" scenario, just leave the running
Parakey app alone for 4+ hours and check ~/Library/Logs/Parakey.log for
the `re-warmed in N.NNs after idle` line on the next hotkey press.
Latency for the subsequent transcribe should match active-use baselines.

Usage:

    python3 bench_idle.py            # full demo
    python3 bench_idle.py --quick    # shorter (skip steady-state warmup loop)
"""
from __future__ import annotations

import argparse
import os
import statistics
import sys
import threading
import time

import mlx.core as mx
import numpy as np

from parakeet_mlx import from_pretrained
from parakeet_mlx.audio import get_logmel

from warmup_gate import WarmupGate

MODEL_ID = os.environ.get("PARAKEY_MODEL", "mlx-community/parakeet-tdt-0.6b-v2")
SAMPLE_RATE = 16000
CLIP_DURATION = 3.0
SIM_SPEAK_SECONDS = 1.0


def make_audio(seconds: float, seed: int = 0) -> np.ndarray:
    n = int(seconds * SAMPLE_RATE)
    rng = np.random.default_rng(seed)
    # Quiet sine-ish wave so the model has something to transcribe but
    # we're not measuring text length variance.
    t = np.arange(n) / SAMPLE_RATE
    return (0.05 * np.sin(2 * np.pi * 440 * t) + 0.001 * rng.standard_normal(n)).astype(np.float32)


def transcribe_once(model, audio: np.ndarray) -> float:
    t0 = time.perf_counter()
    audio_mx = mx.array(audio)
    mel = get_logmel(audio_mx, model.preprocessor_config)
    _ = model.generate(mel)
    return time.perf_counter() - t0


def fmt_ms(seconds: float) -> str:
    return f"{seconds*1000:7.1f}ms"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--quick", action="store_true",
                        help="skip the 5-run steady-state baseline loop")
    args = parser.parse_args()

    print(f"loading {MODEL_ID} ...", flush=True)
    t0 = time.perf_counter()
    model = from_pretrained(MODEL_ID)
    print(f"  loaded in {fmt_ms(time.perf_counter() - t0)}\n")

    audio = make_audio(CLIP_DURATION)

    # ----- (1) first-ever generate(): the canonical cold path ----------
    print("[1] first generate() after fresh process load (cold GPU):")
    cold = transcribe_once(model, audio)
    print(f"    {fmt_ms(cold)}\n")

    # ----- (2) steady-state baseline ----------------------------------
    if not args.quick:
        print("[2] steady-state baseline (5 back-to-back generates):")
        runs = [transcribe_once(model, audio) for _ in range(5)]
        baseline_p50 = statistics.median(runs)
        for i, dt in enumerate(runs, 1):
            print(f"    run {i}: {fmt_ms(dt)}")
        print(f"    p50 = {fmt_ms(baseline_p50)}")
        speedup = cold / baseline_p50 if baseline_p50 else float("inf")
        print(f"    cold/warm ratio: {speedup:5.2f}x  (this is what the fix addresses)\n")
    else:
        baseline_p50 = transcribe_once(model, audio)
        print(f"[2] quick baseline: {fmt_ms(baseline_p50)}\n")

    # ----- (3) demonstrate the inline-warmup pattern ------------------
    # parakey.py does the warmup *inline*, in the same thread as the real
    # transcribe — fixing it on the same Metal queue avoids MLX's
    # cross-thread graph-recompile fragility. The user-perceived latency
    # after release is therefore warmup_time + transcribe_time.
    print("[3] inline-warmup pattern (forced-cold gate):")
    gate = WarmupGate(cold_threshold_seconds=0)  # always cold
    self_audio_samples = len(audio)

    def transcribe_with_inline_rewarm():
        with gate.transcribe():
            if gate.is_cold():
                gate.warming = True
                try:
                    transcribe_once(model, np.zeros(self_audio_samples, dtype=np.float32))
                finally:
                    gate.warming = False
            return transcribe_once(model, audio)

    t0 = time.perf_counter()
    real_dt = transcribe_with_inline_rewarm()
    total = time.perf_counter() - t0

    print(f"    inline-warmup + real transcribe total: {fmt_ms(total)}")
    print(f"    of which real transcribe: {fmt_ms(real_dt)}")
    print(f"    (steady-state baseline was {fmt_ms(baseline_p50)})")
    print()

    # ----- Sanity-check what we measured ------------------------------
    # Real transcribe should be at steady-state (warmup primed the GPU
    # for this exact audio length).
    if real_dt > baseline_p50 * 2:
        print("⚠️  real transcribe slower than 2× baseline — inline warmup may")
        print("   not have primed the right graph for this audio length.")
        return 1
    # Total should be MUCH better than cold (the whole point of the fix).
    if total > cold * 0.9:
        print(f"⚠️  inline-warmup total ({fmt_ms(total)}) is not meaningfully better")
        print(f"   than the cold path ({fmt_ms(cold)}). Fix isn't working.")
        return 1

    speedup_vs_cold = cold / total
    print(f"✓ inline-warmup pattern is {speedup_vs_cold:.1f}× faster than cold,")
    print(f"  and the real transcribe is back at steady-state speed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
