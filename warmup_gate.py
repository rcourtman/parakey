"""
warmup_gate.py — manages re-warming the Parakeet-MLX model after long idles.

When the app sits idle for hours, MLX evicts compiled-shader and tensor
caches; the first inference after that gap can be ~8× slower than the
steady-state. WarmupGate encapsulates the three pieces that fix it:

1. A *cold check* — has it been long enough since the last inference that
   we should re-warm?
2. A *single-flight latch* — if two presses race, only one warmup runs.
3. A *serialization lock* — the real transcribe waits for any in-flight
   warmup so the GPU only runs one `model.generate()` at a time.

The class deliberately knows nothing about MLX, the model, or rumps — it's
a pure state machine. That makes it trivial to unit-test on any platform
(including Linux CI), without importing the heavy GPU stack.

Usage (see parakey.py for the real wiring):

    gate = WarmupGate(cold_threshold_seconds=300)

    # On hotkey press, in a background thread:
    if gate.try_begin_warmup():
        try:
            run_dummy_inference()
        finally:
            gate.end_warmup()

    # On hotkey release, in the transcribe thread:
    with gate.transcribe():
        run_real_inference()

    # Anywhere — read for the menu status:
    if gate.warming: show("Warming up…")
"""
from __future__ import annotations

import contextlib
import threading
import time
from typing import Callable, Iterator


class WarmupGate:
    """State machine for cold-after-idle re-warmup."""

    def __init__(
        self,
        cold_threshold_seconds: float,
        *,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        if cold_threshold_seconds < 0:
            raise ValueError("cold_threshold_seconds must be non-negative")
        self._cold = cold_threshold_seconds
        self._clock = clock
        self._lock = threading.Lock()
        # Public, atomic flags — safe to read without locking. CPython
        # guarantees attribute reads/writes are atomic for these types.
        self.warming: bool = False
        # 0.0 means "never warmed" → first check treats us as cold. The
        # caller is expected to overwrite this immediately after the
        # initial startup warmup completes.
        self.last_inference_at: float = 0.0

    # ---- Cold-check ----------------------------------------------------

    def is_cold(self) -> bool:
        """True if enough time has elapsed since the last inference that we
        should fire a re-warm before the next real transcribe."""
        return (self._clock() - self.last_inference_at) >= self._cold

    # ---- Single-flight warmup ------------------------------------------

    def try_begin_warmup(self) -> bool:
        """Reserve the GPU for a warmup.

        Returns True if the caller should now run a dummy inference and
        then call ``end_warmup()``. Returns False if either (a) the model
        is still warm, or (b) another caller — warmup or transcribe — is
        already holding the inference lock.

        Never blocks. Safe to call from any thread.
        """
        if not self.is_cold():
            return False
        if not self._lock.acquire(blocking=False):
            return False
        # Setting the flag *after* lock acquisition ensures callers never
        # see warming=True without the lock actually held.
        self.warming = True
        return True

    def end_warmup(self) -> None:
        """Release the warmup lock and stamp ``last_inference_at``. Must
        be called exactly once per successful ``try_begin_warmup() -> True``,
        including on error paths (use try/finally)."""
        self.last_inference_at = self._clock()
        self.warming = False
        self._lock.release()

    # ---- Transcribe serialization --------------------------------------

    @contextlib.contextmanager
    def transcribe(self) -> Iterator[None]:
        """Block until any in-flight warmup completes, then run the real
        inference inside the lock. ``last_inference_at`` is stamped on
        successful exit (i.e. no exception inside the ``with`` block).

        Usage:
            with gate.transcribe():
                model.generate(mel)
        """
        self._lock.acquire()
        try:
            yield
            # Only update the timestamp on the happy path. If the
            # transcribe raised, the GPU state is uncertain and we'd
            # rather err on the side of treating the next press as
            # cold than skip a warmup we needed.
            self.last_inference_at = self._clock()
        finally:
            self._lock.release()
