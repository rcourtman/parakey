# Contributing

Thanks for considering a contribution to Parakey. The project is a
single-file Swift menu-bar app plus a thin signed/notarised `.app`
wrapper, and the goal is to keep it that way.

## Reporting bugs

Open an issue with:

- macOS version (`sw_vers`). Parakey requires **macOS 14 (Sonoma)** or
  later.
- Mac model (M1/M2/M3/M4 etc.)
- The last ~30 lines of `~/Library/Logs/Parakey.log`
- Whether the tink and pop sounds play at the expected moments
- Whether all three privacy permissions (Microphone, Accessibility,
  Input Monitoring) are granted to **Parakey.app** specifically (not
  `Terminal` or anything else)

## Suggesting features

Open an issue. Roughly in scope: hotkey behaviour, transcription
quality / latency, menu bar UX, install/upgrade ergonomics. Roughly
out of scope:

- Cloud transcription backends — the project is local-only by design.
- Cross-platform (Windows / Linux) — the integration is heavily
  macOS-specific (AVFoundation, AppKit, Carbon, NSAppleScript,
  CoreGraphics event taps).
- Heavy GUIs / preferences windows — the menu bar is the UI.

## Development setup

```sh
git clone https://github.com/rcourtman/parakey.git
cd parakey/swift
./dev-run.sh
```

`dev-run.sh` is idempotent — re-run it any time. It builds
`Sources/Parakey/main.swift` with `swift build`, wraps the binary
in `/tmp/Parakey-dev.app`, signs it with your Developer ID +
hardened runtime + the production entitlements (so TCC permissions
carry over from the Cask install — no manual re-grants), kills any
prior dev instance, and relaunches via `open`.

Requirements: Xcode 16+ (or the Swift 6.3+ toolchain), macOS 14
(Sonoma) or later, and a Developer ID Application certificate in your
keychain.

After editing `Sources/Parakey/main.swift`:

```sh
./dev-run.sh
tail -f ~/Library/Logs/Parakey.log
```

## Pull requests

- Keep the diff focused on one change.
- No new dependencies unless they replace something heavier or unlock
  a meaningful feature. SwiftPM dependencies in particular show up in
  every release build's `Package.resolved` lockfile — commit that
  alongside `Package.swift`.
- Match the existing style: terse Swift, structured concurrency where
  it earns its keep (`actor` for ANE access, `@MainActor` for UI),
  comments only when the *why* is non-obvious.
- Don't reach for `Bundle.module` — see `AGENTS.md` for the
  resource-bundling and codesigning constraints that pushed resources
  outside the SwiftPM target.
- Don't reintroduce `@MainActor` on `AudioCapture` — the
  `AVAudioEngine` tap fires on an audio thread and the actor
  isolation check will trap. The class is `@unchecked Sendable` with
  `NSLock` on purpose.
- If you change anything performance-sensitive, include before/after
  numbers from `experiments/swift-bench/` and note which Mac you ran
  on (CPU + ANE generation).

## Code structure

- `swift/Sources/Parakey/main.swift` — the menu bar app. One file,
  section-tagged with `// MARK: -` regions. State is kept on the
  `ParakeyApp` instance and the various support classes
  (`Settings`, `HotkeyListener`, `AudioCapture`, `TranscriptionWorker`,
  `UpdateCheck`, etc.).
- `swift/Package.swift` — SwiftPM manifest, single FluidAudio
  dependency, macOS 14 platform target.
- `swift/Info.plist` — canonical Info.plist used by both
  `dev-run.sh` and `ship-swift.sh` so dev and release builds share
  bundle id / minimum macOS / usage descriptions.
- `swift/Resources/` — menu-bar PNGs (template image + @2x). Live
  outside the SwiftPM target; copied into `Contents/Resources/` by
  the wrapper scripts.
- `swift/dev-run.sh` — debug build + wrap + sign + relaunch.
- `ship-swift.sh` — version bump, release build, sign, notarise,
  staple, ditto-zip, tag, push, GitHub release, Cask bump.
- `entitlements.plist` — hardened-runtime entitlements (two keys:
  `audio-input` + `microphone`).
- `experiments/swift-bench/` — head-to-head latency benchmark
  (FluidAudio/ANE vs the older parakey-mlx/GPU path). Useful when
  changing the inference backend.

See `AGENTS.md` for the deeper architectural invariants (Swift
concurrency model, AVAudioConverter `.noDataNow` gotcha, TCC
inheritance, telemetry/ship-on-request invariants).
