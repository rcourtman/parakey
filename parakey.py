#!/usr/bin/env python3
"""
parakey — menu bar push-to-talk dictation using Parakeet-MLX.

Hold Right Control, talk, release. Audio is transcribed locally and pasted
at the cursor. Lives in the menu bar.
"""
from __future__ import annotations

import os
# Disable Hugging Face Hub's anonymous usage telemetry. parakeet-mlx
# pulls models via huggingface_hub on first launch; without this opt-out
# the library would send a small ping every download. Set before any
# huggingface-touching import below.
os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")

import collections
import subprocess
import sys
import tempfile
import textwrap
import threading
import time

import mlx.core as mx
import numpy as np
import rumps
import sounddevice as sd
from AppKit import (
    NSAlert,
    NSImage,
    NSPasteboard,
    NSPasteboardTypeString,
    NSSound,
    NSWorkspace,
)
from Foundation import NSAppleScript, NSBundle, NSURL, NSUserDefaults
from pynput import keyboard
import Quartz

from parakeet_mlx import from_pretrained
from parakeet_mlx.audio import get_logmel

from warmup_gate import WarmupGate
import inference_worker as _iw_module
from inference_worker import InferenceWorker

# Wire MLX / parakeet_mlx / numpy into the worker module. The worker
# itself doesn't import them at module scope so it can be unit-tested
# on platforms (Linux CI) where MLX isn't available.
_iw_module.configure(mx, from_pretrained, get_logmel, np)

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
DEFAULT_HOTKEY_KEYCODE = 61  # Right Option (universal across Apple keyboards;
                             # MacBooks and Magic Keyboards have no Right Control)

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


_LOG_PATH = os.path.expanduser("~/Library/Logs/Parakey.log")
try:
    os.makedirs(os.path.dirname(_LOG_PATH), exist_ok=True)
except OSError:
    pass


def log(msg: str) -> None:
    line = f"[{time.strftime('%H:%M:%S')}] {msg}"
    print(line, flush=True)
    # Bundled .apps run with no console; mirror to a file we can tail.
    try:
        with open(_LOG_PATH, "a") as f:
            f.write(line + "\n")
    except OSError:
        pass


# ---- Helpers ----------------------------------------------------------------

def load_sound(path: str):
    return NSSound.alloc().initWithContentsOfFile_byReference_(path, True)


MUTE_AFTER_TINK_SECONDS = 0.18  # let the start sound finish before muting
MAX_RECORDING_SECONDS = 120     # auto-release if hotkey is held longer
LOG_TRANSCRIPTS = False         # do not write transcript text to disk
HISTORY_SIZE = 5                # rolling in-memory transcript history (lost on restart)

# If the model hasn't been used in this many seconds, fire a background
# warmup the next time the user presses the hotkey. MLX evicts compiled
# Metal pipelines and tensor allocations after long idles, which makes the
# first transcribe after a multi-hour gap an order of magnitude slower
# (e.g. 8s instead of 0.4s for the same clip). The warmup runs while the
# user is still speaking, so by the time they release the GPU is hot
# again and the real transcribe is back to steady-state latency.
COLD_THRESHOLD_SECONDS = 300    # treat as cold after 5 min of inactivity

# --- Update check ----------------------------------------------------------
# parse_semver, find_brew, fetch_latest_release_tag, and the constants live
# in update_check.py so they can be unit-tested without dragging in MLX.
# Only the AppKit-dependent helpers (bundle path, version string) stay here.
from update_check import (
    GITHUB_LATEST_RELEASE_URL,
    GITHUB_RELEASES_PAGE,
    UPDATE_CHECK_FIRST_DELAY_SECONDS,
    UPDATE_CHECK_INTERVAL_SECONDS,
    UPDATE_CHECK_HTTP_TIMEOUT_SECONDS,
    parse_semver,
    find_brew,
    fetch_latest_release_tag,
)


def current_bundle_version() -> str:
    """Read CFBundleShortVersionString out of the running bundle's Info.plist.
    Returns '0.0.0' when we can't (e.g. running from source in dev), which
    means update-check comparisons will treat us as ancient and always offer
    the latest release — fine for testing, harmless in production."""
    try:
        info = NSBundle.mainBundle().infoDictionary()
        v = info.objectForKey_("CFBundleShortVersionString")
        if v is not None:
            return str(v)
    except Exception:
        pass
    return "0.0.0"


