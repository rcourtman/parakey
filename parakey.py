#!/usr/bin/env python3
"""
parakey — menu bar push-to-talk dictation using Parakeet-MLX.

Hold Right Control, talk, release. Audio is transcribed locally and pasted
at the cursor. Lives in the menu bar.
"""
from __future__ import annotations

import collections
import os
import sys
import threading
import time

import mlx.core as mx
import numpy as np
import rumps
import sounddevice as sd
from AppKit import NSAlert, NSImage, NSPasteboard, NSPasteboardTypeString, NSSound
from Foundation import NSAppleScript, NSBundle, NSUserDefaults
from pynput import keyboard
import Quartz

from parakeet_mlx import from_pretrained
from parakeet_mlx.audio import get_logmel

# Tell the running process to identify as "Parakey" instead of "Python".
# The Homebrew Python interpreter ships in its own .app bundle, so by
# default macOS surfaces "Python" in tooltips, About dialogs, and
# notifications. Mutating mainBundle()'s info dictionary in-place fixes
# the user-visible bits. (CFBundleIdentifier — used by TCC — is not
# affected by this trick; a full fix would mean bundling Python via
# py2app so the running executable lives inside Parakey.app.)
_info = NSBundle.mainBundle().infoDictionary()
if _info is not None:
    _info["CFBundleName"] = "Parakey"
    _info["CFBundleDisplayName"] = "Parakey"

# ---- Config -----------------------------------------------------------------

MODEL_ID = os.environ.get("PARAKEY_MODEL", "mlx-community/parakeet-tdt-0.6b-v2")
SAMPLE_RATE = 16000
CHANNELS = 1
MIN_CLIP_SECONDS = 0.25
START_SOUND = "/System/Library/Sounds/Tink.aiff"
DONE_SOUND = "/System/Library/Sounds/Pop.aiff"

PROJECT_DIR = os.path.dirname(os.path.abspath(__file__))
MENUBAR_ICON_PATH = os.path.join(PROJECT_DIR, "icon", "parakey-menubar.png")

# Hotkey choices: (display name, pynput Key, macOS virtual keycode).
# Keycode is needed separately for the Quartz event-tap suppression.
HOTKEY_CHOICES: list[tuple[str, "keyboard.Key", int]] = [
    ("Right Control", keyboard.Key.ctrl_r, 62),
    ("Right Option",  keyboard.Key.alt_r,  61),
    ("Right Command", keyboard.Key.cmd_r,  54),
    ("F5",            keyboard.Key.f5,     96),
    ("F6",            keyboard.Key.f6,     97),
    ("F13",           keyboard.Key.f13,    105),
    ("F18",           keyboard.Key.f18,    79),
    ("F19",           keyboard.Key.f19,    80),
]
DEFAULT_HOTKEY_KEYCODE = 62  # Right Control

TRIGGER_HOLD = "hold"
TRIGGER_TOGGLE = "toggle"
TRIGGER_DISPLAY = {TRIGGER_HOLD: "Press and hold", TRIGGER_TOGGLE: "Press to toggle"}
DEFAULT_TRIGGER_MODE = TRIGGER_HOLD


def hotkey_for_keycode(keycode: int):
    for entry in HOTKEY_CHOICES:
        if entry[2] == keycode:
            return entry
    return HOTKEY_CHOICES[0]

# State labels shown next to the menu bar icon. Empty for idle so the
# brand mark stands alone; short text for the rest so the bar isn't
# cluttered.
LABEL_LOAD = "loading…"
LABEL_IDLE = ""
LABEL_REC = "🔴"  # emoji preserves its red colour even when the icon is templated
LABEL_BUSY = "…"
LABEL_PAUSED = "paused"
LABEL_ERROR = "!"


def log(msg: str) -> None:
    line = f"[{time.strftime('%H:%M:%S')}] {msg}"
    print(line, flush=True)


# ---- Helpers ----------------------------------------------------------------

def load_sound(path: str):
    return NSSound.alloc().initWithContentsOfFile_byReference_(path, True)


