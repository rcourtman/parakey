# Parakey

Lightweight push-to-talk dictation for macOS Apple Silicon. Hold **Right
Control**, talk, release — your words get transcribed locally with
Parakeet-MLX and pasted at the cursor.

No cloud, no subscription. Lives in the menu bar. Auto-starts at login.

## Install

On a fresh Apple Silicon Mac:

```sh
brew install python ffmpeg
git clone <this-repo> ~/parakey
cd ~/parakey
./install.sh
```

`install.sh` is idempotent — re-run it any time to pick up new code or
template changes. It will:

1. Create a venv in `~/parakey/.venv` and install Python deps.
2. Build `~/Applications/Parakey.app` from `templates/`.
3. Generate `~/Library/LaunchAgents/com.local.parakey.plist` with paths
   substituted for the current user.
4. Codesign the bundle (Developer ID if available, ad-hoc otherwise).
5. (Re)load the LaunchAgent so Parakey starts immediately and at login.

After first install, grant **Microphone**, **Accessibility**, and **Input
Monitoring** to Parakey.app in System Settings → Privacy & Security,
then `launchctl kickstart -k gui/$(id -u)/com.local.parakey`.

## How it works

1. `pynput` listens for the hotkey (Right Control by default).
2. While held, `sounddevice` captures mic audio at 16 kHz mono and a tink
   confirms the listener is active. After 180 ms, the system audio
   output is muted so background music doesn't bleed into the recording
   (or distract you while talking).
3. On release, the audio is written to a temp WAV and transcribed by
   `parakeet-mlx` locally on the GPU (MLX / Metal).
4. The transcript is placed on the clipboard via `NSPasteboard` and a
   `Cmd+V` is posted via Quartz `CGEventPost` — both in-process, no
   subprocess overhead. A trailing space is appended.
5. System audio is unmuted and a pop sound plays.

The Right Control keystroke itself is suppressed via a Quartz event tap
so it doesn't trigger any other application shortcuts.

A 2-minute hard cap auto-releases if the hotkey is held too long.

## Layout

| Thing | Path |
|---|---|
| Code + venv | `~/parakey/` |
| App bundle | `~/Applications/Parakey.app` (Developer ID signed) |
| LaunchAgent | `~/Library/LaunchAgents/com.local.parakey.plist` |
| Logs | `~/parakey/parakey.log` (rotates at 1 MB to `.log.1`) |

## Menu bar

Status icons:

- 🎙 idle — ready
- 🔴 recording
- ⏳ transcribing
- ⏸ paused
- ⚠️ error

Menu items:

- **Status: …** — current state
- **Last: …** — preview of the most recent transcript
- **Copy last transcription** — re-copy the last result if a paste
  landed in the wrong place
- **Pause / Resume** — temporarily disable the hotkey
- **About Parakey** — version + model info
- **Quit** — clean shutdown (no auto-restart)

## Run

The LaunchAgent runs Parakey at login automatically. To restart manually:

```sh
launchctl kickstart -k gui/$(id -u)/com.local.parakey
```

To disable login start:

```sh
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.local.parakey.plist
```

To re-enable:

```sh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.local.parakey.plist
```

## Permissions

Granted once to `~/Applications/Parakey.app` in **System Settings →
Privacy & Security**:

- **Microphone**
- **Accessibility** (post Cmd+V via Quartz)
- **Input Monitoring** (Quartz event tap for the hotkey)

Because the bundle is Developer ID signed, these survive bundle
modifications: the TCC entry is keyed on signing identity + bundle ID,
not the exact binary hash.

## Customise

Edit constants at the top of `parakey.py`:

| Constant | Default | Notes |
|---|---|---|
| `MODEL_ID` | `mlx-community/parakeet-tdt-0.6b-v2` | Any Parakeet-MLX model on Hugging Face. |
| `HOTKEY` | `keyboard.Key.ctrl_r` | e.g. `keyboard.Key.f5` for F5. |
| `HOTKEY_KEYCODE` | `62` | macOS virtual keycode of the hotkey (used for event-tap suppression). Must match `HOTKEY`. |
| `MUTE_AFTER_TINK_SECONDS` | `0.18` | Delay before muting so the tink isn't clipped. |
| `MAX_RECORDING_SECONDS` | `120` | Auto-release if hotkey held too long. |
| `LOG_TRANSCRIPTS` | `False` | Set to `True` to log transcript content (debugging). |

`MODEL_ID` can also be overridden via the `PARAKEY_MODEL` env var.

After editing, restart with `launchctl kickstart -k gui/$(id -u)/com.local.parakey`.

### Common macOS keycodes

- Right Control: 62
- Left Control: 59
- Right Option: 61
- Left Option: 58
- F5: 96, F6: 97, F13: 105, F18: 79, F19: 80

## Re-signing the bundle

If you modify anything inside `~/Applications/Parakey.app/Contents/`
(the launcher script or `Info.plist`), the codesign signature breaks.
Re-sign with:

```sh
CERT="D2D9FAEC9256C65B08A6EE0275451E3307B73C98"  # Developer ID Application
codesign --force --deep --sign "$CERT" --options runtime --timestamp \
  ~/Applications/Parakey.app
codesign --verify --deep --strict ~/Applications/Parakey.app
```

Editing `~/parakey/parakey.py` itself doesn't require re-signing — that
file lives outside the bundle.

## Troubleshooting

- **Hotkey does nothing / no tink**: Input Monitoring not granted to
  Parakey.app. Toggle it in System Settings, then `launchctl kickstart
  -k gui/$(id -u)/com.local.parakey`.
- **Tink but no paste**: Accessibility not granted. Same drill.
- **No audio captured**: check Microphone in Privacy settings.
- **Slow first transcription**: model load + Metal kernel warmup. Both
  happen at startup now, so subsequent runs are fast.
- **Music doesn't pause**: parakey mutes the system *output*, it doesn't
  pause Spotify/Music. Background audio is silenced for the duration of
  the dictation, then unmuted.
