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

    # ----- (3) demonstrate the parallel-warmup-during-speak pattern ----
    # The real parakey.py uses an InferenceWorker that owns the model
    # and runs every generate() on a single dedicated thread. On press
    # (when the model is cold) we enqueue a warmup; on release we enqueue
    # the real transcribe. The worker's FIFO queue serializes them, so
    # the transcribe waits for the warmup to finish — but because the
    # user is speaking during that whole window, by release time the
    # warmup is usually already done and the transcribe runs immediately.
    print("[3] parallel-warmup-during-speak pattern (forced-cold gate):")
    print("    spawning worker (will load its own model on its own thread)...")
    # The worker MUST load the model itself — that's the whole point of
    # the architecture. Reusing the bench's main-thread-loaded model
    # would re-trigger the very bug we're trying to test the fix for.
    import inference_worker as iwmod
    iwmod.configure(mx, from_pretrained, get_logmel, np)
    from inference_worker import InferenceWorker
    worker = InferenceWorker(
        MODEL_ID,
        sample_rate=16000,
        warmup_seconds=0.5,
        log_cb=lambda _msg: None,
    )
    worker.start()
    if not worker.wait_ready(timeout=120):
        print("⚠️  worker never reached ready"); worker.shutdown(); return 1
    if worker.error:
        print(f"⚠️  worker init failed: {worker.error}"); worker.shutdown(); return 1

    speak_seconds = SIM_SPEAK_SECONDS
    print(f"    user 'speaks' for: {speak_seconds*1000:7.1f}ms")

    # On press: kick off the parallel warmup.
    user_t0 = time.perf_counter()
    worker.submit_warmup(audio_samples=int(speak_seconds * 16000))

    # User speaks (parallel with warmup running on the worker).
    time.sleep(speak_seconds)
    release_t = time.perf_counter()

    # On release: submit the real transcribe.
    done = threading.Event()
    result: dict = {}
    def on_done(text):
        result["dt_complete"] = time.perf_counter()
        result["text"] = text
        done.set()
    worker.submit_transcribe(audio, on_done)
    done.wait()

    user_total = result["dt_complete"] - user_t0
    after_release = result["dt_complete"] - release_t
    worker.shutdown()

    print(f"    user-perceived total (press → text):   {fmt_ms(user_total)}")
    print(f"    of which after release (release → text): {fmt_ms(after_release)}")
    print(f"    (steady-state baseline was {fmt_ms(baseline_p50)})")
    print()

    # ----- Sanity-check what we measured ------------------------------
    # The whole win is: after release, latency should be ~baseline,
    # not warmup+baseline, because the warmup ran during speak.
    if after_release > baseline_p50 * 2.5:
        print(f"⚠️  after-release latency ({fmt_ms(after_release)}) is more than 2.5×")
        print(f"   baseline ({fmt_ms(baseline_p50)}). The warmup may not be running")
        print(f"   in parallel with speak as intended.")
        return 1

    speedup_vs_cold = cold / after_release
    print(f"✓ parallel-warmup pattern is {speedup_vs_cold:.1f}× faster than cold path,")
    print(f"  and after-release latency is at steady-state speed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