MUTE_AFTER_TINK_SECONDS = 0.18  # let the start sound finish before muting
MAX_RECORDING_SECONDS = 120     # auto-release if hotkey is held longer
LOG_TRANSCRIPTS = False         # do not write transcript text to disk
HISTORY_SIZE = 5                # rolling in-memory transcript history (lost on restart)

V_KEYCODE = 0x09  # macOS virtual keycode for "v"

# Pre-compiled in-process AppleScripts (avoid subprocess spawn).
_query_and_mute_script = NSAppleScript.alloc().initWithSource_(
    "set old_muted to output muted of (get volume settings)\n"
    "set volume output muted true\n"
    "return old_muted"
)
_unmute_script = NSAppleScript.alloc().initWithSource_(
    "set volume output muted false"
)


def _query_and_mute() -> "bool | None":
    """Mute system output and return previous mute state (None on failure)."""
    result, error = _query_and_mute_script.executeAndReturnError_(None)
    if error is not None or result is None:
        return None
    return bool(result.booleanValue())


def _unmute() -> None:
    _unmute_script.executeAndReturnError_(None)


def _send_cmd_v() -> None:
    src = Quartz.CGEventSourceCreate(Quartz.kCGEventSourceStateHIDSystemState)
    v_down = Quartz.CGEventCreateKeyboardEvent(src, V_KEYCODE, True)
    Quartz.CGEventSetFlags(v_down, Quartz.kCGEventFlagMaskCommand)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, v_down)
    v_up = Quartz.CGEventCreateKeyboardEvent(src, V_KEYCODE, False)
    Quartz.CGEventSetFlags(v_up, Quartz.kCGEventFlagMaskCommand)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, v_up)


def paste_text(text: str) -> None:
    pb = NSPasteboard.generalPasteboard()
    pb.clearContents()
    pb.setString_forType_(text, NSPasteboardTypeString)
    _send_cmd_v()


# ---- Settings (NSUserDefaults) ----------------------------------------------

SETTINGS_SUITE = "com.local.parakey"


class Settings:
    KEY_HOTKEY_KEYCODE = "hotkey_keycode"
    KEY_TRIGGER_MODE = "trigger_mode"
    KEY_MUTE_WHILE_RECORDING = "mute_while_recording"

    def __init__(self) -> None:
        # Two paths depending on how we're running:
        #  - Bundled (Parakey.app via PyInstaller): bundleIdentifier ==
        #    SETTINGS_SUITE, so standardUserDefaults() points at our
        #    plist. macOS rejects initWithSuiteName_ for your own
        #    bundle id (returns None).
        #  - Unbundled (dev: running parakey.py from Homebrew Python):
        #    bundleIdentifier == "org.python.python", so we need an
        #    explicit suite name to land on com.local.parakey.plist.
        #  Both paths read and write the same on-disk plist:
        #    ~/Library/Preferences/com.local.parakey.plist
        if NSBundle.mainBundle().bundleIdentifier() == SETTINGS_SUITE:
            self.defaults = NSUserDefaults.standardUserDefaults()
        else:
            self.defaults = NSUserDefaults.alloc().initWithSuiteName_(SETTINGS_SUITE)

    @property
    def hotkey_keycode(self) -> int:
        if self.defaults.objectForKey_(self.KEY_HOTKEY_KEYCODE) is None:
            return DEFAULT_HOTKEY_KEYCODE
        return int(self.defaults.integerForKey_(self.KEY_HOTKEY_KEYCODE))

    @hotkey_keycode.setter
    def hotkey_keycode(self, value: int) -> None:
        self.defaults.setInteger_forKey_(int(value), self.KEY_HOTKEY_KEYCODE)
        self.defaults.synchronize()

    @property
    def trigger_mode(self) -> str:
        v = self.defaults.stringForKey_(self.KEY_TRIGGER_MODE)
        if v in (TRIGGER_HOLD, TRIGGER_TOGGLE):
            return str(v)
        return DEFAULT_TRIGGER_MODE

    @trigger_mode.setter
    def trigger_mode(self, value: str) -> None:
        if value not in (TRIGGER_HOLD, TRIGGER_TOGGLE):
            raise ValueError(f"invalid trigger mode: {value}")
        self.defaults.setObject_forKey_(value, self.KEY_TRIGGER_MODE)
        self.defaults.synchronize()

    @property
    def mute_while_recording(self) -> bool:
        if self.defaults.objectForKey_(self.KEY_MUTE_WHILE_RECORDING) is None:
            return True  # default on
        return bool(self.defaults.boolForKey_(self.KEY_MUTE_WHILE_RECORDING))

    @mute_while_recording.setter
    def mute_while_recording(self, value: bool) -> None:
        self.defaults.setBool_forKey_(bool(value), self.KEY_MUTE_WHILE_RECORDING)
        self.defaults.synchronize()


