# Parakey (Swift)

Native Swift successor to `parakey.py`. Same UX (menu bar push-to-talk
dictation), native AppKit / AVFoundation / Speech APIs, FluidAudio's
Parakeet TDT v3 running on the Apple Neural Engine.

**Status:** MVP. Boots, loads the model, captures audio, transcribes,
pastes at cursor. Settings UI, About dialog, history, in-app updater,
and skip-version semantics are not ported yet — see the parent
[`parakey.py`](../parakey.py) for the behavioural spec on each of
those.

## Why this exists

Most of the entitlement / TCC bugs we fought on the Python side were
*Python's fault* — running an embedded interpreter from a bundled
`.app` puts you on the unhappy path with macOS's security model.
Going native sidesteps that entire class of problem. We also pick up
~1.5–2× inference latency improvement (measured in
[`experiments/swift-bench/`](../experiments/swift-bench/README.md))
and an ANE power-efficiency win on laptops.

## Build

Requires:

- macOS 26 (Tahoe) — `SpeechAnalyzer` and FluidAudio's CoreML
  targeting depend on it.
- Xcode 16 / Swift 6.3 or later (`swift --version` to check).
- The same Developer ID + notary credentials set up for the Python
  release path (only matters for shipping, not for local builds).

```sh
cd swift
swift build               # debug build at .build/debug/Parakey
swift build -c release    # optimised build at .build/release/Parakey
```

First launch downloads the ~600 MB Parakeet TDT v3 CoreML model from
HuggingFace into `~/Library/Application Support/FluidAudio/Models/`.
Subsequent launches use the cache.

## Run (locally, for development)

```sh
./.build/debug/Parakey
```

The first time you launch:

1. CoreML compiles the Encoder `.mlmodelc` for ANE — this takes
   ~15 s on a clean cache. You'll see `ASR: ready in X.XX s` in
   `~/Library/Logs/Parakey.log` when it's done.
2. macOS prompts for **Microphone** access the first time the audio
   engine reads from the input node.
3. **Accessibility** and **Input Monitoring** need to be granted
   manually in System Settings → Privacy & Security — the menu
   shows "⚠ Grant … permission…" rows that open the right pane.
   Because this is an unsigned debug binary, it shows up in the
   Settings list by binary path, not by bundle ID.

## How it works

A single `main.swift` for now — same "one big file" convention as
`parakey.py`. Layout:

| Section | Purpose |
|---|---|
| `Logger` | Stamps stderr + writes to `~/Library/Logs/Parakey.log` (same path the Python app uses, so the file is interchangeable). |
| `Permissions` | Reads TCC status for Microphone (`AVCaptureDevice`), Accessibility (`AXIsProcessTrusted`), and Input Monitoring (`CGPreflightListenEventAccess`). Mirrors the Python `_check_permission` / `_request_permission` pair. |
| `HotkeyListener` | A `cgSessionEventTap` watching `flagsChanged` so it can detect Right Option press / release as a modifier-key event (no `keyDown` for modifiers). |
| `AudioCapture` | `AVAudioEngine` with an input-node tap that downmixes to 16 kHz mono Float32 via `AVAudioConverter` and accumulates into a buffer while recording. |
| `TranscriptionWorker` | A Swift `actor` that owns FluidAudio's `AsrManager`. The actor's serial executor plays the same role `inference_worker.py` plays in the Python app — single-threaded ownership of the model, no cross-thread access. |
| `Paster` | Writes to `NSPasteboard.general`, posts `Cmd+V` via `CGEvent`. Same as Python `paste_text()`. |
| `ParakeyApp` | `NSApplicationDelegate`. Sets up `NSStatusItem`, loads ASR *first*, then starts hotkey + audio. |

## A non-obvious lesson learned

**Load the ASR model *before* starting the audio engine.** If
AVAudioEngine.start() runs first, the subsequent CoreML compile of
the ANE-targeted Encoder model hangs indefinitely on first launch.
The bench ([`experiments/swift-bench/`](../experiments/swift-bench/))
doesn't see this because it never opens an audio session before
loading the model.

## What's missing vs `parakey.py`

Roughly in priority order for what to port next:

- **Settings UI** — hotkey choice, trigger mode (hold vs toggle),
  microphone choice, mute system audio while recording, dock
  visibility, "check for updates" toggle.
- **About dialog** with version + attribution.
- **History** — last 5 transcripts in a submenu, copy to clipboard.
- **In-app updater** — GitHub Releases poll, "Update to vX.Y.Z"
  submenu with What's new / Update now / Skip vX.Y.Z (port of the
  v0.1.7 commits on `main`).
- **Sounds** — start "tink" and done "pop" cues.
- **Mute system audio while recording** — AppleScript bridge.
- **Auto-recover-stale-TCC-on-upgrade** — same heuristic, in Swift.
- **Click-twice-to-reset retry** — same heuristic, in Swift.
- **Hardened-runtime entitlements** — `audio-input`, `microphone`,
  no JIT / library validation entitlements needed since this is
  native Swift, not a bundled Python interpreter.
- **`ship-swift.sh`** equivalent — version bump, `swift build -c
  release`, sign + notarise + zip + tag + GitHub release + cask
  bump. The Python `ship.sh` is a clean template.

## Coexistence with `parakey.py`

The Python app continues to live in the repo root. While the Swift
version is reaching parity, both can be developed in parallel: the
Python version stays as the reference implementation for behavior
and as the currently-shipped Cask. When Swift reaches v0.1.6 feature
parity, the Cask formula is updated to ship the Swift binary, and
the Python tree gets removed in a separate cleanup commit.

Run two Parakey instances at once is *not* a supported configuration
— both would register CGEventTaps for the same hotkey and fight over
audio + paste. For dev testing, `pkill -f "/Applications/Parakey.app"`
before launching the Swift build, then re-`open
/Applications/Parakey.app` when done.
