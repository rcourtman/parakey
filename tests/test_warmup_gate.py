"""
Tests for warmup_gate.WarmupGate.

Run from the repo root with:

    python3 -m unittest tests.test_warmup_gate

These cover the concurrency-sensitive logic that re-warms the model after
the app has been idle for hours. We DO NOT exercise MLX or the real model
here — the point is to validate the lock + gating state machine in
isolation so failures show up on CI (Linux, no GPU) instead of mid-release.
"""
from __future__ import annotations

import os
import sys
import threading
import time
import unittest

# Make ``warmup_gate`` importable when running this file directly or
# via `python -m unittest tests.test_warmup_gate` from the repo root.
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from warmup_gate import WarmupGate


class FakeClock:
    """Manually-advanced clock so tests don't depend on real wall time."""

    def __init__(self, start: float = 1000.0) -> None:
        self.t = start

    def __call__(self) -> float:
        return self.t

    def advance(self, seconds: float) -> None:
        self.t += seconds


# ----------------------------------------------------------------------
# is_cold / time-based gating
# ----------------------------------------------------------------------

class IsColdTests(unittest.TestCase):
    def test_fresh_gate_is_cold(self):
        # last_inference_at defaults to 0.0 — anything > threshold is cold.
        gate = WarmupGate(cold_threshold_seconds=10, clock=FakeClock(1000.0))
        self.assertTrue(gate.is_cold())

    def test_just_warmed_is_not_cold(self):
        clock = FakeClock(1000.0)
        gate = WarmupGate(cold_threshold_seconds=10, clock=clock)
        gate.last_inference_at = clock()
        self.assertFalse(gate.is_cold())

    def test_advancing_clock_past_threshold_makes_cold(self):
        clock = FakeClock(1000.0)
        gate = WarmupGate(cold_threshold_seconds=10, clock=clock)
        gate.last_inference_at = clock()
        clock.advance(9.999)
        self.assertFalse(gate.is_cold())
        clock.advance(0.002)  # now t-last = 10.001
        self.assertTrue(gate.is_cold())

    def test_zero_threshold_is_always_cold(self):
        clock = FakeClock(1000.0)
        gate = WarmupGate(cold_threshold_seconds=0, clock=clock)
        gate.last_inference_at = clock()
        self.assertTrue(gate.is_cold())

    def test_negative_threshold_rejected(self):
        with self.assertRaises(ValueError):
            WarmupGate(cold_threshold_seconds=-1)


# ----------------------------------------------------------------------
# try_begin_warmup single-flight behaviour
# ----------------------------------------------------------------------

class TryBeginWarmupTests(unittest.TestCase):
    def test_warm_gate_refuses(self):
        clock = FakeClock(1000.0)
        gate = WarmupGate(cold_threshold_seconds=10, clock=clock)
        gate.last_inference_at = clock()  # warm
        self.assertFalse(gate.try_begin_warmup())
        self.assertFalse(gate.warming)

    def test_cold_gate_accepts_then_blocks_concurrent_caller(self):
        gate = WarmupGate(cold_threshold_seconds=10, clock=FakeClock())
        # First caller wins.
        self.assertTrue(gate.try_begin_warmup())
        self.assertTrue(gate.warming)
        # Second caller is locked out, even though gate is still cold.
        self.assertFalse(gate.try_begin_warmup())
        # State must not be corrupted by the failed second attempt.
        self.assertTrue(gate.warming)
        gate.end_warmup()
        self.assertFalse(gate.warming)

    def test_end_warmup_resets_timestamp_and_unlocks(self):
        clock = FakeClock(1000.0)
        gate = WarmupGate(cold_threshold_seconds=10, clock=clock)
        self.assertTrue(gate.try_begin_warmup())
        clock.advance(0.5)  # simulate warmup taking 500 ms
        gate.end_warmup()
        # After end_warmup, last_inference_at should be the post-warmup
        # clock value — the gate is no longer cold.
        self.assertEqual(gate.last_inference_at, 1000.5)
        self.assertFalse(gate.is_cold())
        # Lock must be released — the next cold cycle can warm again.
        clock.advance(20)
        self.assertTrue(gate.try_begin_warmup())
        gate.end_warmup()

    def test_warmup_failure_path_still_releases_lock(self):
        """Caller's job to use try/finally — verify end_warmup works even
        if no real inference happened between begin and end."""
        gate = WarmupGate(cold_threshold_seconds=10, clock=FakeClock())
        self.assertTrue(gate.try_begin_warmup())
        try:
            raise RuntimeError("simulated MLX OOM")
        except RuntimeError:
            gate.end_warmup()
        self.assertFalse(gate.warming)
        # Gate should be usable again (after enough time has passed).
        gate._clock = FakeClock(2000.0)  # jump forward past threshold
        self.assertTrue(gate.try_begin_warmup())
        gate.end_warmup()


