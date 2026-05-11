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
| `parakey.py` | The app shell — menu, audio capture, hotkey, history, settings. |
| `inference_worker.py` | The single dedicated thread that owns the MLX model and runs every `generate()`. MLX (0.31.2+) requires load + use on the same thread; this enforces that and lets warmups run in parallel with the user speaking. |
| `warmup_gate.py` | Cold-after-idle state machine — `is_cold()`, `try_begin_warmup()`, `transcribe()`. Pure Python; unit-testable. |
| `update_check.py` | Pure helpers for the in-app updater: `parse_semver`, `find_brew`, `fetch_latest_release_tag`. Imports stdlib only so it runs on Linux CI. |
| `bench.py` | Steady-state transcription pipeline profile. |
| `bench_idle.py` | Cold-vs-warm + parallel-warmup-during-speak validation. Apple Silicon only. |
| `tests/` | `unittest` suites for `WarmupGate`, `InferenceWorker`, `update_check`. ~38 tests, run on Linux CI. |
| `Parakey.spec` | PyInstaller config for the bundled `.app`. |
| `entitlements.plist` | Hardened-runtime entitlements (JIT, library validation, microphone). |
| `release.sh` | Build → sign → notarise → zip pipeline. |
| `ship.sh` | One-command end-to-end release: version bump, build, tag, push, GitHub release, Homebrew Cask bump. |
| `install.sh` | Contributor dev install (venv + LaunchAgent + signed shell-launcher bundle). |
| `icon/` | SVG sources (`hero.svg`, `latency.svg`, `workflow.svg`, `menu-mockup.svg`, `parakey.svg`) + generated `.icns` and menu-bar PNGs. |
| `templates/` | Skeletons used by `install.sh` to generate the dev `Parakey.app` and LaunchAgent plist. |

## Build & test

Validation order — what `ship.sh` runs, and what you should run by hand
before pushing anything load-bearing:

```sh
# Type/syntax check
.venv/bin/python -c "import py_compile; py_compile.compile('parakey.py', doraise=True)"

# Unit tests (Linux-CI-friendly; no MLX needed)
.venv/bin/python -m unittest discover -s tests

# Steady-state transcription pipeline profile
.venv/bin/python bench.py

# Cold-vs-warm + parallel-warmup-during-speak (Apple Silicon required)
.venv/bin/python bench_idle.py

# Production bundle build (signs + notarises + zips)
./release.sh

# Or full end-to-end ship (version bump + build + tag + GitHub release + Cask):
./ship.sh --dry-run   # to validate the pipeline without pushing
./ship.sh             # actually ship

# Dev install (uses Homebrew Python, fast iteration)
./install.sh

# Restart the dev install after editing parakey.py:
launchctl kickstart -k gui/$(id -u)/com.local.parakey
```

After the dev install is set up, you don't rebuild for code edits —
just edit `parakey.py` and `kickstart` to pick up changes.

CI runs Python + shell + plist syntax checks AND the unit-test suite
on push/PR (see `.github/workflows/check.yml`). GPU-touching benches
must be run manually on Apple Silicon — they can't run in CI.

## Threading model — important

MLX (≥ 0.31.2) is strict about thread affinity: a model loaded on one
thread cannot be safely used from another. Calling `model.generate()`
from a thread that didn't load the model raises
`RuntimeError: There is no Stream(gpu, 0) in current thread` —
shape-dependently, so you might not catch it in casual testing.

Therefore: **all `model.generate()` calls go through
`InferenceWorker`**, which owns the model on its own thread plus a
`mx.new_thread_local_stream(mx.gpu)`. New inference paths (e.g. a
streaming mode, a model swap, batch transcription) must use the
worker's queue, never call `model.generate()` directly from another
thread.

