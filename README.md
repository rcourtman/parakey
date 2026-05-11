<p align="center">
  <img src="icon/hero.svg" alt="Parakey — Hold a key. Speak. Text appears." width="900">
</p>

<p align="center">
  <a href="https://github.com/rcourtman/parakey/releases/latest"><img src="https://img.shields.io/github/v/release/rcourtman/parakey?label=release&color=10B981" alt="Latest release"></a>
  <a href="https://github.com/rcourtman/parakey/actions/workflows/check.yml"><img src="https://github.com/rcourtman/parakey/actions/workflows/check.yml/badge.svg" alt="Build status"></a>
  <a href="https://github.com/rcourtman/parakey/blob/main/LICENSE"><img src="https://img.shields.io/github/license/rcourtman/parakey?color=10B981" alt="MIT licensed"></a>
  <img src="https://img.shields.io/badge/Apple%20Silicon%20%C2%B7%20macOS%2026%2B-10B981?color=10B981" alt="Apple Silicon · macOS 26+">
  <a href="https://github.com/rcourtman/homebrew-parakey"><img src="https://img.shields.io/badge/Homebrew-Cask-10B981?logo=homebrew&logoColor=white" alt="Homebrew Cask"></a>
</p>

# Parakey

**Push-to-talk dictation for Apple Silicon. Hold a key, speak, let go —
text appears at the cursor in about 100 milliseconds.**

