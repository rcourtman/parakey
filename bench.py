#!/usr/bin/env python3
"""
bench.py — profile parakey's transcription pipeline.

Compares the path-based pipeline (write WAV → ffmpeg → mlx) against a
direct numpy → mlx path that bypasses both the WAV round-trip and ffmpeg.
"""
from __future__ import annotations

import os
import statistics
import sys
import tempfile
import time

import mlx.core as mx
import numpy as np
import soundfile as sf

from parakeet_mlx import from_pretrained
from parakeet_mlx.audio import get_logmel

MODEL_ID = os.environ.get("PARAKEY_MODEL", "mlx-community/parakeet-tdt-0.6b-v2")
SAMPLE_RATE = 16000
DURATIONS = [1.0, 3.0, 10.0, 30.0]
RUNS_PER_DURATION = 5
WARMUP_RUNS = 2


def fmt_ms(values):
    if not values:
        return "n/a"
    p50 = statistics.median(values) * 1000
    mn = min(values) * 1000
    mx_ = max(values) * 1000
    return f"p50={p50:6.1f}ms  min={mn:6.1f}ms  max={mx_:6.1f}ms"


def make_audio(seconds: float, seed: int) -> np.ndarray:
    n = int(seconds * SAMPLE_RATE)
    rng = np.random.default_rng(seed)
    return (rng.standard_normal(n) * 0.05).astype(np.float32)


def time_path_pipeline(model, audio: np.ndarray) -> dict[str, float]:
    """Current production path: tempfile + sf.write + model.transcribe(path)."""
    t0 = time.perf_counter()
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
        wav_path = f.name
    t1 = time.perf_counter()
    try:
        sf.write(wav_path, audio, SAMPLE_RATE)
        t2 = time.perf_counter()
        result = model.transcribe(wav_path)
        # force materialization
        _ = result.text
        t3 = time.perf_counter()
    finally:
        try:
            os.unlink(wav_path)
        except OSError:
            pass
    return {
        "tmpfile":   t1 - t0,
        "wav_write": t2 - t1,
        "transcribe": t3 - t2,
        "total":     t3 - t0,
    }


def time_direct_pipeline(model, audio: np.ndarray) -> dict[str, float]:
    """Bypass: numpy → mx.array → get_logmel → model.generate."""
    t0 = time.perf_counter()
    audio_mx = mx.array(audio)
    mx.eval(audio_mx)
    t1 = time.perf_counter()
    mel = get_logmel(audio_mx, model.preprocessor_config)
    mx.eval(mel)
    t2 = time.perf_counter()
    result = model.generate(mel)[0]
    _ = result.text
    t3 = time.perf_counter()
    return {
        "to_mx":     t1 - t0,
        "logmel":    t2 - t1,
        "generate":  t3 - t2,
        "total":     t3 - t0,
    }


def main() -> int:
    print(f"loading {MODEL_ID} ...", flush=True)
    t0 = time.perf_counter()
    model = from_pretrained(MODEL_ID)
    print(f"  loaded in {(time.perf_counter()-t0)*1000:.0f}ms\n")

    print("warmup ...", flush=True)
    warm = make_audio(0.5, seed=0)
    for _ in range(WARMUP_RUNS):
        time_path_pipeline(model, warm)
        time_direct_pipeline(model, warm)
    print("  done\n")

    print(f"{'duration':>10}  {'path total':>12}  {'direct total':>14}  {'speedup':>8}")
    print(f"{'-'*10:>10}  {'-'*12:>12}  {'-'*14:>14}  {'-'*8:>8}")

    detail_collect = {}
    for dur in DURATIONS:
        audio = make_audio(dur, seed=int(dur * 100))
        path_runs = [time_path_pipeline(model, audio) for _ in range(RUNS_PER_DURATION)]
        direct_runs = [time_direct_pipeline(model, audio) for _ in range(RUNS_PER_DURATION)]

        path_p50 = statistics.median(r["total"] for r in path_runs) * 1000
        direct_p50 = statistics.median(r["total"] for r in direct_runs) * 1000
        speedup = path_p50 / direct_p50 if direct_p50 else float("inf")

        print(f"{dur:>9.1f}s  {path_p50:>10.1f}ms  {direct_p50:>12.1f}ms  {speedup:>7.2f}x")
        detail_collect[dur] = (path_runs, direct_runs)

    print()
    print(f"=== Stage breakdown (3.0s clip, {RUNS_PER_DURATION} runs each) ===")
    path_runs, direct_runs = detail_collect[3.0]
    print("path-based pipeline:")
    for k in ("tmpfile", "wav_write", "transcribe", "total"):
        vals = [r[k] for r in path_runs]
        print(f"  {k:>11}: {fmt_ms(vals)}")
    print("direct numpy → mx pipeline:")
    for k in ("to_mx", "logmel", "generate", "total"):
        vals = [r[k] for r in direct_runs]
        print(f"  {k:>11}: {fmt_ms(vals)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
