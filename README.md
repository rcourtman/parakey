<p align="center">
  <img src="icon/hero.svg" alt="Parakey — fast, lightweight local dictation for Apple Silicon." width="900">
</p>

<p align="center">
  <a href="https://github.com/rcourtman/parakey/releases/latest"><img src="https://img.shields.io/github/v/release/rcourtman/parakey?label=release&color=10B981" alt="Latest release"></a>
  <a href="https://github.com/rcourtman/parakey/actions/workflows/check.yml"><img src="https://github.com/rcourtman/parakey/actions/workflows/check.yml/badge.svg" alt="Build status"></a>
  <a href="https://github.com/rcourtman/parakey/blob/main/LICENSE"><img src="https://img.shields.io/github/license/rcourtman/parakey?color=10B981" alt="MIT licensed"></a>
  <img src="https://img.shields.io/badge/Apple%20Silicon%20%C2%B7%20macOS%2026%2B-10B981?color=10B981" alt="Apple Silicon · macOS 26+">
  <a href="https://github.com/rcourtman/homebrew-parakey"><img src="https://img.shields.io/badge/Homebrew-Cask-10B981?logo=homebrew&logoColor=white" alt="Homebrew Cask"></a>
  <a href="https://rcourtman.github.io/parakey/"><img src="https://img.shields.io/badge/Docs-GitHub%20Pages-10B981" alt="Documentation site"></a>
</p>

# Parakey

**Push-to-talk dictation for Apple Silicon Macs.** Hold a key, speak,
release, and the transcript appears at the cursor.

Parakey is a native Swift menu-bar app. Speech recognition runs locally
with [Parakeet TDT v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)
through [FluidAudio](https://github.com/FluidInference/FluidAudio),
CoreML, and the Apple Neural Engine.

> **~100 ms transcription** · **2.4 MB release zip** · **~80 MB RAM** · **0% CPU between dictations**

## Install

```sh
brew install --cask rcourtman/parakey/parakey
open /Applications/Parakey.app
```

Requirements:

- Apple Silicon Mac
- macOS 26 Tahoe or later
- Homebrew for install and updates

First launch downloads the local speech model, about 600 MB. Open
**Setup Checklist…** from the menu bar to finish the model, permission,
and hotkey checks.

### Assistant Install Prompt

For a shell-capable coding assistant:

```text
Install Parakey from https://github.com/rcourtman/parakey.

Use the notarised Homebrew Cask:

    brew install --cask rcourtman/parakey/parakey
    open /Applications/Parakey.app

Confirm the Mac is Apple Silicon and running macOS 26 or later.
Install Homebrew first if needed. After launch, use Parakey's
Setup Checklist from the menu bar to finish permissions and hotkey
readiness.
```

## Use

Default workflow:

1. Hold **Right Option**.
2. Speak.
3. Release.
4. Parakey pastes the transcript at the cursor.

Useful menu items:

- **Setup Checklist…** — model, permissions, and hotkey readiness
- **Settings → Hotkey** — choose Right Option, Right Control, Right
  Command, or selected F-keys
- **Settings → Trigger** — hold-to-talk or press-to-toggle
- **Settings → Language** — auto-detect (default) or pin to one of 18
  Latin/Cyrillic-script languages to prevent wrong-script
  bleed-through
- **Settings → After Pasting** — append space, append newline, or no
  suffix
- **Settings → Text Corrections** — local phrase replacements for
  recurring mishearings
- **Settings → Remove filler words** — opt-in deterministic strip of
  "um", "uh", "ah", "er", "erm", "hm" (and elongated variants)
- **Copy Diagnostics** — transcript-free support summary

## Privacy

Parakey is local-first:

- Audio is captured in memory, transcribed locally, then discarded.
- No cloud transcription.
- No telemetry, analytics, accounts, or crash reporter.
- Transcript content is never written to logs.
- Recent transcript history is in-memory only and clears on quit.
- Text corrections stay local unless you choose a sync file yourself.

Network calls are limited to:

- one-time model download from Hugging Face,
- optional GitHub release checks,
- user-triggered Homebrew/GitHub update downloads.

## How It Works

```text
CGEventTap hotkey
  → AVAudioEngine capture
  → 16 kHz mono Float32 audio
  → FluidAudio / Parakeet TDT v3 / CoreML / ANE
  → local text corrections
  → clipboard paste at cursor
```

The app is intentionally small: one SwiftPM target, one main Swift app
file, AppKit menu-bar UI, AVFoundation audio capture, CoreGraphics
events, and CoreML inference.

## Develop

```sh
git clone https://github.com/rcourtman/parakey.git
cd parakey/swift
./dev-run.sh
```

Useful checks:

```sh
swift build
swift run Parakey --self-test all
./ship-swift.sh --dry-run
```

Key files:

- `swift/Sources/Parakey/main.swift` — app implementation
- `swift/Package.swift` — SwiftPM manifest
- `swift/dev-run.sh` — signed local dev build
- `ship-swift.sh` — signed, notarised release workflow
- `entitlements.plist` — hardened-runtime microphone entitlements
- `experiments/swift-bench/` — latency benchmark harness

Release notes live in `swift/release-notes/`.

## Links

- [Latest release](https://github.com/rcourtman/parakey/releases/latest)
- [Documentation site](https://rcourtman.github.io/parakey/)
- [Homebrew tap](https://github.com/rcourtman/homebrew-parakey)
- [FluidAudio](https://github.com/FluidInference/FluidAudio)
- [Parakeet TDT v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)

## License

MIT. See [LICENSE](LICENSE).