# ----------------------------------------------------------------------
# transcribe() context manager — serialization
# ----------------------------------------------------------------------

class TranscribeContextTests(unittest.TestCase):
    def test_transcribe_stamps_timestamp_on_happy_path(self):
        clock = FakeClock(1000.0)
        gate = WarmupGate(cold_threshold_seconds=10, clock=clock)
        with gate.transcribe():
            clock.advance(0.3)
        self.assertEqual(gate.last_inference_at, 1000.3)
        self.assertFalse(gate.is_cold())

    def test_transcribe_releases_lock_on_exception(self):
        gate = WarmupGate(cold_threshold_seconds=10, clock=FakeClock())
        with self.assertRaises(ValueError):
            with gate.transcribe():
                raise ValueError("boom")
        # Lock released → next transcribe must not deadlock. Use a thread
        # with a short timeout to guard against an actual deadlock bug.
        completed = threading.Event()

        def second_transcribe():
            with gate.transcribe():
                pass
            completed.set()

        t = threading.Thread(target=second_transcribe, daemon=True)
        t.start()
        t.join(timeout=1.0)
        self.assertTrue(completed.is_set(), "lock not released on exception")

    def test_transcribe_does_not_stamp_timestamp_on_exception(self):
        """If the GPU state is uncertain after a transcribe error, we'd
        rather treat the next press as cold than skip a warmup we need."""
        clock = FakeClock(1000.0)
        gate = WarmupGate(cold_threshold_seconds=10, clock=clock)
        try:
            with gate.transcribe():
                raise RuntimeError("simulated transcribe fail")
        except RuntimeError:
            pass
        # last_inference_at must NOT have been advanced.
        self.assertEqual(gate.last_inference_at, 0.0)
        # And the gate must still report cold.
        self.assertTrue(gate.is_cold())


# ----------------------------------------------------------------------
# Real-threading interactions: warmup vs transcribe
# ----------------------------------------------------------------------

class WarmupVsTranscribeTests(unittest.TestCase):
    """These use real threads and a real ``threading.Lock`` underneath the
    gate — that's where the actual concurrency bugs would hide."""

    def test_transcribe_waits_for_in_flight_warmup(self):
        """If a warmup is mid-flight, a transcribe must block until it
        finishes. This is the whole point of the inference lock."""
        gate = WarmupGate(cold_threshold_seconds=10, clock=FakeClock())
        order = []
        warmup_started = threading.Event()
        warmup_can_finish = threading.Event()

        def warmup():
            self.assertTrue(gate.try_begin_warmup())
            try:
                order.append("warmup_start")
                warmup_started.set()
                warmup_can_finish.wait(timeout=2.0)
                order.append("warmup_end")
            finally:
                gate.end_warmup()

        def transcribe():
            warmup_started.wait(timeout=2.0)
            with gate.transcribe():
                order.append("transcribe")

        wt = threading.Thread(target=warmup, daemon=True)
        tt = threading.Thread(target=transcribe, daemon=True)
        wt.start()
        tt.start()

        warmup_started.wait(timeout=2.0)
        # Give the transcribe thread a moment to TRY to acquire and block.
        time.sleep(0.05)
        # Transcribe must be parked, waiting for the warmup to finish.
        self.assertEqual(order, ["warmup_start"])

        warmup_can_finish.set()
        wt.join(timeout=2.0)
        tt.join(timeout=2.0)

        self.assertEqual(order, ["warmup_start", "warmup_end", "transcribe"])

    def test_warmup_loses_to_in_flight_transcribe(self):
        """If a transcribe is already on the GPU, a warmup attempt must
        bail immediately — non-blocking. Otherwise the press handler thread
        could pile up behind a long transcribe."""
        gate = WarmupGate(cold_threshold_seconds=10, clock=FakeClock())
        transcribe_started = threading.Event()
        transcribe_can_finish = threading.Event()

        def transcribe():
            with gate.transcribe():
                transcribe_started.set()
                transcribe_can_finish.wait(timeout=2.0)

        tt = threading.Thread(target=transcribe, daemon=True)
        tt.start()
        transcribe_started.wait(timeout=2.0)

        # Warmup attempt now must NOT block. is_cold is True (last_inference
        # is 0.0), so the only thing stopping it is the held lock.
        t0 = time.monotonic()
        result = gate.try_begin_warmup()
        elapsed = time.monotonic() - t0

        self.assertFalse(result)
        self.assertLess(elapsed, 0.05, "try_begin_warmup blocked when it should have bailed")
        self.assertFalse(gate.warming)

        transcribe_can_finish.set()
        tt.join(timeout=2.0)


if __name__ == "__main__":
    unittest.main()