Native Swift. Runs on the Apple Neural Engine via
[FluidAudio](https://github.com/FluidInference/FluidAudio) +
[Parakeet TDT v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3).
Local. No cloud. No subscription. No preferences window.

> **~100 ms transcription** · **2.2 MB download** · **~80 MB RAM** · **0% CPU between dictations**

<p align="center">
  <img src="icon/latency.svg" alt="End-to-end latency: press, speak, release — text appears in about 100 milliseconds." width="900">
</p>

- **Fast** — about **100 ms** from key release to pasted text on a
  typical 2–4 second clip. The encoder runs on the Apple Neural
  Engine, the decoder is a tiny autoregressive loop, and the paste
  is just `Cmd+V` on the general pasteboard — no IPC, no subprocess
  hop, no cloud round-trip. By the time a cloud service has
  finished its TLS handshake, your text is already at the cursor.
  See [`experiments/swift-bench/`](experiments/swift-bench/) for
  apples-to-apples comparisons against alternative backends on the
  same hardware.

- **Lightweight** — **2.2 MB** signed, notarised release zip.
  Uses about **80 MB of RAM** while idle and **0% CPU** between
  dictations — roughly the same memory as a single open Safari tab.
  Single AOT-compiled Swift binary, no embedded interpreter, no
  JIT, no library-validation override, no background daemon, no
  telemetry, no autostart. CoreML keeps the speech model on the
  Neural Engine itself, so the in-app memory footprint stays small
  even though the model is loaded and ready. Two hardened-runtime
  entitlements (microphone + audio-input); that's the whole
  sandbox surface.

- **Private** — audio is captured in memory, transcribed locally,
  and discarded. Nothing leaves your Mac during dictation. No
  telemetry, no accounts, transcripts are never written to disk.
  (Two narrow exceptions: the first launch downloads the speech
  model, and Parakey checks GitHub every six hours for a newer
  release. Both are anonymous; the second is toggleable in
  Settings.)

- **Free** — MIT-licensed open source. No trials, no premium tier,
  no upsell.

- **Minimal** — one menu-bar icon. No dock clutter by default. No
  preferences window — every setting lives in the menu's Settings
  submenu.

- **Focused** — push-to-talk dictation. No AI rewriting, no cloud
  sync, no extras.

The Parakeet TDT v3 weights (~600 MB) download once on first launch
into `~/Library/Application Support/FluidAudio/` and cache there;
nothing else to install.

Apple Silicon only. macOS 26 (Tahoe) or later.

## Requirements

- An Apple Silicon Mac (M1 or newer)
- macOS 26 (Tahoe) or later
- [Homebrew](https://brew.sh/) — only used by the installer for the
  Cask itself; Parakey has no other runtime dependencies

## Install (with an AI assistant)

Paste the prompt below into Claude Code, Cursor, Codex, or any shell-
capable agent running on the target Mac. It'll handle the Homebrew
install, walk you through the three permission grants, and explain
what to expect on first launch.

<details>
<summary>Click to expand the AI-assistant install prompt</summary>

````text
Install Parakey from https://github.com/rcourtman/parakey on this Mac.

Parakey is distributed as a notarised Homebrew Cask. Don't clone the
repo or build from source — `brew install --cask` is the canonical
end-user install path.

Steps:
1. Confirm this Mac is Apple Silicon (uname -m == arm64) and macOS 26+.
   If not, stop and tell me — Parakey is Apple Silicon only and
   requires macOS 26 (Tahoe).
2. Install Homebrew if missing (the installer at https://brew.sh).
3. Run:
     brew install --cask rcourtman/parakey/parakey
4. Launch the app:
     open /Applications/Parakey.app
5. Tell me the menu bar Parakey icon will appear shortly. First launch
   downloads a ~600 MB speech model from Hugging Face — this takes
   1–5 minutes on a typical connection, one-time only. Don't try the
   dictation key yet.
6. Once the icon appears, tell me to click it. Three rows will be
   visible: "⚠ Grant Microphone permission…", "⚠ Grant Accessibility
   permission…", "⚠ Grant Input Monitoring permission…". Tell me to
   click each one — Parakey will trigger the macOS prompt and/or
   open the right Settings pane. I should click Allow on the macOS
   dialog, or toggle Parakey on in Settings, for each of the three.
7. Rows turn ✓ as I grant each, and disappear from the menu once
   all three are granted.

Then the menu bar's status row will tell me which key to hold to
dictate. I can change it from Settings → Hotkey if I'd prefer
something else.

To upgrade later: Parakey checks GitHub every few hours and will
show an "Update to vX.Y.Z…" item at the top of its menu when a new
release is out — click it, the app handles the upgrade and relaunch.
The terminal fallback is still `brew upgrade --cask parakey` if I'd
rather drive it manually.
````

</details>

## Install (one-liner)

```sh
brew install --cask rcourtman/parakey/parakey
open /Applications/Parakey.app
```

That's it — the cask is signed and notarised, no Gatekeeper warnings.
First launch downloads the speech model (~600 MB, one-time). Click
the Parakey menu bar icon to grant the three macOS privacy permissions
when it asks.

To upgrade: just click **"Update to vX.Y.Z…"** when it appears at
the top of Parakey's menu — the app polls GitHub for new releases
every few hours and handles the upgrade and relaunch itself. Or run
`brew upgrade --cask parakey` manually if you prefer the terminal.

To uninstall:

```sh
brew uninstall --zap --cask parakey   # also removes preferences + logs
```

## Install (from source, for contributors)

If you want to hack on the code:

```sh
git clone https://github.com/rcourtman/parakey.git ~/parakey
cd ~/parakey/swift
./dev-run.sh
```

`dev-run.sh` is idempotent — re-run it any time. It compiles
`Sources/Parakey/main.swift` with `swift build`, wraps the binary in
a minimal `/tmp/Parakey-dev.app`, signs it with your Developer ID +
hardened runtime + the production entitlements (so TCC permissions
carry over from the Cask install — no manual re-grants), kills any
prior dev instance, and relaunches via `open`.

Requirements: Xcode 16+ (or the Swift 6.3+ toolchain) and a
Developer ID Application certificate in your keychain. The first
build also pulls FluidAudio from SwiftPM and downloads the Parakeet
TDT v3 CoreML weights (~600 MB, cached to `~/Library/Application
Support/FluidAudio/`).

To produce the notarised release build that ships on Homebrew:
`./ship-swift.sh --dry-run` first (see *Building a release* below).

## First launch

The first time Parakey runs, it downloads the Parakeet TDT v3 model
(~600 MB) from Hugging Face into
`~/Library/Application Support/FluidAudio/`. This is a one-time
download — subsequent launches load the cached CoreML weights and
are ready in well under a second. During the download the menu bar
icon shows a "loading…" indicator; there's no progress bar (yet), so
allow 1–5 minutes on a typical connection before pressing your
dictation key.

## Permissions

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

The menu bar icon reflects state via macOS's template-image tinting:
the parakeet glyph in the bar's normal label colour when idle, dimmed
while loading, **red** while recording, **yellow** if something went
wrong.

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
  - **Microphone** — System default (default) or any specific input
    device. Switching takes effect immediately. If the saved device
    is later unplugged, Parakey falls back to system default.
  - **Mute system audio while recording** — on by default; turn off
    if you'd rather music keep playing while you dictate
  - **Show Parakey in Dock** — off by default (menu-bar only)
- **Pause / Resume** — temporarily disable the hotkey
- **About Parakey**
- **Quit** — clean shutdown

A 2-minute hard cap auto-releases if the hotkey is held too long.

## How it works

1. A Quartz `CGEventTap` listens for the hotkey (modifier keys via
   `flagsChanged`, regular keys via `keyDown`/`keyUp`).
2. While held, an `AVAudioEngine` input tap captures mic audio and an
   `AVAudioConverter` resamples it to 16 kHz mono Float32 on the fly.
3. On release, the buffer is handed to a `TranscriptionWorker` actor
   that owns FluidAudio's `AsrManager`. The Parakeet TDT v3 CoreML
   models run on the Apple Neural Engine; the encoder is the bound
   work, the TDT decoder is autoregressive but tiny.
4. The transcript is placed on `NSPasteboard` and `Cmd+V` is posted
   via `CGEvent`. System audio is unmuted via `NSAppleScript` and the
   "Pop" system sound plays.

The chosen hotkey itself is suppressed via the same event tap so it
doesn't trigger any other application shortcuts.

For latency / accuracy numbers and the test methodology, see
[`experiments/swift-bench/`](experiments/swift-bench/).

## Customise

Most settings live in the menu's **Settings** submenu (described
above). All — **Hotkey**, **Trigger mode**, **Mute system audio while
recording**, **Show Parakey in Dock**, **Check for updates
automatically** — persist across restarts via `NSUserDefaults`
(`~/Library/Preferences/com.local.parakey.plist`).

Power users can also poke them via `defaults` directly:

```sh
defaults write com.local.parakey hotkey_keycode -int 105   # F13
defaults write com.local.parakey trigger_mode toggle
defaults write com.local.parakey mute_while_recording -bool false
defaults write com.local.parakey show_in_dock -bool true
defaults write com.local.parakey input_device "AirPods Pro"  # exact device name
defaults write com.local.parakey check_for_updates -bool false
# Then quit + relaunch Parakey to pick up settings that affect startup
# (most apply live; restart is only needed for the Dock toggle).
```

For deeper changes, constants live at the top of
`swift/Sources/Parakey/main.swift`:

| Constant | Default | Notes |
|---|---|---|
| `MIN_CLIP_SECONDS` | `0.25` | Recordings shorter than this are discarded (treated as accidental key-tap). |
| `MAX_RECORDING_SECONDS` | `120` | Auto-release if the hotkey is held longer. |
| `MUTE_AFTER_START_SOUND` | `0.18` | Delay before muting so the start sound isn't clipped. |
| `HISTORY_SIZE` | `5` | Rolling in-memory transcript history (cleared on quit). |
| `UPDATE_CHECK_INTERVAL_SECONDS` | `21600` (6 h) | How often the app polls GitHub for a newer release. |

After editing, rebuild + relaunch via `swift/dev-run.sh`.

## Updates

Parakey checks GitHub for a newer release every 6 hours (plus one
check 30 seconds after launch). When a newer version is published,
an **"Update to vX.Y.Z"** submenu appears at the top of the menu:

- **What's new…** — opens the release notes in a dialog with a link
  out to the full GitHub release page.
- **Update now…** — runs `brew upgrade --cask parakey` in a detached
  shell helper and re-opens the app once the upgrade finishes. No
  terminal needed.
- **Skip vX.Y.Z** — suppresses *just this version* without disabling
  the periodic check. A newer release published later still surfaces.

You can also force an immediate check via **Settings → Check for
updates now…**, and disable the periodic poll entirely via **Settings
→ Check for updates automatically**.

What the update check sends: one anonymous HTTPS `GET` to
`api.github.com/repos/rcourtman/parakey/releases/latest`. No
identifier, no telemetry, no user-agent fingerprint beyond Swift's
URLSession default. The release body (used by **What's new**) stays
in memory and is never written to disk. Skipped-version choices are
stored locally in `NSUserDefaults`.

Source / non-brew installs: the update item still appears when a
newer release exists, but **Update now…** opens the GitHub releases
page in your browser rather than touching your local checkout.

## Building a release (maintainers)

`swift/dev-run.sh` is the *contributor* path — fast iteration, debug
build, dropped into `/tmp/Parakey-dev.app`.

`ship-swift.sh` is the *distribution* path — produces a self-contained,
signed, **notarised**, drag-installable `Parakey.app`. The bundle is
a thin wrapper around a single Mach-O Swift binary plus the menu-bar
PNGs and `.icns`; the CoreML weights are downloaded by FluidAudio on
first launch rather than embedded, so the ship-zip stays under 3 MB.

```sh
./ship-swift.sh --dry-run   # build + sign + notarise check, skip git/tag/release/cask
./ship-swift.sh             # actually ship (bumps patch: 0.2.x → 0.2.x+1)
./ship-swift.sh --minor     # 0.2.x → 0.3.0
./ship-swift.sh --major     # 0.x.x → 1.0.0
./ship-swift.sh --version 0.2.3
```

If a release-notes file exists at `swift/release-notes/v<new_version>.md`,
ship-swift.sh uses it for the GitHub release body; otherwise the body
is auto-generated from `git log <prev-tag>..<new-tag>`.

Outputs:

- `swift/dist/Parakey.app` — signed, notarised, ready for Homebrew Cask
- `swift/dist/Parakey.zip` — the ditto-zipped bundle that GitHub
  Releases serves (≈2.2 MB; the version is in the GitHub release tag,
  not the filename)

### Notarisation (one-time setup)

Without notarisation, macOS Gatekeeper warns end users on first launch.
To enable notarisation in `ship-swift.sh`, run once:

```sh
xcrun notarytool store-credentials parakey-notary \
    --apple-id <YOUR_APPLE_ID> \
    --team-id  UJD57YVK2B \
    --password <APP_SPECIFIC_PASSWORD>
```

Generate the app-specific password at
[appleid.apple.com](https://appleid.apple.com) → *Sign-In and Security
→ App-Specific Passwords*. After this, every `./ship-swift.sh` run will
notarise + staple automatically.

## Logging

Parakey writes to `~/Library/Logs/Parakey.log`. The dev binary built
by `swift/dev-run.sh` writes to the same file (same bundle id), so a
single `tail -f` follows both.

Transcript content is **never** written to disk — only timing and
length metadata. There's no opt-in debug flag for logging
transcripts; the only way to see what the model heard is to read the
in-memory history from the menu while the app is still running.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Hotkey does nothing, no tink | Input Monitoring not granted (check the menu — the row will reappear as ⚠) |
| Tink but no paste | Accessibility not granted |
| Mic captures silence (transcripts come back as 0 chars) | Microphone not granted |
| Menu bar shows "loading…" for several minutes on first launch | First-run model download from Hugging Face (~600 MB). One-time. |
| Music doesn't pause, only quietens | Parakey mutes system *output*, it doesn't pause Spotify/Music. Resumes on release. |
| The Parakey.app you downloaded won't open | Confirm Apple Silicon + macOS 26+. If it's an older release from before notarisation was set up, you may hit a Gatekeeper warning — right-click → Open → Open. |

The in-menu permission rows surface most permission issues directly —
if you see ⚠ rows, click them. If you've toggled permissions in
Settings outside the app, the rows update within ~100 ms.

If you've granted permissions but the macOS TCC database is stale,
clicking a ⚠ row twice in a row triggers `tccutil reset` on that
service for `com.local.parakey` — re-grant on the prompt that follows.

## Uninstall

```sh
brew uninstall --zap --cask parakey
```

`--zap` also clears `~/Library/Preferences/com.local.parakey.plist`
and `~/Library/Logs/Parakey.log`.

Optionally also remove the cached speech model:

```sh
rm -rf ~/Library/Application\ Support/FluidAudio/
```

And revoke permissions in System Settings → Privacy & Security.

## Support

Parakey is free and will stay free — same app whether or not you
sponsor, no upsells, no nag screens, no premium tier. But if it
saves you time and you'd like to throw a coffee my way as
encouragement, the buttons are here:

[![GitHub Sponsors](https://img.shields.io/github/sponsors/rcourtman?label=Sponsor&logo=github)](https://github.com/sponsors/rcourtman)
[![Ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/rcourtman)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Bug reports and PRs welcome.

## License

MIT — see [LICENSE](LICENSE).

## Acknowledgements

- [FluidAudio](https://github.com/FluidInference/FluidAudio) by
  FluidInference — the Swift ASR SDK that runs Parakeet on the Apple
  Neural Engine.
- [Parakeet TDT v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)
  by NVIDIA — the underlying speech-recognition model.
