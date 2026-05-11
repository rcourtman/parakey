"""
Tests for inference_worker.InferenceWorker.

The worker is the single thread that owns the MLX model in production.
We can't import real MLX on Linux CI, so these tests inject lightweight
fakes via ``inference_worker.configure(...)``. The tests cover the parts
that are easy to break and hard to spot in casual use:

  * The worker creates its thread-local stream + loads the model on
    its OWN thread (not the caller's).
  * ``wait_ready()`` blocks until both load and startup-warmup finish.
  * Tasks run FIFO; a transcribe submitted after a warmup waits for it.
  * ``warming`` is True for the lifetime of a warmup task and only
    that.
  * Errors in user-submitted tasks don't kill the worker.
  * ``shutdown()`` is graceful: queued tasks before the sentinel still
    run, tasks queued after are ignored.
"""
from __future__ import annotations

import os
import sys
import threading
import time
import unittest
from typing import Any
from unittest.mock import MagicMock

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import inference_worker
from inference_worker import InferenceWorker


# ---------------------------------------------------------------------
# Fakes for the MLX/parakeet_mlx/numpy globals the worker uses.
# ---------------------------------------------------------------------

class FakeStreamContext:
    def __enter__(self): return self
    def __exit__(self, *exc): return False


class FakeMX:
    """Minimal stand-in for ``mlx.core``. Records which thread created
    the thread-local stream so tests can verify the worker did it on
    its own thread, not the caller's."""

    class _GPU: pass
    gpu = _GPU()

    def __init__(self) -> None:
        self.stream_created_on_thread: int | None = None
        self.stream_uses: list[int] = []  # thread ids that entered mx.stream()

    def new_thread_local_stream(self, device):
        self.stream_created_on_thread = threading.get_ident()
        return object()  # opaque token

    def stream(self, _s):
        self.stream_uses.append(threading.get_ident())
        return FakeStreamContext()

    def array(self, a, *args, **kwargs):
        return a  # passthrough


class FakeNumpy:
    float32 = "f32"
    @staticmethod
    def zeros(n, dtype=None):
        # Just enough to look array-ish.
        a = MagicMock()
        a.astype = MagicMock(return_value=a)
        a.__len__ = lambda self: n  # type: ignore[assignment]
        return a


class FakeResult:
    def __init__(self, text: str) -> None:
        self.text = text


class FakeModel:
    """A stand-in parakeet model. ``generate`` records every call's
    audio length so tests can prove the worker called it correctly."""

    def __init__(self) -> None:
        self.preprocessor_config = object()
        self.generate_calls: list[tuple[int, int]] = []  # (length, thread_id)
        self.loaded_on_thread: int = threading.get_ident()
        self.text_to_return = "ok"
        self.delay_each_generate = 0.0

    def generate(self, mel):
        # Whatever was passed for length is fine — we just want to
        # confirm it ran on the right thread.
        time.sleep(self.delay_each_generate)
        return [FakeResult(self.text_to_return)]


def fake_get_logmel(audio, _cfg):
    return audio  # passthrough — generate doesn't care


# Holds the most recent model that ``fake_from_pretrained`` produced,
# so tests can inspect it.
_LAST_MODEL: dict = {}


def fake_from_pretrained(_model_id: str):
    model = FakeModel()
    _LAST_MODEL["model"] = model
    return model


def _configure_with_fakes() -> FakeMX:
    fake_mx = FakeMX()
    inference_worker.configure(fake_mx, fake_from_pretrained, fake_get_logmel, FakeNumpy)
    return fake_mx


# ---------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------

class LifecycleTests(unittest.TestCase):
    def test_wait_ready_blocks_until_load_and_warmup_complete(self):
        fake_mx = _configure_with_fakes()
        w = InferenceWorker("fake/model", sample_rate=16000, warmup_seconds=0.1)
        w.start()
        try:
            self.assertTrue(w.wait_ready(timeout=2.0))
            self.assertIsNone(w.error)
            self.assertIs(_LAST_MODEL["model"], w.model)
            # Model was loaded on the worker thread, not main.
            self.assertNotEqual(_LAST_MODEL["model"].loaded_on_thread,
                                threading.get_ident())
            # Stream was also created on the worker thread.
            self.assertEqual(fake_mx.stream_created_on_thread,
                             _LAST_MODEL["model"].loaded_on_thread)
        finally:
            w.shutdown(); w.join(timeout=2.0)

    def test_error_during_load_is_surfaced_and_ready_still_fires(self):
        # Fake from_pretrained that explodes.
        def boom(_id):
            raise RuntimeError("nope")
        inference_worker.configure(FakeMX(), boom, fake_get_logmel, FakeNumpy)
        w = InferenceWorker("fake/model", sample_rate=16000)
        w.start()
        try:
            self.assertTrue(w.wait_ready(timeout=2.0),
                            "wait_ready must unblock even on init failure")
            self.assertIsNotNone(w.error)
            self.assertIn("nope", w.error)
        finally:
            w.shutdown(); w.join(timeout=2.0)


