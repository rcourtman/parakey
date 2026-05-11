"""
inference_worker.py — single dedicated thread that owns the Parakeet-MLX
model and runs every ``model.generate()`` call.

## Why a dedicated thread?

MLX (>= 0.31.2) is strict about thread affinity: a model loaded on one
thread can't be used safely from another. Streams are thread-local, and
once a model has compiled a graph on its loading thread, a different
thread calling ``generate()`` may raise

    RuntimeError: There is no Stream(gpu, 0) in current thread.

The failure mode is shape-dependent — it only fires when the new
thread's input forces a graph recompile (e.g. shorter audio than the
prior call) — but in production that's exactly what a re-warmup looks
like after a long user transcribe.

Apple's own ``mlx-lm`` hit the same wall and landed the same fix
(`ml-explore/mlx-lm#1090 <https://github.com/ml-explore/mlx-lm/pull/1090>`_):
load the model on the inference thread, give that thread its own
thread-local stream, and route every ``generate()`` through it.

## What this gives us

* Background warmup that actually works — no silent ``Stream(gpu, 0)``
  failures. Re-warmup can run in parallel with the user speaking, so
  by release time the GPU is hot and the real transcribe is at
  steady-state speed.
* Natural serialization — the worker's task queue runs jobs FIFO, so
  there's no explicit lock around ``generate()`` anywhere.
* Single source of truth for "is the model ready" via ``wait_ready()``.

This module deliberately has no rumps / pynput / sounddevice imports
so it can be imported and exercised on plain Linux CI runners — the
tests stub MLX out and verify the queue + lifecycle state machine.
"""
from __future__ import annotations

import queue
import threading
import time
from typing import Any, Callable, Optional


# Module-level so tests can monkey-patch them without touching real MLX.
# parakey.py imports the real MLX module and overwrites these at startup.
_mx: Any = None
_from_pretrained: Any = None
_get_logmel: Any = None
_np: Any = None


def configure(mx, from_pretrained, get_logmel, np) -> None:
    """Inject the real MLX / parakeet_mlx / numpy modules. Called once
    from parakey.py at import time. Lets tests replace these with mocks."""
    global _mx, _from_pretrained, _get_logmel, _np
    _mx = mx
    _from_pretrained = from_pretrained
    _get_logmel = get_logmel
    _np = np


