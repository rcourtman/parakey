# Parakey — Swift source

This directory is the canonical Parakey app: a single-file Swift
menu-bar dictation tool for Apple Silicon. The whole app lives in
[`Sources/Parakey/main.swift`](Sources/Parakey/main.swift).

## Quick build

```sh
./dev-run.sh
```

Builds `Sources/Parakey/main.swift`, wraps it in a signed
`/tmp/Parakey-dev.app`, kills any prior instance, and relaunches.
Requires Xcode 16+, macOS 14 (Sonoma) or later, and a Developer ID Application
certificate in your keychain.

Logs land in `~/Library/Logs/Parakey.log` — same path the production
Cask install uses, so a single `tail -f` covers both.

## Layout

| Path | Purpose |
|---|---|
| `Package.swift` | SwiftPM manifest. Single dependency: [FluidAudio](https://github.com/FluidInference/FluidAudio). |
| `Sources/Parakey/main.swift` | The entire app. Section-tagged with `// MARK: -`. |
| `Info.plist` | Canonical Info.plist shared by `dev-run.sh` and `../ship-swift.sh`. |
| `Resources/parakey-menubar.png` (+ `@2x`) | Template menu-bar icon. Lives outside the SwiftPM target on purpose — see `../AGENTS.md`. |
| `dev-run.sh` | Local iteration loop (debug build, sign, relaunch). |

## More

- **End users** — see [`../README.md`](../README.md) for install / usage / troubleshooting.
- **Contributors** — see [`../CONTRIBUTING.md`](../CONTRIBUTING.md).
- **AI coding agents** — see [`../AGENTS.md`](../AGENTS.md) for the load-bearing invariants (Swift concurrency model, the `AVAudioConverter` `.noDataNow` gotcha, TCC inheritance, telemetry / ship-on-request rules).
- **Release** — see [`../ship-swift.sh`](../ship-swift.sh).
- **Latency benchmarks** — see [`../experiments/swift-bench/`](../experiments/swift-bench/).