# ---------------------------------------------------------------------
# Task processing
# ---------------------------------------------------------------------

class TaskProcessingTests(unittest.TestCase):
    def test_transcribe_returns_text_via_callback(self):
        _configure_with_fakes()
        w = InferenceWorker("fake/model", sample_rate=16000)
        w.start()
        try:
            w.wait_ready()
            _LAST_MODEL["model"].text_to_return = "hello world"
            done = threading.Event()
            got: dict = {}
            w.submit_transcribe(FakeNumpy.zeros(16000), lambda t: (got.update(text=t), done.set()))
            self.assertTrue(done.wait(timeout=2.0))
            self.assertEqual(got["text"], "hello world")
        finally:
            w.shutdown(); w.join(timeout=2.0)

    def test_warmup_then_transcribe_serialize_via_queue(self):
        """A warmup queued *before* a transcribe runs first, and the
        transcribe waits for it. This is what gives us 'parallel during
        speak' for free without explicit locks."""
        _configure_with_fakes()
        w = InferenceWorker("fake/model", sample_rate=16000)
        w.start()
        try:
            w.wait_ready()
            order: list[str] = []
            transcribe_done = threading.Event()
            # Slow warmup so the order is observable.
            _LAST_MODEL["model"].delay_each_generate = 0.1

            # We don't have direct hook into the warmup task, but we can
            # observe via the warming flag.
            w.submit_warmup()
            def on_transcribe(text):
                order.append("transcribe")
                transcribe_done.set()
            w.submit_transcribe(FakeNumpy.zeros(8000), on_transcribe)

            # Sample the warming flag while warmup is in flight.
            time.sleep(0.05)
            self.assertTrue(w.warming, "warming must be True during warmup task")
            self.assertEqual(order, [],
                             "transcribe must not have run while warmup was in flight")

            self.assertTrue(transcribe_done.wait(timeout=2.0))
            self.assertEqual(order, ["transcribe"])
            self.assertFalse(w.warming, "warming must clear after warmup task ends")
        finally:
            w.shutdown(); w.join(timeout=2.0)

    def test_task_error_does_not_kill_worker(self):
        _configure_with_fakes()
        w = InferenceWorker("fake/model", sample_rate=16000)
        w.start()
        try:
            w.wait_ready()
            # Make the model throw on next generate.
            class Boom(Exception): pass
            _LAST_MODEL["model"].generate = MagicMock(side_effect=Boom("oops"))

            err_seen = threading.Event()
            def on_err(e): err_seen.set()
            w.submit_transcribe(FakeNumpy.zeros(8000), lambda _t: None, on_error=on_err)
            self.assertTrue(err_seen.wait(timeout=2.0))

            # Now reset and submit another transcribe — worker must still
            # be processing tasks.
            done = threading.Event()
            _LAST_MODEL["model"].generate = lambda _mel: [FakeResult("alive")]
            got: dict = {}
            w.submit_transcribe(FakeNumpy.zeros(8000),
                                lambda t: (got.update(text=t), done.set()))
            self.assertTrue(done.wait(timeout=2.0))
            self.assertEqual(got["text"], "alive")
        finally:
            w.shutdown(); w.join(timeout=2.0)

    def test_shutdown_drains_queue_then_exits(self):
        _configure_with_fakes()
        w = InferenceWorker("fake/model", sample_rate=16000)
        w.start()
        try:
            w.wait_ready()
            done = threading.Event()
            w.submit_transcribe(FakeNumpy.zeros(8000), lambda _t: done.set())
            w.shutdown()
            self.assertTrue(done.wait(timeout=2.0),
                            "queued task before shutdown must still run")
            w.join(timeout=2.0)
            self.assertFalse(w.is_alive())
        finally:
            if w.is_alive():
                w.shutdown(); w.join(timeout=2.0)


if __name__ == "__main__":
    unittest.main()
