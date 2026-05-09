# Parakey

**Lightweight push-to-talk dictation for macOS Apple Silicon. Local, fast,
no subscription.**

Hold a hotkey, talk, release — your speech is transcribed locally with
[Parakeet-MLX](https://github.com/senstella/parakeet-mlx) and pasted at
the cursor. Lives in the menu bar. Auto-starts at login.

- **No cloud.** Audio never leaves your Mac.
- **No subscription.** MIT-licensed, ~400 lines of Python.
- **Lightweight.** One menu bar app, one launch agent, one model on
  disk.
- **Apple Silicon only.** The transcription runs on Metal via MLX.

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
   one-time only). Don't try to press Right Control yet.
6. Tell me to click the menu bar 🎙 once it appears. There will be
   three rows labelled "⚠ Grant Microphone permission…", "⚠ Grant
   Accessibility permission…", "⚠ Grant Input Monitoring
   permission…". Tell me to click each one — Parakey will trigger
   the macOS prompt and/or open the right Settings pane. I should
   click Allow on the macOS dialog, or toggle Parakey on in the
   Settings pane, for each of the three.
7. The rows turn ✓ as I grant each, and disappear from the menu
   once all three are granted.

Then I can hold Right Control to dictate.
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
before pressing Right Control.

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

Hold **Right Control**, talk, release. The transcript is pasted at the
cursor with a trailing space. A short tink confirms recording started;
a pop confirms it landed.

While the hotkey is held, system audio output is muted (so background
music doesn't bleed into the recording or distract you). It's restored
on release.

The menu bar icon reflects state: 🎙 idle / 🔴 recording / ⏳
transcribing / ⏸ paused.

Menu items:

- **Status** — current state
- **Last** — preview of the most recent transcript
- **Copy last transcription** — re-copy if a paste landed in the wrong
  place
- **Hotkey** — submenu to pick the dictation key (Right Control / Right
  Option / Right Command / F5 / F6 / F13 / F18 / F19)
- **Trigger mode** — *Press and hold* or *Press to toggle*
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

The Right Control keystroke itself is suppressed via the same event tap
so it doesn't trigger any other application shortcuts.

For a profile of where time is spent, run:

```sh
.venv/bin/python bench.py
```

## Customise

The two settings most users want are in the menu bar itself:

- **Hotkey** — Right Control (default), Right Option, Right Command, F5,
  F6, F13, F18, F19
- **Trigger mode** — *Press and hold* (default) or *Press to toggle*
  (click on / click off)

Both persist across restarts via `NSUserDefaults`
(`~/Library/Preferences/com.local.parakey.plist`) and you can also set
them via `defaults`:

```sh
defaults write com.local.parakey hotkey_keycode -int 105   # F13
defaults write com.local.parakey trigger_mode toggle
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
signed, optionally-notarised `Parakey.app` you can attach to a GitHub
Release. The bundle embeds Python and every dependency, so the running
executable lives inside `Parakey.app` and macOS identifies it as
Parakey throughout (TCC, Activity Monitor, notifications, etc.).

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

Logs land in `~/parakey/parakey.log` (rotated to `.log.1` at 1 MB).
Transcript content is **not** written to disk — only timing and length
metadata.

If you need to debug a specific transcription, set `LOG_TRANSCRIPTS =
True` in `parakey.py`, restart, reproduce, then flip it back.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Hotkey does nothing, no tink | Input Monitoring not granted to Parakey.app |
| Tink but no paste | Accessibility not granted |
| No audio captured | Microphone not granted, or wrong default input device |
| Slow first transcription | Model load + Metal kernel warmup happens at startup, but the first time after a fresh install also pulls the model from Hugging Face |
| Music doesn't pause, only quietens | Parakey mutes the system *output*, it doesn't pause Spotify/Music. The audio resumes on release. |

After granting any of the three permissions, restart the agent:

```sh
launchctl kickstart -k gui/$(id -u)/com.local.parakey
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