def is_brew_install() -> bool:
    """True if we're running from the Cask-installed bundle at
    /Applications/Parakey.app. Source / dev installs from elsewhere
    can't be updated via brew so we fall back to opening the releases
    page in the browser."""
    try:
        return str(NSBundle.mainBundle().bundlePath()) == "/Applications/Parakey.app"
    except Exception:
        return False


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
    KEY_SHOW_IN_DOCK = "show_in_dock"
    KEY_INPUT_DEVICE = "input_device"  # device name as string; "" = system default
    KEY_CHECK_FOR_UPDATES = "check_for_updates"  # bool; default True
    KEY_LAST_SEEN_VERSION = "last_seen_version"  # str; for upgrade detection

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

    @property
    def show_in_dock(self) -> bool:
        # Default off — menu-bar-only matches the convention for utilities.
        return bool(self.defaults.boolForKey_(self.KEY_SHOW_IN_DOCK))

    @show_in_dock.setter
    def show_in_dock(self, value: bool) -> None:
        self.defaults.setBool_forKey_(bool(value), self.KEY_SHOW_IN_DOCK)
        self.defaults.synchronize()

    @property
    def input_device(self) -> str:
        """Saved input-device name. Empty string means 'use system default'."""
        v = self.defaults.stringForKey_(self.KEY_INPUT_DEVICE)
        return str(v) if v is not None else ""

    @input_device.setter
    def input_device(self, value: str) -> None:
        self.defaults.setObject_forKey_(value or "", self.KEY_INPUT_DEVICE)
        self.defaults.synchronize()

    @property
    def last_seen_version(self) -> str:
        """The CFBundleShortVersionString we saw on the last successful
        startup. Empty string for first-ever launch. Used to detect
        upgrades and proactively recover from stale TCC state."""
        v = self.defaults.stringForKey_(self.KEY_LAST_SEEN_VERSION)
        return str(v) if v is not None else ""

    @last_seen_version.setter
    def last_seen_version(self, value: str) -> None:
        self.defaults.setObject_forKey_(value or "", self.KEY_LAST_SEEN_VERSION)
        self.defaults.synchronize()

    @property
    def check_for_updates(self) -> bool:
        """Whether to poll GitHub for newer releases. Default on."""
        if self.defaults.objectForKey_(self.KEY_CHECK_FOR_UPDATES) is None:
            return True
        return bool(self.defaults.boolForKey_(self.KEY_CHECK_FOR_UPDATES))

    @check_for_updates.setter
    def check_for_updates(self, value: bool) -> None:
        self.defaults.setBool_forKey_(bool(value), self.KEY_CHECK_FOR_UPDATES)
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
        self.show_in_dock = self.settings.show_in_dock
        self.input_device = self.settings.input_device  # "" = system default
        self.check_for_updates = self.settings.check_for_updates

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

        # Permission rows shown directly in the main menu. They appear
        # below the status row only while any of the three permissions
        # is still missing; once all three are granted the rows
        # collapse out of the menu so it stays clean.
        self._perm_pane_map = {
            "Microphone":       "Privacy_Microphone",
            "Accessibility":    "Privacy_Accessibility",
            "Input Monitoring": "Privacy_ListenEvent",
        }
        self._perm_callbacks = {
            name: self._make_perm_handler(name) for name in self._perm_pane_map
        }
        # Stable menu keys (rumps tracks items by their initial title).
        self._perm_keys = {name: f"(perm:{name})" for name in self._perm_pane_map}
        self.perm_items = {
            name: rumps.MenuItem(
                self._perm_keys[name],
                callback=self._perm_callbacks[name],
            )
            for name in self._perm_pane_map
        }
        self._perm_rows_visible = False  # toggled in _update_permission_rows
        # In-session click counter per permission. On click #2+ for the
        # same permission, the handler proactively resets TCC before
        # re-firing the request — the user's first click landing without
        # effect almost always means TCC's in a stuck state. Counter
        # never decrements; if the click succeeds, the row disappears
        # entirely so the count is moot.
        self._perm_click_counts: dict[str, int] = {}

        self.pause_item = rumps.MenuItem("Pause", callback=self.toggle_pause)
        # Disabled info row showing the running version. Sits just above
        # "About Parakey" so users can glance at the version without
        # opening the About dialog. The dialog still has the canonical
        # presentation (with build number, hotkey, model, etc.).
        self.version_item = rumps.MenuItem(
            f"Parakey {current_bundle_version()}", callback=None,
        )
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

        self.dock_item = rumps.MenuItem(
            "Show Parakey in Dock", callback=self.toggle_dock_setting
        )
        self.dock_item.state = 1 if self.show_in_dock else 0

        self.update_check_item = rumps.MenuItem(
            "Check for updates", callback=self.toggle_update_check_setting
        )
        self.update_check_item.state = 1 if self.check_for_updates else 0

        # Lazily-inserted "Update to vX.Y.Z…" item at the top of the menu.
        # Starts with a placeholder title so rumps uses that as its stable
        # internal key (same trick as the permission rows); we rename it
        # to the real version once a newer release is detected.
        self._update_item_key = "(update)"
        self.update_item = rumps.MenuItem(
            self._update_item_key, callback=self._on_update_clicked
        )
        self._update_item_inserted = False
        self.update_available_tag: "str | None" = None  # 'v0.1.3' if newer found

        # Manual "Check for updates now" action — complements the
        # periodic background check controlled by the toggle above.
        # Default title is stored so we can restore it after showing
        # a transient result ("Checking…", "✓ Up to date", etc.).
        self._update_check_now_default_title = "Check for Updates Now…"
        self.update_check_now_item = rumps.MenuItem(
            self._update_check_now_default_title,
            callback=self._on_update_check_now_clicked,
        )

        # Microphone submenu — list every input-capable device sounddevice
        # finds, plus a "System default" entry at the top. Click to switch;
        # the audio stream restarts to pick up the new device.
        self.mic_items: list = []
        self.mic_default_item = rumps.MenuItem(
            "System default", callback=self.select_input_device
        )
        self.mic_items.append(self.mic_default_item)
        for dev in sd.query_devices():
            if dev.get("max_input_channels", 0) > 0:
                item = rumps.MenuItem(
                    dev["name"], callback=self.select_input_device
                )
                self.mic_items.append(item)
        self._refresh_mic_checkmarks()

        # Start without the permission rows in the menu; _tick inserts
        # them lazily if any permission is missing, and removes them
        # once all three are granted.
        self.menu = [
            self.status_item,
            None,
            {
                "Settings": [
                    {"Hotkey": self.hotkey_items},
                    {"Trigger mode": list(self.trigger_items.values())},
                    {"Microphone": self.mic_items},
                    self.mute_item,
                    self.dock_item,
                    self.update_check_item,
                    self.update_check_now_item,
                ]
            },
            None,
            self.pause_item,
            None,
            self.version_item,
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

        # Cold-after-idle re-warmup state. The gate owns the inference
        # lock (one model.generate() at a time), the timestamp tracking,
        # and the public `warming` flag used by the menu status. See
        # warmup_gate.py for the contract.
        self._gate = WarmupGate(COLD_THRESHOLD_SECONDS, clock=time.monotonic)

        self.start_sound = load_sound(START_SOUND)
        self.done_sound = load_sound(DONE_SOUND)

        # The worker owns the MLX model and is the ONLY thread that
        # calls model.generate(). Loading the model on this thread (not
        # main) is required by MLX 0.31.2 — see inference_worker.py for
        # the gory details and the upstream mlx-lm fix.
        self.worker = InferenceWorker(
            MODEL_ID,
            sample_rate=SAMPLE_RATE,
            warmup_seconds=0.5,
            status_cb=self._set_load_status,
            log_cb=log,
        )
        self.worker.start()

        self.stream: sd.InputStream | None = None
        self.listener: keyboard.Listener | None = None

        threading.Thread(target=self._initialize, daemon=True).start()

    # ---- Initialization (background thread) --------------------------------

    def _initialize(self) -> None:
        try:
            # Block until the worker has loaded the model + done its
            # startup warmup. Worker handles its own status messages
            # via the status_cb we passed in.
            self.worker.wait_ready()
            if self.worker.error:
                raise RuntimeError(self.worker.error)
            # Reset the gate's clock so the next press isn't treated as cold.
            self._gate.last_inference_at = time.monotonic()

            # If we just got upgraded, scrub any TCC entries that are
            # stuck "denied" (the legacy v0.1.x microphone / input-
            # monitoring traps). Granted permissions are untouched.
            self._recover_stale_tcc_after_upgrade()

            self._set_load_status("opening mic")
            device_arg = self.input_device or None
            try:
                self.stream = sd.InputStream(
                    samplerate=SAMPLE_RATE,
                    channels=CHANNELS,
                    dtype="float32",
                    callback=self._audio_callback,
                    device=device_arg,
                )
                self.stream.start()
            except Exception as e:
                # Saved device may have been unplugged since last launch.
                log(f"failed to open {device_arg!r}: {e} — falling back to system default")
                self.input_device = ""
                self.settings.input_device = ""
                self._refresh_mic_checkmarks()
                self.stream = sd.InputStream(
                    samplerate=SAMPLE_RATE,
                    channels=CHANNELS,
                    dtype="float32",
                    callback=self._audio_callback,
                )
                self.stream.start()
            mic_name = sd.query_devices(self.stream.device, kind="input")["name"]
            log(f"mic open: {mic_name}")

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
            # Begin the GitHub Releases poll. Sleeps UPDATE_CHECK_FIRST_DELAY
            # before its first check so it never competes with model load.
            self._start_update_check_loop()
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
        # If the model has been idle long enough that MLX's compiled-shader
        # cache has likely been evicted, kick off a parallel warmup on the
        # worker thread now. The worker queue is FIFO, so this warmup runs
        # to completion before the real transcribe we'll submit on release.
        # Because the user typically speaks for >1s, the warmup is usually
        # done by release time and the transcribe runs immediately.
        if self._gate.try_begin_warmup():
            self.worker.submit_warmup()

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
            # Submit to the worker thread. If a re-warmup was queued on
            # press, it's still running (or already done) — the worker's
            # FIFO queue means we naturally wait for it without any
            # explicit lock here. After a long idle the typical post-
            # release latency is therefore max(0, remaining_warmup) +
            # real_transcribe, instead of the 8s cold path or the 1.4s
            # inline-warmup approach.
            t0 = time.time()
            done = threading.Event()
            result: dict = {}

            def on_done(text: str) -> None:
                result["text"] = text
                self._gate.last_inference_at = time.monotonic()
                # If a warmup was in flight (queued earlier in _start_recording)
                # it must have completed before our transcribe ran, so we
                # release the gate latch here.
                if self._gate.warming:
                    self._gate.end_warmup()
                done.set()

            def on_error(exc: BaseException) -> None:
                result["error"] = exc
                if self._gate.warming:
                    self._gate.end_warmup()
                done.set()

            self.worker.submit_transcribe(audio, on_done, on_error)
            done.wait()
            dt = time.time() - t0
            if "error" in result:
                raise result["error"]
            text = result.get("text", "")
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

    def _refresh_mic_checkmarks(self) -> None:
        """Set state=1 on whichever Microphone item is currently active."""
        target = self.input_device  # "" = System default
        for item in self.mic_items:
            if target == "":
                item.state = 1 if item.title == "System default" else 0
            else:
                item.state = 1 if item.title == target else 0

    def select_input_device(self, sender) -> None:
        chosen = "" if sender.title == "System default" else sender.title
        if chosen == self.input_device:
            return  # no-op
        self.input_device = chosen
        self.settings.input_device = chosen
        self._refresh_mic_checkmarks()
        log(f"input device set to {chosen or '(system default)'}")
        self._restart_audio_stream()

    def _restart_audio_stream(self) -> None:
        """Close the current input stream and reopen with the saved device.

        Aborts any in-flight recording cleanly. Falls back to the system
        default if the requested device can't be opened (e.g. unplugged).
        """
        with self.lock:
            self.recording = False
            self.frames = []
        if self.mute_timer is not None:
            self.mute_timer.cancel()
            self.mute_timer = None
        if self.max_duration_timer is not None:
            self.max_duration_timer.cancel()
            self.max_duration_timer = None
        self._restore_mute()

        try:
            if self.stream is not None:
                self.stream.stop()
                self.stream.close()
        except Exception as e:
            log(f"closing old stream: {e}")
        self.stream = None

        device_arg = self.input_device or None
        try:
            self.stream = sd.InputStream(
                samplerate=SAMPLE_RATE,
                channels=CHANNELS,
                dtype="float32",
                callback=self._audio_callback,
                device=device_arg,
            )
            self.stream.start()
            log(f"mic open: {sd.query_devices(self.stream.device, kind='input')['name']}")
        except Exception as e:
            log(f"failed to open device {device_arg!r}: {e} — falling back to system default")
            self.input_device = ""
            self.settings.input_device = ""
            self._refresh_mic_checkmarks()
            try:
                self.stream = sd.InputStream(
                    samplerate=SAMPLE_RATE,
                    channels=CHANNELS,
                    dtype="float32",
                    callback=self._audio_callback,
                )
                self.stream.start()
                log(f"mic open: {sd.query_devices(kind='input')['name']}")
            except Exception as e2:
                log(f"fallback also failed: {e2}")

    def toggle_dock_setting(self, sender) -> None:
        self.show_in_dock = not self.show_in_dock
        self.settings.show_in_dock = self.show_in_dock
        sender.state = 1 if self.show_in_dock else 0
        self._apply_dock_visibility()
        log(f"show in dock: {self.show_in_dock}")

    def toggle_update_check_setting(self, sender) -> None:
        """Settings ▸ Check for updates. Disables the periodic GitHub poll
        without removing the menu item if an update is already pending —
        the user can still click through to apply or visit the releases
        page."""
        self.check_for_updates = not self.check_for_updates
        self.settings.check_for_updates = self.check_for_updates
        sender.state = 1 if self.check_for_updates else 0
        log(f"check for updates: {self.check_for_updates}")

    # ---- Update check ------------------------------------------------------

    def _start_update_check_loop(self) -> None:
        """Kick off the recurring background update poll. Called once from
        _initialize after the app is ready; subsequent ticks are scheduled
        by the loop itself."""
        if not self.check_for_updates:
            return
        threading.Thread(
            target=self._update_check_tick, daemon=True,
            name="ParakeyUpdateCheck",
        ).start()

    def _update_check_tick(self) -> None:
        """One check, then sleep until the next interval and repeat. Runs
        on a dedicated daemon thread — quits silently when the toggle is
        flipped off."""
        time.sleep(UPDATE_CHECK_FIRST_DELAY_SECONDS)
        while True:
            if not self.check_for_updates:
                return
            try:
                self._check_for_update_once()
            except Exception as e:
                log(f"update check raised: {e}")
            time.sleep(UPDATE_CHECK_INTERVAL_SECONDS)

    def _on_update_check_now_clicked(self, sender) -> None:
        """Manual 'check now' action. Fires a check on a background
        thread (so the menu stays responsive) and shows the result
        inline in the menu item title for a few seconds.

        The action complements the periodic background check controlled
        by the 'Check for updates' toggle — it lets the user force a
        check without waiting up to UPDATE_CHECK_INTERVAL_SECONDS, and
        gives explicit feedback ("Up to date" / "Update available")
        rather than the silent appearance/non-appearance of the
        top-of-menu update row.
        """
        sender.title = "Checking for updates…"
        sender.set_callback(None)  # prevent double-clicks while in flight

        def worker() -> None:
            try:
                self._check_for_update_once()
                had_update = self.update_available_tag is not None
            except Exception as e:
                log(f"manual update check failed: {e}")
                had_update = False
            from PyObjCTools.AppHelper import callAfter
            callAfter(self._finish_update_check_now, had_update)

        threading.Thread(target=worker, daemon=True).start()

    def _finish_update_check_now(self, had_update: bool) -> None:
        """Show a transient result in the Check-Now item, then restore it.

        Runs on the main thread (rumps requires menu mutation there).
        If an update was found, _check_for_update_once already inserted
        the top-of-menu 'Update to v…' row, so all we need here is to
        confirm the check happened.
        """
        item = self.update_check_now_item
        item.title = "✓ Update available" if had_update else "✓ You're up to date"

        def restore_after_delay() -> None:
            time.sleep(4)
            from PyObjCTools.AppHelper import callAfter
            callAfter(self._restore_update_check_now_item)

        threading.Thread(target=restore_after_delay, daemon=True).start()

    def _restore_update_check_now_item(self) -> None:
        item = self.update_check_now_item
        item.title = self._update_check_now_default_title
        item.set_callback(self._on_update_check_now_clicked)

    def _check_for_update_once(self) -> None:
        tag = fetch_latest_release_tag()
        if tag is None:
            return  # network blip, log already silent
        latest = parse_semver(tag)
        current = parse_semver(current_bundle_version())
        if not latest or latest <= current:
            return
        # Newer release is published. Update the menu item title and
        # insert it (if not already) at the top of the menu, right under
        # the status row.
        self.update_available_tag = tag.lstrip("vV")
        self.update_item.title = f"Update to v{self.update_available_tag}…"
        if not self._update_item_inserted:
            self.menu.insert_after(self._status_key, self.update_item)
            self._update_item_inserted = True
        log(f"update available: {current_bundle_version()} → v{self.update_available_tag}")

    def _on_update_clicked(self, _sender) -> None:
        """User clicked the in-menu update item. Brew-installed users get
        an automated upgrade + relaunch; source-installs and missing-brew
        cases fall back to opening the releases page in a browser."""
        if not self.update_available_tag:
            return
        if not is_brew_install():
            log("update click: not a brew install, opening releases page")
            subprocess.Popen(["open", GITHUB_RELEASES_PAGE])
            return
        brew = find_brew()
        if brew is None:
            log("update click: brew not found in PATH, opening releases page")
            subprocess.Popen(["open", GITHUB_RELEASES_PAGE])
            return
        self._spawn_update_helper(brew)

    def _spawn_update_helper(self, brew_path: str) -> None:
        """Write a short shell script that waits for *this* process to die,
        runs ``brew upgrade --cask parakey``, then re-opens the app. We
        spawn it detached and ``rumps.quit_application()`` so it can
        replace the bundle without fighting an open .app."""
        pid = os.getpid()
        app_path = "/Applications/Parakey.app"
        helper = textwrap.dedent(f"""\
            #!/bin/bash
            # Generated by Parakey at update time. Safe to delete after run.
            set -u
            # Wait for the running Parakey to exit (avoids 'app is open' clash).
            for _ in $(seq 1 60); do
                if ! kill -0 {pid} 2>/dev/null; then break; fi
                sleep 0.5
            done
            # Run the brew upgrade. If it fails (e.g. tap unreachable),
            # surface the releases page so the user has a fallback.
            if ! "{brew_path}" upgrade --cask parakey >/tmp/parakey-update.log 2>&1; then
                /usr/bin/open "{GITHUB_RELEASES_PAGE}"
                exit 1
            fi
            # Relaunch.
            /usr/bin/open "{app_path}"
        """)
        fd, path = tempfile.mkstemp(prefix="parakey-update-", suffix=".sh")
        os.close(fd)
        with open(path, "w") as f:
            f.write(helper)
        os.chmod(path, 0o755)
        subprocess.Popen([path], start_new_session=True)
        log(f"spawned update helper: {path}; quitting for upgrade")
        # Give the helper a beat to start polling our pid, then exit cleanly.
        threading.Timer(0.5, rumps.quit_application).start()

    def _apply_dock_visibility(self) -> None:
        """Switch between Regular (dock visible) and Accessory (menu-bar only)."""
        from AppKit import (
            NSApp,
            NSApplicationActivationPolicyRegular,
            NSApplicationActivationPolicyAccessory,
        )
        target = (
            NSApplicationActivationPolicyRegular
            if self.show_in_dock else
            NSApplicationActivationPolicyAccessory
        )
        NSApp.setActivationPolicy_(target)

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

    # ---- Permissions --------------------------------------------------------

    # ---- Auto-recovery for stale TCC state ---------------------------------

    # Mapping from the human-readable permission names used in the menu to
    # the TCC service identifiers that `tccutil reset` accepts. The
    # Microphone and Accessibility names match; Input Monitoring is called
    # "ListenEvent" by TCC.
    _TCC_SERVICE_NAMES = {
        "Microphone": "Microphone",
        "Accessibility": "Accessibility",
        "Input Monitoring": "ListenEvent",
    }
    PARAKEY_BUNDLE_ID = "com.local.parakey"

    def _recover_stale_tcc_after_upgrade(self) -> None:
        """If we got upgraded since the last successful launch, reset
        any TCC entry that's currently denied.

        Why: between v0.1.0 and v0.1.2 Parakey shipped with the wrong
        microphone entitlement key (App Sandbox flavour, not Hardened
        Runtime). macOS Tahoe stopped tolerating that mismatch and
        cached a denial. Upgrading to v0.1.3+ with the correct
        entitlement didn't clear the denial — the user had to run
        `tccutil reset` manually. v0.1.4 hits the same shape of bug
        for Input Monitoring. This method makes both invisible: on
        the first launch after an upgrade, we proactively clear any
        stuck denial for our own bundle so the existing in-menu
        Grant flow can register cleanly.

        Importantly: we DON'T reset permissions that are already
        granted. The user's grant stays intact across upgrades.
        """
        last_seen = self.settings.last_seen_version
        current = current_bundle_version()
        if not last_seen:
            # First-ever launch — just record the version. No state to
            # recover from; the user hasn't granted anything yet.
            self.settings.last_seen_version = current
            return
        if last_seen == current:
            return  # not an upgrade
        log(f"upgrade detected: {last_seen} → {current}; "
            "checking for stale TCC state to recover")
        for name, service in self._TCC_SERVICE_NAMES.items():
            if self._check_permission(name):
                continue  # granted, leave it alone
            try:
                subprocess.run(
                    ["tccutil", "reset", service, self.PARAKEY_BUNDLE_ID],
                    check=False, capture_output=True, timeout=5,
                )
                log(f"  reset TCC {service} for {self.PARAKEY_BUNDLE_ID} "
                    "(was denied; next Grant click will register cleanly)")
            except Exception as e:
                log(f"  tccutil reset {service} failed: {e}")
        # Always record the new version, even if some resets failed —
        # we don't want to re-attempt the same reset on every launch.
        self.settings.last_seen_version = current

    def _make_perm_handler(self, name: str):
        """Click handler. Tries to drive the user to the right place:

        - If the permission is undetermined, trigger the macOS native
          dialog ("Parakey wants Microphone access. Allow / Don't
          Allow"). Don't open Settings — that would steal focus from
          the dialog.
        - If the permission was previously denied (or there's no
          native dialog flow, e.g. Input Monitoring), open the
          relevant Settings pane and let the user toggle there.
        """
        def handler(_sender) -> None:
            from AppKit import (
                NSApp,
                NSApplicationActivationPolicyRegular,
                NSApplicationActivationPolicyAccessory,
            )
            # LSUIElement (menu-bar-only) apps aren't normally allowed
            # to be the frontmost app, which means macOS's permission
            # dialog has no foreground host to attach to and doesn't
            # appear. Temporarily promote to a Regular app for ~6s
            # while the request is in flight, then drop back.
            self._perm_click_counts[name] = self._perm_click_counts.get(name, 0) + 1
            click_count = self._perm_click_counts[name]
            log(f"perm click #{click_count}: {name}")

            # Belt-and-braces: on click 2+ for the same denied
            # permission, scrub TCC before re-requesting. The most
            # common cause of "I clicked Grant but nothing happened"
            # is a stuck TCC entry from an earlier broken build, and
            # a reset puts us back to "never asked" state so the
            # request below registers cleanly.
            if click_count >= 2:
                service = self._TCC_SERVICE_NAMES.get(name)
                if service is not None:
                    try:
                        subprocess.run(
                            ["tccutil", "reset", service, self.PARAKEY_BUNDLE_ID],
                            check=False, capture_output=True, timeout=5,
                        )
                        log(f"  reset TCC {service} before retry")
                    except Exception as e:
                        log(f"  tccutil reset {service} failed: {e}")

            NSApp.setActivationPolicy_(NSApplicationActivationPolicyRegular)
            NSApp.activateIgnoringOtherApps_(True)

            should_open_settings = self._needs_settings_pane(name)
            self._request_permission(name)

            if should_open_settings:
                time.sleep(0.3)
                url = NSURL.URLWithString_(
                    "x-apple.systempreferences:com.apple.preference.security?"
                    + self._perm_pane_map[name]
                )
                NSWorkspace.sharedWorkspace().openURL_(url)

            def _restore_policy():
                time.sleep(6)
                from AppKit import NSApp as _NSApp
                from PyObjCTools.AppHelper import callAfter
                # Restore to whatever the user wants long-term:
                # Regular if they've opted into a dock icon,
                # Accessory otherwise (menu-bar only, no dock).
                target = (
                    NSApplicationActivationPolicyRegular
                    if self.show_in_dock else
                    NSApplicationActivationPolicyAccessory
                )
                callAfter(_NSApp.setActivationPolicy_, target)
                log(f"  restored activation policy after {name}")

            threading.Thread(target=_restore_policy, daemon=True).start()
        return handler

    def _needs_settings_pane(self, name: str) -> bool:
        """True if the permission can't be resolved by a native dialog —
        either previously denied, or the API doesn't show one."""
        try:
            if name == "Microphone":
                from AVFoundation import AVCaptureDevice
                status = int(AVCaptureDevice.authorizationStatusForMediaType_("soun"))
                # 0 NotDetermined, 1 Restricted, 2 Denied, 3 Authorized.
                # Native dialog only appears when NotDetermined.
                return status != 0
            if name == "Accessibility":
                from ApplicationServices import AXIsProcessTrusted
                # AXIsProcessTrustedWithOptions(prompt=True) shows a native
                # dialog with an "Open System Settings" button when the
                # status is unknown. If already explicitly granted, nothing
                # to do; if denied, the dialog still appears, so let it
                # handle it.
                return AXIsProcessTrusted()
            if name == "Input Monitoring":
                # No reliable native prompt for this one — always send the
                # user to Settings.
                return True
        except Exception:
            pass
        return True

    def _check_permission(self, name: str) -> bool:
        """Return True if the named permission is genuinely granted.

        Each check uses the API macOS itself uses for TCC accounting,
        not a heuristic. If those report 'not granted' but audio still
        seems to flow, that's a real macOS-bundle-identity bug — we
        surface the status honestly rather than lying.
        """
        try:
            if name == "Microphone":
                from AVFoundation import AVCaptureDevice
                # AVAuthorizationStatusAuthorized = 3
                return int(AVCaptureDevice.authorizationStatusForMediaType_("soun")) == 3
            if name == "Accessibility":
                from ApplicationServices import AXIsProcessTrusted
                return bool(AXIsProcessTrusted())
            if name == "Input Monitoring":
                # Symmetric with the request path: ask CoreGraphics about
                # CGEventTap access, not IOKit about HID access. Same TCC
                # entry under the hood, but the CG variant is what pynput
                # actually depends on at runtime.
                return bool(Quartz.CGPreflightListenEventAccess())
        except Exception as e:
            log(f"check {name} failed: {e}")
        return False

    # Keep references so completion handlers don't get GC'd before
    # macOS calls back into them.
    _completion_handlers: dict = {}

    def _request_permission(self, name: str) -> None:
        """Trigger macOS to register and prompt for the named permission."""
        try:
            if name == "Microphone":
                from AVFoundation import AVCaptureDevice
                before = int(AVCaptureDevice.authorizationStatusForMediaType_("soun"))
                log(f"  Microphone status before request: {before} "
                    "(0=NotDetermined 1=Restricted 2=Denied 3=Authorized)")

                def _mic_cb(granted):
                    log(f"  Microphone request callback: granted={bool(granted)}")
                self._completion_handlers["mic"] = _mic_cb

                AVCaptureDevice.requestAccessForMediaType_completionHandler_(
                    "soun", _mic_cb,
                )
                # Status doesn't update synchronously — the dialog (if shown)
                # runs the user's response on a queue, and the cb above
                # logs the eventual result.
                after = int(AVCaptureDevice.authorizationStatusForMediaType_("soun"))
                log(f"  Microphone status immediately after request call: {after}")
            elif name == "Accessibility":
                from ApplicationServices import (
                    AXIsProcessTrusted,
                    AXIsProcessTrustedWithOptions,
                    kAXTrustedCheckOptionPrompt,
                )
                log(f"  Accessibility trusted before request: {AXIsProcessTrusted()}")
                AXIsProcessTrustedWithOptions(
                    {kAXTrustedCheckOptionPrompt: True}
                )
            elif name == "Input Monitoring":
                # CGRequestListenEventAccess is the canonical API for any
                # app using CGEventTap (which is what pynput's listener
                # uses under the hood). It does three things in one call:
                #   * Registers the app in the Input Monitoring TCC list
                #     so it shows up in System Settings with a toggle.
                #   * Shows the system prompt if permission was never asked.
                #   * Opens Settings to the right pane if previously denied.
                # The older IOHIDRequestAccess call (IOKit) targets the
                # same TCC service but doesn't reliably register CGEventTap
                # clients on Tahoe 26 — the app silently fails to appear
                # in the list, leaving the user with a "+" button they
                # can't actually use.
                result = bool(Quartz.CGRequestListenEventAccess())
                log(f"  CGRequestListenEventAccess returned: {result}")
        except Exception as e:
            log(f"request {name} failed: {e}")

    def _icon_image(self) -> "NSImage | None":
        path = os.path.join(PROJECT_DIR, "icon", "Parakey.icns")
        if not os.path.exists(path):
            return None
        return NSImage.alloc().initWithContentsOfFile_(path)

    def show_about(self, sender) -> None:
        hotkey_name, _, _ = hotkey_for_keycode(self.hotkey_keycode)
        alert = NSAlert.alloc().init()
        alert.setMessageText_(f"Parakey {current_bundle_version()}")
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

    def _update_permission_rows(self) -> None:
        """Show/hide the three permission rows based on grant state.

        Visible only while any permission is missing — once all three
        are granted the rows collapse out of the menu. Each row's
        title is also kept in sync (✓ vs ⚠) for the brief window
        where some are granted but not all.
        """
        states = {name: self._check_permission(name) for name in self.perm_items}
        any_missing = not all(states.values())

        if any_missing and not self._perm_rows_visible:
            # Insert first, with the placeholder titles still in place —
            # rumps uses menuitem.title at the moment of insertion as
            # the menu's dict key, and our subsequent insert_after
            # calls (and the matching del when we hide) all reference
            # those stable placeholder keys. If we updated the visible
            # titles before inserting, the second insert_after would
            # not find its anchor, the exception would be swallowed by
            # rumps' callback wrapper, and the rows would never appear.
            # The user-visible titles are set by the trailing block
            # below once everything is in the menu.
            anchor = self._status_key
            for name in ("Microphone", "Accessibility", "Input Monitoring"):
                self.menu.insert_after(anchor, self.perm_items[name])
                anchor = self._perm_keys[name]
            self._perm_rows_visible = True

        elif (not any_missing) and self._perm_rows_visible:
            for name in self.perm_items:
                try:
                    del self.menu[self._perm_keys[name]]
                except KeyError:
                    pass
            self._perm_rows_visible = False

        # Keep titles + callbacks current while rows are showing.
        if self._perm_rows_visible:
            for name, item in self.perm_items.items():
                granted = states[name]
                if granted:
                    new_title = f"✓  {name} permission granted"
                elif self._perm_click_counts.get(name, 0) >= 1:
                    # User has clicked Grant at least once but the
                    # permission still hasn't taken. Tell them their
                    # click landed and prompt a retry — the click
                    # handler auto-resets TCC on the second attempt,
                    # which usually unsticks a stuck denial.
                    new_title = f"⚠  {name} stuck? Click again to reset and retry…"
                else:
                    new_title = f"⚠  Grant {name} permission…"
                if item.title != new_title:
                    item.title = new_title
                item.set_callback(None if granted else self._perm_callbacks[name])

    _dock_policy_applied = False

    def _apply_dock_visibility_once(self) -> None:
        """Sync the activation policy with self.show_in_dock at startup."""
        if self._dock_policy_applied:
            return
        self._apply_dock_visibility()
        self._dock_policy_applied = True

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
        self._apply_dock_visibility_once()
        self._update_permission_rows()
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
            # If a background warmup is still in flight on the worker, the
            # transcribe is queued behind it — surface that honestly instead
            # of pretending we're already transcribing.
            self.status_item.title = "Warming up…" if self.worker.warming else "Transcribing"
        elif self.recording:
            self.title = LABEL_REC
            self.status_item.title = "Recording"
        elif self.worker.warming:
            # User finished recording before the parallel warmup did, OR
            # warmup fired without an immediate transcribe. Either way,
            # be honest about what's holding things up.
            self.title = LABEL_BUSY
            self.status_item.title = "Warming up…"
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