This isn't a Parakey-specific choice — Apple's own `mlx-lm` server
hit the same wall and landed the same fix in
[ml-explore/mlx-lm#1090](https://github.com/ml-explore/mlx-lm/pull/1090).

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

- **Telemetry, analytics, crash reporting, "anonymous usage stats."**
  Zero — see *Privacy / security* below for the load-bearing
  invariant. Not "off by default", not "opt-in", not "just a UUID":
  **none**. This is the product's marketing position.
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

### Invariant: no telemetry, ever

Parakey ships with **no analytics, no event tracking, no error
reporting, no crash reporting, no "anonymous usage stats."** This is
a load-bearing product commitment — it's documented in the README's
opening privacy bullet, in the awesome-mac entry, in the
awesome-macOS entry, and in the in-app About copy. Users install
Parakey *specifically* because of it.

Do not add any of the following, regardless of how innocuous they
seem or how strong the "we'd just like to know how many people use
it" instinct is:

- A phone-home with a UUID or install ID (even one generated locally).
- Sentry / Bugsnag / Crashlytics / any third-party SDK.
- Apple's `MetricKit`, `os_log` with a custom subsystem, or any
  signpost the user can't audit by reading parakey.py.
- A "share usage stats" toggle, even default-off. Adding it normalises
  the conversation.
- Counting feature usage (which hotkey, which trigger mode, etc.) and
  pinging anywhere with it.
- Augmenting the existing GitHub update check with version info,
  platform info, or anything beyond the bare GET it does today.

If a future feature genuinely needs to ask the user something
specific, do it in a release note / on social — voluntary, in-context,
no infrastructure. If a bug needs reproduction info, GitHub issues
exist and produce higher-quality data than telemetry would anyway.

Substitutes for the questions telemetry would answer:

- **User count, version distribution** → GitHub Releases download
  counts (visible on the releases page), Homebrew's own analytics
  (`brew analytics` aggregates cask install counts).
- **Is anything crashing in the wild?** → GitHub issues. Watch
  download counts vs. issue volume.
- **Are people on the latest version?** → After a release ships, the
  in-app update check gives every running Parakey the chance to
  upgrade itself. Compare new vs. old release download counts.

### The exhaustive list of network calls Parakey makes

Anything added to this list expands the privacy surface and must be
documented here:

1. **First-launch model download** —
   `huggingface.co` (or `hf.co` via redirect). One-time, ~600 MB.
   `HF_HUB_DISABLE_TELEMETRY=1` is set as the very first line of
   effective code in `parakey.py` (after stdlib imports), before any
   HF-touching import. Don't move it.
2. **Update check** —
   `api.github.com/repos/rcourtman/parakey/releases/latest`, every
   `UPDATE_CHECK_INTERVAL_SECONDS` (6 h), first call 30 s after
   reaching "ready". Anonymous `GET`, no auth header, no identifier.
   User can disable via Settings → Check for updates.
3. **Update apply** —
   When the user clicks the in-menu update item on a brew install:
   shells out to `brew upgrade --cask parakey`, which then fetches
   `github.com/rcourtman/parakey/releases/download/...`. User-
   triggered, not background.

That is the entire list. If you're about to add a fourth, stop and
read the "Invariant: no telemetry" section above.

### Other privacy / security invariants

- **Hardened-runtime entitlements** (in `entitlements.plist`) are:
  `cs.allow-jit`, `cs.allow-unsigned-executable-memory`,
  `cs.disable-library-validation`, `device.microphone`. Anything new
  expands TCC surface — justify before adding.
- **Transcripts are in-memory only.** A `collections.deque(maxlen=5)`
  rolling history clears on quit. Nothing is persisted.
- **`LOG_TRANSCRIPTS = False`** is the published default and part of
  the privacy claim. Only flip to `True` locally for debugging — and
  even then, never commit logs to the repo or attach them to issues
  without redaction.

## Release workflow

The repo is agent-operated; releases happen via a single command so
there's nothing to remember between sessions. Make sure your edits
are committed on `main` (and pushed if you want CI to validate them
first), then:

```sh
./ship.sh                 # default: bump patch (0.1.1 → 0.1.2)
./ship.sh --minor         # 0.1.x → 0.2.0
./ship.sh --major         # 0.x.x → 1.0.0
./ship.sh --version 0.1.5 # explicit
./ship.sh --dry-run       # build everything, skip git/tag/release/cask
```

`ship.sh` does in order:

1. Pre-flight (clean tree on `main`, `gh` auth, sibling tap present)
2. Read current version from `Parakey.spec`, compute target, refuse
   if a tag for the target version already exists
3. Run `python -m unittest discover -s tests` — if the WarmupGate
   tests (or anything in `tests/`) fail, the release aborts before
   anything is touched
4. `py_compile` `parakey.py` / `warmup_gate.py` / `bench.py` /
   `bench_idle.py`
5. Rewrite `CFBundleShortVersionString` and `CFBundleVersion` in
   `Parakey.spec` (the latter monotonically increments)
6. Call `./release.sh` (PyInstaller → Developer ID sign → notarytool
   → ditto-zip). If this fails the Parakey.spec edit is reverted
7. Commit the version bump, tag `vX.Y.Z`, push `main` + tag
8. `gh release create` with `dist/Parakey.zip` as the asset; release
   notes are auto-generated from `git log <prev-tag>..<new-tag>`
9. Rewrite `version` + `sha256` in the sibling Homebrew tap's
   `Casks/parakey.rb`, commit, push

The tap lives at `../homebrew-parakey` by default; override with
`PARAKEY_HOMEBREW_TAP=/path/to/tap` if your layout differs.

**Recovery**: if `release.sh` fails, ship.sh reverts `Parakey.spec`
for you. If a later step (push, gh release, cask) fails, the build
artefact is still in `dist/Parakey.zip` — re-run the failed step
manually rather than re-running `ship.sh` (which would try to bump
the version a second time).

**One-time setup** (only needed on a fresh machine):

```sh
# Notary credentials so release.sh can notarise
xcrun notarytool store-credentials parakey-notary \
    --apple-id <YOUR_APPLE_ID> --team-id UJD57YVK2B \
    --password <APP_SPECIFIC_PASSWORD>

# GitHub CLI auth
gh auth login

# Sibling tap clone if you don't have it yet
git clone https://github.com/rcourtman/homebrew-parakey ../homebrew-parakey
```

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