# ---- App --------------------------------------------------------------------

class Parakey(rumps.App):
    def __init__(self) -> None:
        icon = MENUBAR_ICON_PATH if os.path.exists(MENUBAR_ICON_PATH) else None
        super().__init__(
            "Parakey",
            title=LABEL_LOAD,
            icon=icon,
            template=True,           # auto-tint for light/dark mode
            quit_button=None,
        )

        self.settings = Settings()
        _, hk, hkcode = hotkey_for_keycode(self.settings.hotkey_keycode)
        self.hotkey = hk
        self.hotkey_keycode = hkcode
        self.trigger_mode = self.settings.trigger_mode
        self.mute_while_recording = self.settings.mute_while_recording

        # Stable menu keys (rumps tracks items by their initial title;
        # the visible title can change later without affecting lookup).
        self._status_key = "(starting up)"

        self.status_item = rumps.MenuItem(self._status_key)

        # Rolling in-memory history. Deque auto-evicts the oldest when
        # full. Cleared on app quit — nothing persisted to disk.
        self.history: collections.deque = collections.deque(maxlen=HISTORY_SIZE)

        # Pre-allocated menu slots for the history. Slot 0 lives inline
        # in the main menu (one-click access to the most recent thing).
        # Slots 1..N live inside a "Recent" submenu, lazy-added as they
        # fill so the submenu never shows empty placeholder rows.
        self.history_slots: list[rumps.MenuItem] = []
        for i in range(HISTORY_SIZE):
            slot = rumps.MenuItem(
                f"(transcript {i})",
                callback=self._make_history_copy_callback(i),
            )
            self.history_slots.append(slot)
        self.recent_submenu_item = rumps.MenuItem("Recent")
        self._inline_slot_inserted = False
        self._submenu_inserted = False
        self._submenu_slots_added = 0  # how many of slots 1..N are in the submenu
        self._tooltip_set = False

        self.pause_item = rumps.MenuItem("Pause", callback=self.toggle_pause)
        self.about_item = rumps.MenuItem("About Parakey", callback=self.show_about)
        self.quit_item = rumps.MenuItem("Quit", callback=self.quit_app)

        self.hotkey_items = [
            rumps.MenuItem(name, callback=self.select_hotkey)
            for name, _, _ in HOTKEY_CHOICES
        ]
        for item, (_, _, code) in zip(self.hotkey_items, HOTKEY_CHOICES):
            item.state = 1 if code == self.hotkey_keycode else 0

        self.trigger_items = {
            mode: rumps.MenuItem(label, callback=self.select_trigger_mode)
            for mode, label in TRIGGER_DISPLAY.items()
        }
        for mode, item in self.trigger_items.items():
            item.state = 1 if mode == self.trigger_mode else 0

        self.mute_item = rumps.MenuItem(
            "Mute system audio while recording", callback=self.toggle_mute_setting
        )
        self.mute_item.state = 1 if self.mute_while_recording else 0

        self.menu = [
            self.status_item,
            None,
            {
                "Settings": [
                    {"Hotkey": self.hotkey_items},
                    {"Trigger mode": list(self.trigger_items.values())},
                    self.mute_item,
                ]
            },
            None,
            self.pause_item,
            None,
            self.about_item,
            self.quit_item,
        ]

        self.lock = threading.Lock()
        self.recording = False
        self.busy = False
        self.paused = False
        self.frames: list[np.ndarray] = []
        self.ready = False
        self.error: str | None = None
        self.load_status = "starting…"
        self.saved_muted: "bool | None" = None
        self.mute_timer: "threading.Timer | None" = None
        self.max_duration_timer: "threading.Timer | None" = None

        self.start_sound = load_sound(START_SOUND)
        self.done_sound = load_sound(DONE_SOUND)

        self.model = None
        self.stream: sd.InputStream | None = None
        self.listener: keyboard.Listener | None = None

        threading.Thread(target=self._initialize, daemon=True).start()

    # ---- Initialization (background thread) --------------------------------

    def _initialize(self) -> None:
        try:
            self._set_load_status(f"loading {MODEL_ID.split('/')[-1]}")
            t0 = time.time()
            self.model = from_pretrained(MODEL_ID)
            log(f"model loaded in {time.time()-t0:.1f}s")

            self._set_load_status("warming up")
            t0 = time.time()
            warm = np.zeros(int(SAMPLE_RATE * 0.5), dtype=np.float32)
            warm_mx = mx.array(warm)
            mel = get_logmel(warm_mx, self.model.preprocessor_config)
            self.model.generate(mel)
            log(f"warmed up in {time.time()-t0:.1f}s")

            self._set_load_status("opening mic")
            self.stream = sd.InputStream(
                samplerate=SAMPLE_RATE,
                channels=CHANNELS,
                dtype="float32",
                callback=self._audio_callback,
            )
            self.stream.start()
            log(f"mic open: {sd.query_devices(kind='input')['name']}")

            self._set_load_status("registering hotkey")
            self.listener = keyboard.Listener(
                on_press=self._on_press,
                on_release=self._on_release,
                darwin_intercept=self._darwin_intercept,
            )
            self.listener.start()

            self.ready = True
            hk_name, _, _ = hotkey_for_keycode(self.hotkey_keycode)
            verb = "hold" if self.trigger_mode == TRIGGER_HOLD else "press"
            log(f"ready — {verb} {hk_name} to dictate")
        except Exception as e:
            self.error = str(e)
            log(f"init failed: {e}")

    def _set_load_status(self, msg: str) -> None:
        self.load_status = msg
        log(msg)

    # ---- Audio + hotkey ----------------------------------------------------

    def _audio_callback(self, indata, frames, time_info, status) -> None:
        if status:
            log(f"audio status: {status}")
        if self.recording:
            self.frames.append(indata.copy())

    def _start_recording(self) -> None:
        with self.lock:
            if self.recording or self.busy:
                return
            self.recording = True
            self.frames = []
        self.start_sound.stop()
        self.start_sound.play()
        if self.mute_timer is not None:
            self.mute_timer.cancel()
            self.mute_timer = None
        if self.mute_while_recording:
            self.mute_timer = threading.Timer(MUTE_AFTER_TINK_SECONDS, self._engage_mute)
            self.mute_timer.daemon = True
            self.mute_timer.start()
        if self.max_duration_timer is not None:
            self.max_duration_timer.cancel()
        self.max_duration_timer = threading.Timer(
            MAX_RECORDING_SECONDS, self._auto_release
        )
        self.max_duration_timer.daemon = True
        self.max_duration_timer.start()

    def _stop_recording(self) -> None:
        with self.lock:
            if not self.recording:
                return
            self.recording = False
        if self.mute_timer is not None:
            self.mute_timer.cancel()
            self.mute_timer = None
        if self.max_duration_timer is not None:
            self.max_duration_timer.cancel()
            self.max_duration_timer = None
        threading.Thread(target=self._transcribe_and_paste, daemon=True).start()

    def _on_press(self, key) -> None:
        if not self.ready or self.paused or key != self.hotkey:
            return
        if self.trigger_mode == TRIGGER_TOGGLE:
            if self.recording:
                self._stop_recording()
            else:
                self._start_recording()
        else:  # TRIGGER_HOLD
            self._start_recording()

    def _on_release(self, key) -> None:
        if key != self.hotkey:
            return
        if self.trigger_mode == TRIGGER_HOLD:
            self._stop_recording()
        # TRIGGER_TOGGLE: release is a no-op; second press will stop.

    def _auto_release(self) -> None:
        log(f"max recording duration ({MAX_RECORDING_SECONDS}s) reached")
        self._stop_recording()

    def _engage_mute(self) -> None:
        if not self.mute_while_recording:
            return
        with self.lock:
            if not self.recording:
                return
        prev = _query_and_mute()
        self.saved_muted = prev
        log(f"output muted (was: {prev})")

    def _restore_mute(self) -> None:
        if self.saved_muted is False:
            _unmute()
            log("output unmuted")
        self.saved_muted = None

    def _transcribe_and_paste(self) -> None:
        with self.lock:
            frames = self.frames
            self.frames = []
            self.busy = True
        try:
            if not frames:
                return
            audio = np.concatenate(frames, axis=0).flatten()
            dur = len(audio) / SAMPLE_RATE
            if dur < MIN_CLIP_SECONDS:
                log(f"clip too short ({dur:.2f}s), ignored")
                return
            t0 = time.time()
            audio_mx = mx.array(audio.astype(np.float32))
            mel = get_logmel(audio_mx, self.model.preprocessor_config)
            result = self.model.generate(mel)[0]
            dt = time.time() - t0
            text = result.text.strip()
            preview = repr(text) if LOG_TRANSCRIPTS else f"{len(text)} chars"
            log(f"{dur:.1f}s audio → {dt:.2f}s → {preview}")
            if text:
                self.history.appendleft(text)
                paste_text(text + " ")
                self._restore_mute()  # unmute before done sound
                self.done_sound.stop()
                self.done_sound.play()
        except Exception as e:
            log(f"transcribe error: {e}")
        finally:
            self._restore_mute()  # safety net if happy path skipped it
            with self.lock:
                self.busy = False

    def _darwin_intercept(self, event_type, event):
        keycode = Quartz.CGEventGetIntegerValueField(
            event, Quartz.kCGKeyboardEventKeycode
        )
        if keycode == self.hotkey_keycode and not self.paused:
            return None
        return event

    # ---- Menu actions ------------------------------------------------------

    def _make_history_copy_callback(self, slot_idx: int):
        """Returns a click handler that copies the transcript at slot_idx."""
        def callback(_sender) -> None:
            if slot_idx < len(self.history):
                text = self.history[slot_idx]
                pb = NSPasteboard.generalPasteboard()
                pb.clearContents()
                pb.setString_forType_(text, NSPasteboardTypeString)
                log(f"copied {len(text)} chars from history slot {slot_idx}")
        return callback

    def select_hotkey(self, sender) -> None:
        for name, key, code in HOTKEY_CHOICES:
            if name == sender.title:
                self.hotkey = key
                self.hotkey_keycode = code
                self.settings.hotkey_keycode = code
                log(f"hotkey set to {name} (keycode {code})")
                break
        for item in self.hotkey_items:
            item.state = 1 if item.title == sender.title else 0

    def toggle_mute_setting(self, sender) -> None:
        self.mute_while_recording = not self.mute_while_recording
        self.settings.mute_while_recording = self.mute_while_recording
        sender.state = 1 if self.mute_while_recording else 0
        log(f"mute while recording: {self.mute_while_recording}")

    def select_trigger_mode(self, sender) -> None:
        for mode, label in TRIGGER_DISPLAY.items():
            if label == sender.title:
                # Releasing mid-recording when switching to TOGGLE while held
                # would otherwise leave the app stuck — stop cleanly first.
                if self.recording:
                    self._stop_recording()
                self.trigger_mode = mode
                self.settings.trigger_mode = mode
                log(f"trigger mode set to {mode}")
                break
        for mode, item in self.trigger_items.items():
            item.state = 1 if mode == self.trigger_mode else 0

    def toggle_pause(self, sender) -> None:
        self.paused = not self.paused
        sender.title = "Resume" if self.paused else "Pause"
        log(f"{'paused' if self.paused else 'resumed'}")

    def show_about(self, sender) -> None:
        hotkey_name, _, _ = hotkey_for_keycode(self.hotkey_keycode)
        alert = NSAlert.alloc().init()
        alert.setMessageText_("Parakey")
        alert.setInformativeText_(
            "Lightweight push-to-talk dictation for Apple Silicon Macs.\n"
            "\n"
            f"Hotkey:  {hotkey_name}\n"
            f"Mode:    {TRIGGER_DISPLAY[self.trigger_mode]}\n"
            f"Model:   {MODEL_ID}\n"
            "\n"
            "Maintained by Richard Courtman.\n"
            "github.com/rcourtman/parakey · MIT licensed"
        )
        icon_path = os.path.join(PROJECT_DIR, "icon", "Parakey.icns")
        if os.path.exists(icon_path):
            img = NSImage.alloc().initWithContentsOfFile_(icon_path)
            if img is not None:
                alert.setIcon_(img)
        alert.runModal()

    def quit_app(self, sender) -> None:
        log("quitting")
        try:
            if self.listener:
                self.listener.stop()
        except Exception:
            pass
        try:
            if self.stream:
                self.stream.stop()
                self.stream.close()
        except Exception:
            pass
        rumps.quit_application()

    # ---- UI tick (main thread, 10 Hz) --------------------------------------

    def _set_tooltip_once(self) -> None:
        """Set the menu bar tooltip to 'Parakey' once the NSStatusItem exists."""
        if self._tooltip_set:
            return
        try:
            ns = getattr(self._nsapp, "nsstatusitem", None)
            if ns is not None:
                btn = ns.button()
                if btn is not None:
                    btn.setToolTip_("Parakey")
                    self._tooltip_set = True
        except Exception as e:
            log(f"tooltip set failed: {e}")
            self._tooltip_set = True  # don't keep retrying

    @rumps.timer(0.1)
    def _tick(self, _sender) -> None:
        self._set_tooltip_once()
        # Menu bar title (with the brand icon shown via self.icon).
        if self.error:
            self.title = LABEL_ERROR
            self.status_item.title = f"Error: {self.error}"
            return
        if not self.ready:
            self.title = LABEL_LOAD
            self.status_item.title = self.load_status[:1].upper() + self.load_status[1:]
            return
        if self.busy:
            self.title = LABEL_BUSY
            self.status_item.title = "Transcribing"
        elif self.recording:
            self.title = LABEL_REC
            self.status_item.title = "Recording"
        elif self.paused:
            self.title = LABEL_PAUSED
            self.status_item.title = "Paused"
        else:
            self.title = LABEL_IDLE
            hk_name, _, _ = hotkey_for_keycode(self.hotkey_keycode)
            verb = "Hold" if self.trigger_mode == TRIGGER_HOLD else "Press"
            self.status_item.title = f"{verb} {hk_name} to dictate"

        # Rolling transcript history. Most recent lives inline in the main
        # menu. Older entries live inside a "Recent" submenu so the main
        # menu stays compact. Both surfaces are lazy-built — they don't
        # appear until there's content to show.
        n = len(self.history)

        # Inline slot 0
        if n >= 1 and not self._inline_slot_inserted:
            self.menu.insert_after(self._status_key, self.history_slots[0])
            self._inline_slot_inserted = True

        # "Recent" submenu (visible only once there's a 2nd transcript)
        if n >= 2 and not self._submenu_inserted:
            self.menu.insert_after("(transcript 0)", self.recent_submenu_item)
            self._submenu_inserted = True

        # Add older slots into the submenu as they fill up
        target_submenu_count = max(0, n - 1)
        for i in range(self._submenu_slots_added, target_submenu_count):
            self.recent_submenu_item.add(self.history_slots[i + 1])
        self._submenu_slots_added = max(self._submenu_slots_added, target_submenu_count)

        # Update each slot's visible title (the deque shifts as new
        # transcripts arrive; menu keys stay stable as "(transcript N)").
        for i in range(n):
            text = self.history[i]
            preview = text if len(text) <= 50 else text[:47] + "…"
            quoted = f"“{preview}”"
            if self.history_slots[i].title != quoted:
                self.history_slots[i].title = quoted


def main() -> int:
    Parakey().run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
