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

## Install

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

The first time the app runs it downloads the Parakeet-TDT-0.6B model
(~600 MB) into `~/.cache/huggingface/`. Subsequent launches are
instant.

### Permissions

After the first install, macOS will need three permissions granted to
**Parakey.app** in **System Settings → Privacy & Security**:

- **Microphone** — to record while the hotkey is held
- **Accessibility** — to send Cmd+V via Quartz events
- **Input Monitoring** — for the global hotkey listener

If a prompt is missed, add Parakey.app manually in each pane, then:

```sh
launchctl kickstart -k gui/$(id -u)/com.local.parakey
```

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

Constants live at the top of `parakey.py`:

| Constant | Default | Notes |
|---|---|---|
| `MODEL_ID` | `mlx-community/parakeet-tdt-0.6b-v2` | Any Parakeet-MLX model on Hugging Face. Also overridable via `PARAKEY_MODEL` env var. |
| `HOTKEY` | `keyboard.Key.ctrl_r` | e.g. `keyboard.Key.f5`. |
| `HOTKEY_KEYCODE` | `62` | macOS virtual keycode of the hotkey (used to suppress the keystroke). Must match `HOTKEY`. |
| `MUTE_AFTER_TINK_SECONDS` | `0.18` | Delay before muting so the start sound isn't clipped. |
| `MAX_RECORDING_SECONDS` | `120` | Auto-release if the hotkey is held longer. |
| `LOG_TRANSCRIPTS` | `False` | Set to `True` to log transcript content (debugging). |

After editing, restart with `launchctl kickstart -k gui/$(id -u)/com.local.parakey`.

### Common macOS keycodes

- Right Control: 62 · Left Control: 59
- Right Option: 61 · Left Option: 58
- F5: 96 · F6: 97 · F13: 105 · F18: 79 · F19: 80

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
