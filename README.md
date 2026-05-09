# Parakey

**Push-to-talk dictation for macOS Apple Silicon. Hold a key, speak,
let go — text appears at the cursor in well under a second.**

Local transcription via [Parakeet-MLX](https://github.com/senstella/parakeet-mlx).
No cloud, no subscription, no preferences window.

- **Fast** — under 200 ms from key release to pasted text on a
  typical 3-second clip. Local inference on your Mac's GPU; no
  network round-trip.
- **Private** — audio is captured in memory, transcribed locally,
  and discarded. Nothing leaves your Mac during dictation. No
  telemetry, no accounts, transcripts are never written to disk.
  (One-time exception: the first launch downloads the speech model
  from Hugging Face. Hugging Face's own usage telemetry is disabled
  by Parakey at startup via `HF_HUB_DISABLE_TELEMETRY=1`.)
- **Free** — MIT-licensed open source. No trials, no premium tier,
  no upsell.
- **Minimal** — one menu-bar icon. No dock clutter by default. No
  preferences window — every setting lives in the menu's Settings
  submenu.
- **Focused** — push-to-talk dictation. No AI rewriting, no cloud
  sync, no extras.

Apple Silicon only. macOS 13+.

## Requirements

- An Apple Silicon Mac (M1 or newer)
- macOS 13 (Ventura) or later
- [Homebrew](https://brew.sh/) for installing `python` and `ffmpeg`

## Install (with an AI assistant)

Paste this into Claude Code, Cursor, Codex, or any shell-capable agent
running on the target Mac:

````text
Install Parakey from https://github.com/rcourtman/parakey on this Mac.

This is a GitHub repo — clone it, don't search locally first.

Steps:
1. Confirm this Mac is Apple Silicon (uname -m == arm64) and macOS 13+.
   If not, stop.
2. Install Homebrew if missing, then `brew install python ffmpeg`
   (skip whichever are already installed).
3. `git clone https://github.com/rcourtman/parakey.git ~/parakey`
   (or `git -C ~/parakey pull` if it already exists).
4. `cd ~/parakey && ./install.sh`. The installer is idempotent.
5. After install.sh finishes, tell me that the menu bar icon will
   appear shortly (it loads a 600 MB model from Hugging Face on
   first launch — this takes 1–5 minutes on a typical connection,
   one-time only). Don't try to press the dictation key yet.
6. Tell me to click the menu bar 🎙 once it appears. There will be
   three rows labelled "⚠ Grant Microphone permission…", "⚠ Grant
   Accessibility permission…", "⚠ Grant Input Monitoring
   permission…". Tell me to click each one — Parakey will trigger
   the macOS prompt and/or open the right Settings pane. I should
   click Allow on the macOS dialog, or toggle Parakey on in the
   Settings pane, for each of the three.
7. The rows turn ✓ as I grant each, and disappear from the menu
   once all three are granted.

Then I can hold Right Option to dictate (or change the key from
Settings → Hotkey in the menu bar).
````

## Install (manually)

```sh
brew install python ffmpeg
git clone https://github.com/rcourtman/parakey.git ~/parakey
cd ~/parakey
./install.sh
```

`install.sh` is idempotent — re-run it any time you pull updates. It
will:

1. Create a venv at `~/parakey/.venv` and install Python deps.
2. Build `~/Applications/Parakey.app` from the templates.
3. Generate `~/Library/LaunchAgents/com.local.parakey.plist`.
4. Codesign the bundle. If you have a Developer ID Application
   certificate, it'll be used automatically; otherwise the bundle is
   ad-hoc signed (which still works, just less stable across rebuilds).
5. Load the LaunchAgent so Parakey starts now and at every login.

### First launch

The first time Parakey runs, it downloads the Parakeet-TDT-0.6B model
(~600 MB) from Hugging Face into `~/.cache/huggingface/`. This is a
one-time download — subsequent launches start in seconds. During the
download the menu bar icon shows a "loading…" indicator; there's no
progress bar (yet), so allow 1–5 minutes on a typical connection
before pressing your dictation key.

### Permissions

Parakey needs three macOS privacy permissions: **Microphone**,
**Accessibility**, and **Input Monitoring**. Until they're all
granted, the menu bar dropdown shows three rows like
**⚠ Grant Microphone permission…** just below the status row.

For each missing permission:

1. Click the ⚠ row in the menu — Parakey triggers the OS-level
   request (you may see a native "Parakey wants access" dialog) and
   opens the relevant Settings pane as a fallback.
2. Toggle Parakey on in the Settings pane if it isn't already.
3. The row updates to ✓ as soon as macOS reflects the new state, and
   once all three are granted the rows collapse out of the menu
   entirely.

No restart needed.

## Usage

Hold **Right Option** (the default — change in Settings → Hotkey if
you'd prefer something else), talk, release. The transcript is pasted
at the cursor with a trailing space. A short tink confirms recording
started; a pop confirms it landed.

While the hotkey is held, system audio output is muted (so background
music doesn't bleed into the recording or distract you). It's restored
on release.

The menu bar icon reflects state: 🎙 idle / 🔴 recording / ⏳
transcribing / ⏸ paused.

Menu structure:

- **Status row** — what Parakey is doing right now (idle / recording /
  transcribing / paused / loading).
- **Permission rows** (only when something's missing) — a clickable
  ⚠ row per ungranted permission. Click → grant → row turns ✓ →
  rows disappear once all three are granted.
- **Recent transcripts** — the most recent one inline (click to copy
  it back to the clipboard); a **Recent** submenu appears once
  you've dictated more than once and holds the previous four. The
  whole transcript history is in-memory only and clears when you
  quit Parakey.
- **Settings** ▶
  - **Hotkey** — Right Option (default), Right Control, Right
    Command, F5, F6, F13, F18, F19
  - **Trigger mode** — *Press and hold* or *Press to toggle*
  - **Mute system audio while recording** — on by default; turn off
    if you'd rather music keep playing while you dictate
  - **Show Parakey in Dock** — off by default (menu-bar only)
- **Pause / Resume** — temporarily disable the hotkey
- **About Parakey**
- **Quit** — clean shutdown (no auto-restart)

A 2-minute hard cap auto-releases if the hotkey is held too long.

## How it works

1. `pynput` listens for the hotkey via a Quartz event tap.
2. While held, `sounddevice` captures mic audio at 16 kHz mono.
3. On release, the audio buffer is fed straight to `parakeet-mlx` —
   `numpy → mlx.array → get_logmel → model.generate` — bypassing the
   ffmpeg/WAV round-trip the public API would normally use.
4. The transcript is placed on the clipboard via `NSPasteboard` and
   `Cmd+V` is posted via `Quartz.CGEventPost` — both in-process, no
   subprocess overhead.
5. System audio is unmuted and a confirmation sound plays.

The chosen hotkey itself is suppressed via the same event tap so it
doesn't trigger any other application shortcuts.

For a profile of where time is spent, run:

```sh
.venv/bin/python bench.py
```

## Customise

Most settings live in the menu's **Settings** submenu (described
above). All four — **Hotkey**, **Trigger mode**, **Mute system audio
while recording**, **Show Parakey in Dock** — persist across restarts
via `NSUserDefaults`
(`~/Library/Preferences/com.local.parakey.plist`).

Power users can also poke them via `defaults` directly:

```sh
defaults write com.local.parakey hotkey_keycode -int 105   # F13
defaults write com.local.parakey trigger_mode toggle
defaults write com.local.parakey mute_while_recording -bool false
defaults write com.local.parakey show_in_dock -bool true
launchctl kickstart -k gui/$(id -u)/com.local.parakey
```

For deeper changes, constants live at the top of `parakey.py`:

| Constant | Default | Notes |
|---|---|---|
| `MODEL_ID` | `mlx-community/parakeet-tdt-0.6b-v2` | Any Parakeet-MLX model on Hugging Face. Also overridable via `PARAKEY_MODEL` env var. |
| `MUTE_AFTER_TINK_SECONDS` | `0.18` | Delay before muting so the start sound isn't clipped. |
| `MAX_RECORDING_SECONDS` | `120` | Auto-release if the hotkey is held longer. |
| `LOG_TRANSCRIPTS` | `False` | Set to `True` to log transcript content (debugging). |

After editing, restart with `launchctl kickstart -k gui/$(id -u)/com.local.parakey`.

## Building a release (maintainers)

`install.sh` is the *contributor* path — fast iteration, uses your
system Python, slightly leaky on macOS-bundle identity.

`release.sh` is the *distribution* path — produces a self-contained,
signed, **notarised**, drag-installable `Parakey.app`. The bundle
embeds Python and every dependency, so the running executable lives
inside `Parakey.app` and macOS identifies it as Parakey throughout
(TCC, Activity Monitor, notifications, etc.). Once notarisation is
set up (one-time, see below), every run signs + uploads + staples
automatically.

```sh
./release.sh
```

Outputs:

- `dist/Parakey.app` — signed, ready to drag into `/Applications/`
- `dist/Parakey.zip` — the same bundle zipped, suitable for upload to
  GitHub Releases (≈145 MB)

### Notarisation (one-time setup)

Without notarisation, macOS Gatekeeper warns end users on first launch.
To enable notarisation in `release.sh`, run once:

```sh
xcrun notarytool store-credentials parakey-notary \
    --apple-id <YOUR_APPLE_ID> \
    --team-id  UJD57YVK2B \
    --password <APP_SPECIFIC_PASSWORD>
```

Generate the app-specific password at
[appleid.apple.com](https://appleid.apple.com) → *Sign-In and Security
→ App-Specific Passwords*. After this, every `./release.sh` run will
notarise + staple automatically.

## Re-signing the bundle

Editing `parakey.py` doesn't break the signature — that file lives
outside the bundle. But editing anything inside
`~/Applications/Parakey.app/Contents/` (the launcher script or
`Info.plist`) does. Easiest path: re-run `./install.sh`, which
re-signs.

To pin a specific signing identity, set `PARAKEY_CODESIGN_IDENTITY`:

```sh
PARAKEY_CODESIGN_IDENTITY="Developer ID Application: My Name (ABC123XYZ)" ./install.sh
```

Otherwise the first `Developer ID Application:` certificate in your
keychain is used, falling back to ad-hoc.

## Logging

Two log files depending on which install path you used:

- `~/parakey/parakey.log` — the dev install (`./install.sh`) writes
  here; rotated to `.log.1` at 1 MB.
- `~/Library/Logs/Parakey.log` — the bundled `.app` (`./release.sh`,
  or a downloaded release) writes here.

Transcript content is **not** written to disk in either case — only
timing and length metadata. If you need to debug a specific
transcription, set `LOG_TRANSCRIPTS = True` in `parakey.py`, restart,
reproduce, then flip it back.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Hotkey does nothing, no tink | Input Monitoring not granted (check the menu — the row will reappear as ⚠) |
| Tink but no paste | Accessibility not granted |
| Mic captures silence (transcripts come back as 0 chars) | Microphone not granted |
| Menu bar shows "loading…" for several minutes on first launch | First-run model download from Hugging Face (~600 MB). One-time. |
| Music doesn't pause, only quietens | Parakey mutes system *output*, it doesn't pause Spotify/Music. Resumes on release. |
| The Parakey.app you downloaded won't open | Confirm Apple Silicon + macOS 13+. If it's an older release before notarisation was set up, you may hit a Gatekeeper warning — right-click → Open → Open. |

The in-menu permission rows surface most permission issues directly —
if you see ⚠ rows, click them. If you've toggled permissions in
Settings outside the app, the rows update within ~100 ms.

If you've edited bundle internals or settings via `defaults` and need
a clean restart:

```sh
launchctl kickstart -k gui/$(id -u)/com.local.parakey   # dev install
# or just quit + relaunch Parakey.app from /Applications/         (bundled)
```

## Uninstall

```sh
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.local.parakey.plist
rm -rf ~/Applications/Parakey.app
rm -f  ~/Library/LaunchAgents/com.local.parakey.plist
rm -rf ~/parakey  # only if you cloned here and want it gone
```

Optionally also remove the model cache:

```sh
rm -rf ~/.cache/huggingface/hub/models--mlx-community--parakeet-tdt-0.6b-v2
```

And revoke permissions in System Settings → Privacy & Security.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Bug reports and PRs welcome.

## License

MIT — see [LICENSE](LICENSE).

## Acknowledgements

- [Parakeet-MLX](https://github.com/senstella/parakeet-mlx) by Senstella
  for the MLX port of NVIDIA's Parakeet-TDT.
- [rumps](https://github.com/jaredks/rumps) for the menu bar
  scaffolding.
- [pynput](https://github.com/moses-palmer/pynput) for the global
  hotkey + Quartz event tap.