class InferenceWorker(threading.Thread):
    """Owns the MLX model. All generate() calls happen on this thread.

    Lifecycle:

        worker = InferenceWorker("mlx-community/parakeet-tdt-0.6b-v2",
                                 sample_rate=16000)
        worker.start()
        worker.wait_ready()        # blocks until model loaded + warmed
        if worker.error:
            ...                    # init failed
        worker.submit_warmup()     # fire-and-forget warmup
        worker.submit_transcribe(audio_np, on_done=lambda text: ...)
        worker.shutdown()          # graceful stop on app quit
    """

    # Sentinel that tells the run loop to exit.
    _STOP = object()

    def __init__(
        self,
        model_id: str,
        *,
        sample_rate: int,
        warmup_seconds: float = 0.5,
        status_cb: Optional[Callable[[str], None]] = None,
        log_cb: Optional[Callable[[str], None]] = None,
    ) -> None:
        super().__init__(daemon=True, name="ParakeyInferenceWorker")
        self._model_id = model_id
        self._sample_rate = sample_rate
        self._warmup_seconds = warmup_seconds
        self._status_cb = status_cb or (lambda _: None)
        self._log_cb = log_cb or (lambda _: None)

        self._queue: "queue.Queue[Any]" = queue.Queue()
        self._ready = threading.Event()

        # Populated by the worker thread; read by other threads.
        self.model: Any = None
        self.error: Optional[str] = None
        # Whether a warmup task is currently executing on the worker.
        # Surfaced to the menu status so the user sees "Warming up…"
        # instead of "Transcribing" when the post-release transcribe
        # is waiting in line behind an in-flight warmup.
        self.warming: bool = False

    # ---- Public API ----------------------------------------------------

    def wait_ready(self, timeout: Optional[float] = None) -> bool:
        """Block until the model is loaded and warmed (or init failed).

        Returns True if the worker is up; False if it timed out. Check
        ``self.error`` to distinguish "loaded successfully" from "failed
        during init" — error is set before _ready is signalled.
        """
        return self._ready.wait(timeout)

    def submit_warmup(self, audio_samples: Optional[int] = None) -> None:
        """Queue a synthetic warmup inference. Bounded-length silence
        keeps the GPU cache hot; size defaults to the constructor's
        ``warmup_seconds``."""
        n = audio_samples if audio_samples is not None \
            else int(self._sample_rate * self._warmup_seconds)
        self._queue.put(("warmup", n))

    def submit_transcribe(
        self,
        audio,
        on_done: Callable[[str], None],
        on_error: Optional[Callable[[BaseException], None]] = None,
    ) -> None:
        """Queue a real transcribe. ``on_done(text)`` is called on this
        worker thread when finished; caller must marshal back to its own
        thread if needed. ``on_error(exc)`` is called instead if the
        inference raises."""
        self._queue.put(("transcribe", audio, on_done, on_error))

    def shutdown(self) -> None:
        """Request graceful exit. Tasks already queued before this call
        still run; tasks queued after are dropped."""
        self._queue.put(self._STOP)

    # ---- Thread body ---------------------------------------------------

    def run(self) -> None:
        # 1. Per-thread MLX stream. Must be created from this thread.
        try:
            self._stream = _mx.new_thread_local_stream(_mx.gpu)
        except Exception as e:
            self.error = f"failed to create thread-local stream: {e!r}"
            self._ready.set()
            return

        # 2. Load model + initial warmup. The whole point of this thread:
        #    both load() and every subsequent generate() happen on the
        #    same thread, inside the same `mx.stream` context.
        try:
            with _mx.stream(self._stream):
                self._status_cb(f"loading {self._model_id.split('/')[-1]}")
                t0 = time.time()
                self.model = _from_pretrained(self._model_id)
                self._log_cb(f"model loaded in {time.time()-t0:.1f}s")

                self._status_cb("warming up")
                t0 = time.time()
                self._do_inference(self._make_silence(
                    int(self._sample_rate * self._warmup_seconds)))
                self._log_cb(f"warmed up in {time.time()-t0:.1f}s")
        except Exception as e:
            self.error = repr(e)
            self._log_cb(f"worker init failed: {e}")
            self._ready.set()
            return

        self._ready.set()

        # 3. Task loop. One generate() at a time; the queue provides the
        #    serialization the inference lock used to.
        while True:
            task = self._queue.get()
            if task is self._STOP:
                return
            try:
                self._dispatch(task)
            except Exception as e:
                self._log_cb(f"worker task error: {e}")

    # ---- Internals -----------------------------------------------------

    def _dispatch(self, task) -> None:
        kind = task[0]
        if kind == "warmup":
            (_, n) = task
            self.warming = True
            try:
                t0 = time.time()
                with _mx.stream(self._stream):
                    self._do_inference(self._make_silence(n))
                self._log_cb(f"re-warmed in {time.time()-t0:.2f}s after idle")
            finally:
                self.warming = False
        elif kind == "transcribe":
            (_, audio, on_done, on_error) = task
            try:
                with _mx.stream(self._stream):
                    text = self._do_inference(audio)
                on_done(text)
            except Exception as e:
                if on_error is not None:
                    on_error(e)
                else:
                    self._log_cb(f"transcribe error (no handler): {e}")
        else:
            self._log_cb(f"worker got unknown task: {kind!r}")

    def _do_inference(self, audio) -> str:
        """Run a single end-to-end generate. Caller must hold the
        mx.stream context (we don't double-wrap to keep stack traces
        short)."""
        audio_mx = _mx.array(audio.astype(_np.float32))
        mel = _get_logmel(audio_mx, self.model.preprocessor_config)
        result = self.model.generate(mel)[0]
        return result.text.strip() if hasattr(result, "text") else ""

    def _make_silence(self, n: int):
        return _np.zeros(n, dtype=_np.float32)
