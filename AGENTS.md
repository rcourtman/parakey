# AGENTS.md

Briefing for AI coding agents working on this repo. Complements
`README.md` (for humans) and `CONTRIBUTING.md` (for contributors).

## Project shape

Parakey is a single-file Python menu-bar app for push-to-talk
dictation on Apple Silicon Macs. The hot path is:

1. `pynput` listens for the user's hotkey via a Quartz event tap.
2. While held, `sounddevice` captures mic audio at 16 kHz mono.
3. On release, the numpy buffer is fed straight into `parakeet-mlx`
   (`mx.array → get_logmel → model.generate`) — bypassing the
   ffmpeg/WAV round-trip the public `model.transcribe(path)` API
   would do.
4. The transcript goes to `NSPasteboard`, `Cmd+V` is posted via
   `Quartz.CGEventPost`, system audio is unmuted, done sound plays.

Key files:

| Path | Purpose |
|---|---|
| `parakey.py` | The whole app. ~1000 lines, single class `Parakey(rumps.App)`. |
| `bench.py` | Profiling script for the transcription pipeline. |
| `Parakey.spec` | PyInstaller config for the bundled `.app`. |
| `entitlements.plist` | Hardened-runtime entitlements (JIT, library validation, microphone). |
| `release.sh` | Build → sign → notarise → zip pipeline. |
| `install.sh` | Contributor dev install (venv + LaunchAgent + signed shell-launcher bundle). |
| `icon/` | SVG sources + generated `.icns` and menu-bar PNGs (see `make-icons.sh`). |
| `templates/` | Skeletons used by `install.sh` to generate the dev `Parakey.app` and LaunchAgent plist. |

## Build & test

There are no unit tests. Validation is:

```sh
# Type/syntax check
.venv/bin/python -c "import py_compile; py_compile.compile('parakey.py', doraise=True)"

# Performance regression check
.venv/bin/python bench.py

# Production bundle build (signs + notarises + zips)
./release.sh

# Dev install (uses Homebrew Python, fast iteration)
./install.sh

# Restart the dev install after editing parakey.py:
launchctl kickstart -k gui/$(id -u)/com.local.parakey
```

After the dev install is set up, you don't rebuild for code edits —
just edit `parakey.py` and `kickstart` to pick up changes.

CI runs Python + shell + plist syntax checks on push/PR (see
`.github/workflows/check.yml`). No macOS-specific tests run in CI.

## Conventions

- **Single file.** `parakey.py` is the whole app. Resist splitting
  unless something genuinely belongs in its own module (e.g. a real
  test suite). Adding files trades discoverability for organisation.
- **Type-hinted.** Method signatures and class attributes are
  annotated. Don't introduce untyped public API.
- **Comments are for the *why*.** The *what* should be obvious from
  the code; comments earn their place by explaining motivation
  (e.g. "we set HF_HUB_DISABLE_TELEMETRY before any HF import
  because…").
- **No transcript content in logs.** `LOG_TRANSCRIPTS = False` is
  the published default and the project's privacy claim. Only the
  log line containing the transcript text itself is gated; durations
  and length-in-chars are fine.
- **Settings persist via `NSUserDefaults`** with explicit
  `initWithSuiteName_("com.local.parakey")`. The running Python
  process inherits `org.python.python` as its bundle id, so
  `standardUserDefaults()` would write to the wrong domain when
  unbundled.
- **rumps menu items are tracked by their *initial* title.** If
  you `insert_after`/`del` items by stable placeholder keys, set
  the visible title *after* insertion. Setting the visible title
  before insertion makes the new title the menu key, breaking
  later insert_after calls — and rumps' callback wrapper swallows
  the exception silently.

## Out of scope

- **Cloud transcription backends.** Parakey is local-only by
  design. Audio never leaves the Mac (one-time exception: the model
  download from Hugging Face on first launch, with telemetry
  disabled).
- **Cross-platform.** Heavy macOS dependencies (NSPasteboard,
  NSAppleScript, Quartz event taps, MLX). Linux/Windows ports
  belong in separate forks if anyone wants to do them.
- **AI rewriting / cloud sync / preference windows.** The README's
  opener positions Parakey as "focused — push-to-talk dictation
  only, no extras." Don't grow the feature surface.
- **Drag-and-drop file transcription.** Considered and rejected;
  if added, evaluate it on its own merits, not as an excuse for
  the dock icon to do something.

## Privacy / security

- **`HF_HUB_DISABLE_TELEMETRY=1`** is set as the very first line of
  effective code in `parakey.py` (after stdlib imports). Before any
  HF-touching import. Don't move it.
- **Hardened-runtime entitlements** (in `entitlements.plist`) are:
  `cs.allow-jit`, `cs.allow-unsigned-executable-memory`,
  `cs.disable-library-validation`, `device.microphone`. Anything new
  expands TCC surface — justify before adding.
- **No network calls beyond model download.** If you add any HTTP
  client, document it and audit the URL list.
- **Transcripts are in-memory only.** A `collections.deque(maxlen=5)`
  rolling history clears on quit. Nothing is persisted.

## Release workflow

1. Bump `CFBundleShortVersionString` in `Parakey.spec`.
2. Edit `parakey.py` / etc.; commit.
3. `./release.sh` — produces `dist/Parakey.zip` (notarised).
   Capture the SHA256: `shasum -a 256 dist/Parakey.zip`.
4. `gh release create vX.Y.Z dist/Parakey.zip --title "Parakey X.Y.Z" --notes-file …`
5. Update [the brew tap](https://github.com/rcourtman/homebrew-parakey)'s
   `Casks/parakey.rb` with the new version + SHA. Push.
6. Smoke-test: `brew uninstall --cask parakey && brew install --cask rcourtman/parakey/parakey`.

## Common change recipes

- **Add a Settings toggle**: new key on `Settings` class, getter +
  setter via `NSUserDefaults`, menu item under the *Settings*
  submenu, click-handler that mirrors to `self.foo` and
  `self.settings.foo`.
- **Add a hotkey to the menu**: extend `HOTKEY_CHOICES` with
  `(display_name, pynput.keyboard.Key, macOS_keycode)`. The menu
  is built from the list automatically.
- **Change the default model**: `MODEL_ID` constant near the top.
  Or override at runtime via `PARAKEY_MODEL=…` env var.
