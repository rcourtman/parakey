# AGENTS.md

Briefing for AI coding agents working on this repo. Complements
`README.md` (for humans) and `CONTRIBUTING.md` (for contributors).

## Project shape

Parakey is a **single-file Swift menu-bar app** for push-to-talk
dictation on Apple Silicon Macs. The whole app is
`swift/Sources/Parakey/main.swift` (~1500 lines, single `ParakeyApp`
type plus a handful of small support classes). The hot path is:

1. A Quartz `CGEventTap` (`HotkeyListener`) catches the user's hotkey.
   Modifier keys are diffed in `flagsChanged`; regular keys come in
   via `keyDown` / `keyUp`. The chosen key is suppressed so it can't
   fire other shortcuts.
2. While held, `AVAudioEngine` taps the input device and
   `AVAudioConverter` resamples to 16 kHz mono Float32 (`AudioCapture`,
   `NSLock`-protected — see *Swift concurrency model* below).
3. On release the Float32 buffer is handed to a
   `TranscriptionWorker` actor that owns FluidAudio's `AsrManager`.
   Parakeet TDT v3 runs on the **Apple Neural Engine** via CoreML.
4. The transcript hits `NSPasteboard`, `Cmd+V` is posted via
   `CGEvent.post`, `NSAppleScript` unmutes system audio, and the
   "Pop" `NSSound` plays.

### Key files

| Path | Purpose |
|---|---|
| `swift/Sources/Parakey/main.swift` | The entire app. Section comments tag the major regions (Settings, Permissions, HotkeyListener, AudioCapture, TranscriptionWorker, Paster, SystemAudio, Sounds, TCC, UpdateCheck, ParakeyApp). |
| `swift/Package.swift` | SwiftPM manifest. `.macOS("26.0")` platform target, single FluidAudio dependency. **No `resources:` declaration** — resources live outside the target on purpose (see *Resource bundling* below). |
| `swift/Info.plist` | Canonical Info.plist for both dev and release builds. CFBundleIdentifier `com.local.parakey` — `dev-run.sh` signs with the same Developer ID cert and identifier as the Cask, so TCC grants from the production install carry over to the dev binary automatically. |
| `swift/Resources/parakey-menubar.png` (+ `@2x`) | Template menu-bar icon. Copied into `Contents/Resources/` by `dev-run.sh` and `ship-swift.sh`. |
| `swift/dev-run.sh` | Local iteration loop: `swift build` → wrap binary in `/tmp/Parakey-dev.app` → sign with Developer ID + hardened runtime + production entitlements → relaunch. |
| `entitlements.plist` | Hardened-runtime entitlements. Just two keys: `device.audio-input` (Tahoe 26 requirement) and `device.microphone` (legacy fallback). Anything new expands TCC surface — justify before adding. |
| `ship-swift.sh` | One-command release: version bump in Info.plist → build → sign → notarise → ditto-zip → tag → push → `gh release create` → bump sibling Homebrew Cask. |
| `icon/` | SVG sources (`hero.svg`, `latency.svg`, `parakey.svg`, etc.), `Parakey.icns`, menu-bar PNGs, `make-icons.sh`. |
| `experiments/swift-bench/` | Standalone ASR latency benchmark used to validate FluidAudio against alternatives (Apple SpeechAnalyzer, parakey-mlx) on the same audio. Re-run when bumping FluidAudio or evaluating a backend swap. |

## Build & test

```sh
# Debug build + run as a signed .app (the canonical dev loop)
cd swift
./dev-run.sh

# Release dry-run: build + sign + entitlement check + zip; skips notarise/staple and git/tag/release/cask
./ship-swift.sh --dry-run

# Tail logs (same file for dev + Cask install — bundle ids match)
tail -f ~/Library/Logs/Parakey.log
```

There is no Linux-runnable unit test suite. The app is a thin
glue layer over AVFoundation, AppKit, Carbon, CoreGraphics, and
FluidAudio — there is nothing meaningful left to mock. CI
(`.github/workflows/check.yml`) runs repo-hygiene syntax checks for
shell, plist, XML/SVG, YAML, JSON, and HTML on `macos-26`; the full
build/notarise path lives in `ship-swift.sh` on the maintainer's Mac.

If you need to validate ASR latency or correctness, use
`experiments/swift-bench/` against the WAVs in `test-audio/`.

## Swift concurrency model — important

Strict-concurrency Swift 6 makes a few things load-bearing here:

- **`ParakeyApp` and its menu wiring are `@MainActor`.** All AppKit /
  menu construction happens on the main actor. Don't touch
  `NSStatusItem`, `NSMenu`, `NSMenuItem`, or any UI state from a
  background queue without an explicit `await MainActor.run`.

- **`AudioCapture` is *not* `@MainActor`.** The `AVAudioEngine` tap
  callback fires on an audio thread, and Swift 6 will trap with
  `dispatch_assert_queue_fail` (SIGTRAP) if you try to enter the main
  actor from there. State is protected by `NSLock`; the class is
  `@unchecked Sendable`. If you make this @MainActor for "tidiness"
  you'll re-introduce the SIGTRAP and audio capture will fail
  silently after the first press.

- **`TranscriptionWorker` is an `actor`.** `AsrManager` and the
  `TdtDecoderState` it carries are owned solely by this actor. ANE
  access is effectively single-threaded; the actor enforces it.
  All `transcribe(...)` calls must go through this actor — never
  call FluidAudio directly from `ParakeyApp` or `AudioCapture`.

### AVAudioConverter gotcha

The converter's `inputBlock` must return `.noDataNow` when the chunk
is consumed, **not** `.endOfStream`. Returning `.endOfStream` puts
the converter into a terminal state — subsequent calls return 0
frames forever and the second press onward captures silence. There
is a comment in `AudioCapture` warning about this; if you see code
returning `.endOfStream` in a refactor, the refactor is wrong.

## Resource bundling — important

The menu-bar PNGs and `.icns` live in `swift/Resources/`, **outside**
the SwiftPM target. They are *not* declared as `resources:` in
`Package.swift` on purpose. Reasons:

1. SwiftPM auto-generates a `<Package>_<Target>.bundle` for declared
   resources, and that bundle has no `Info.plist` — `codesign --deep`
   chokes on it during `ship-swift.sh`.
2. `dev-run.sh` and `ship-swift.sh` both `cp` the resources into
   `Contents/Resources/` of the wrapped `.app`. The code loads them
   via `Bundle.main` (i.e. `NSImage(named: "parakey-menubar")`),
   which finds them under that canonical path.

If you find yourself reaching for `Bundle.module`, you're about to
re-introduce the resource bundle and break codesigning. Don't.

## TCC inheritance — important

The dev binary (`/tmp/Parakey-dev.app`) and the production Cask
binary (`/Applications/Parakey.app`) share `CFBundleIdentifier
com.local.parakey`. That's deliberate: macOS TCC keys permission
grants by `(bundle id, code signature)`, so signing the dev binary
with the **same Developer ID certificate** lets it inherit
Microphone / Accessibility / Input Monitoring grants from the Cask
install. Don't ad-hoc sign the dev binary — TCC will treat it as a
new app and every launch will need re-granting.

`dev-run.sh` picks up the first `Developer ID Application:`
certificate in the keychain automatically. If you don't have one,
that's a setup gap, not a bug to work around.

## Conventions

- **One app file.** `main.swift` is the whole app (~1500 lines).
  Resist splitting it into separate `.swift` files unless a piece is
  genuinely decoupled and testable in isolation (which, given the
  AVFoundation / AppKit / Carbon dependencies, is rare). One scrollable
  file with `// MARK: -` regions beats five files of glue any day.
- **Section comments tag major regions.** `// MARK: - Settings`,
  `// MARK: - HotkeyListener`, etc. Cmd+Ctrl+Up in Xcode jumps
  between them; keep them honest.
- **Comments are for the *why*.** The *what* should be obvious from
  the code; comments earn their place by explaining motivation
  (e.g. the `.noDataNow` note, the `@unchecked Sendable` rationale,
  the bundle-id-matches-Cask reasoning).
- **No transcript content in logs, ever.** Transcripts never reach
  the logger — there's no opt-in flag for it. Durations and
  length-in-chars are fine. If you find yourself adding
  `logger.info("got: \(transcript)")` for debugging, gate it behind a
  local `#if DEBUG` and *do not* land that gate on `main`.
- **Settings persist via `NSUserDefaults`** with explicit
  `UserDefaults(suiteName: "com.local.parakey")`. The suite-name init
  is functionally redundant once the bundle id is set correctly, but
  it's belt-and-braces: an unsigned debug binary run from `swift run`
  (without going through `dev-run.sh`) would otherwise scribble to
  `org.swift.swiftc.plist`.

## Out of scope

- **Telemetry, analytics, crash reporting, "anonymous usage stats."**
  Zero — see *Privacy / security* below for the load-bearing
  invariant. Not "off by default", not "opt-in", not "just a UUID":
  **none**. This is the product's marketing position.
- **Cloud transcription backends.** Parakey is local-only by design.
  Audio never leaves the Mac (one-time exception: the model
  download from Hugging Face on first launch).
- **Cross-platform.** Heavy macOS dependencies (AVFoundation,
  AppKit, Carbon, CoreGraphics, NSAppleScript, FluidAudio's CoreML
  path). Linux/Windows ports belong in separate forks if anyone
  wants to do them.
- **AI rewriting / Parakey-operated cloud sync / preference windows.**
  The README's opener positions Parakey as focused push-to-talk
  dictation. Text-correction portability is intentionally limited to
  export/import/share and a user-chosen local sync file; do not add
  accounts, a Parakey backend, or a background sync service.
- **Drag-and-drop file transcription.** Considered and rejected;
  if added, evaluate it on its own merits, not as an excuse for
  the dock icon to do something.

## Privacy / security

### Invariant: no telemetry, ever

Parakey ships with **no analytics, no event tracking, no error
reporting, no crash reporting, no "anonymous usage stats."** This is
a load-bearing product commitment — it's documented in the README's
opening privacy bullet and in the in-app About copy. Users install
Parakey *specifically* because of it.

Do not add any of the following, regardless of how innocuous they
seem or how strong the "we'd just like to know how many people use
it" instinct is:

- A phone-home with a UUID or install ID (even one generated locally).
- Sentry / Bugsnag / Crashlytics / any third-party SDK.
- Apple's `MetricKit`, `os_log` with a custom subsystem reachable
  off-device, or any signpost the user can't audit by reading
  `main.swift`.
- A "share usage stats" toggle, even default-off. Adding it normalises
  the conversation.
- Counting feature usage (which hotkey, which trigger mode, etc.) and
  pinging anywhere with it.
- Augmenting the existing GitHub update check with version info,
  platform info, or anything beyond its anonymous, unauthenticated
  GitHub JSON request.

If a future feature genuinely needs to ask the user something
specific, do it in a release note / on social — voluntary,
in-context, no infrastructure. If a bug needs reproduction info,
GitHub issues exist and produce higher-quality data than telemetry
would anyway.

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

1. **First-launch model download** — FluidAudio fetches the Parakeet
   TDT v3 CoreML weights from Hugging Face (`huggingface.co`).
   One-time, ~600 MB, cached to
   `~/Library/Application Support/FluidAudio/`.
2. **Update check** —
   `api.github.com/repos/rcourtman/parakey/releases/latest`, every
   `UPDATE_CHECK_INTERVAL_SECONDS` (6 h), first call 30 s after
   reaching "ready". Anonymous `GET`; Parakey sets no body, no auth
   header, no app or user identifier, and no telemetry. The request
   uses Swift `URLSession` defaults plus the GitHub JSON `Accept`
   header. User can disable via Settings → Check for updates
   automatically.
3. **Update apply** — When the user clicks the in-menu update item
   on a brew install: shells out to `brew upgrade --cask parakey`,
   which then fetches
   `github.com/rcourtman/parakey/releases/download/...`. User-
   triggered, not background. On source / non-brew installs, the same
   user-triggered update item opens the GitHub releases page instead
   of modifying the local checkout.

That is the entire list. If you're about to add a fourth, stop and
read the "Invariant: no telemetry" section above.

Text-correction sync does not add a Parakey network call: the app
reads and writes one local `.parakey-corrections` file chosen by the
user. If that file lives in iCloud Drive, Dropbox, Syncthing, or a
shared folder, the OS or that provider handles any network transfer
outside Parakey.

### Other privacy / security invariants

- **Hardened-runtime entitlements** (in `entitlements.plist`) are
  exactly two keys: `com.apple.security.device.audio-input` (the
  Tahoe 26 Hardened Runtime key — without it the app never appears
  in System Settings → Microphone) and
  `com.apple.security.device.microphone` (legacy/sandbox fallback).
  Anything new expands TCC surface — justify before adding. In
  particular, **never** add `cs.allow-jit`,
  `cs.allow-unsigned-executable-memory`, or
  `cs.disable-library-validation`: the only reason to want any of
  those is to embed a runtime interpreter / unsigned dylib in the
  bundle, and that's not what Parakey is.
- **Transcripts are in-memory only.** A rolling history of 5
  transcripts clears on quit. Nothing is persisted.
- **Transcript content never reaches the logger.** There's no
  opt-in flag for this in the Swift port. If you need to inspect a
  transcript while debugging, use the in-menu Recent history while
  the app is still running, or add a `#if DEBUG` gate locally — do
  not commit log calls that emit transcript text.

## Release workflow

### Invariant: only ship when the user asks

**Do not run `./ship-swift.sh` on your own initiative.** Commit
changes to `main`, push them, and wait. The user decides when a
release happens. Bundle multiple commits into a single release
naturally — there's no correctness or safety reason to ship every
accumulated commit immediately.

Triggers that mean "ship":

- The user explicitly says something like *"ship it"*, *"do the
  release"*, *"cut v0.2.x"*, or *"release this".*
- An earlier in-progress release was interrupted and needs to finish
  (resume the existing flow, don't start a new version bump).

Triggers that do **not** mean "ship":

- Finishing a feature or bug fix. Push to main, stop there.
- "Just committed something cool" momentum. Commit. Don't ship.
- A bundle of "polish" changes you'd like users to have. Wait for
  the user to ask.
- The user thanking you, agreeing with a plan, or saying *"continue"* —
  *"continue"* means continue the work you were doing, not "kick off
  a release."
- Even an "urgent" bug fix — commit + push, then tell the user the
  fix is on main and ask whether they want a release. They may want
  to bundle it with other in-flight work, do their own testing first,
  or schedule it.

This rule exists because each release runs notarytool against Apple,
bumps the cask version, creates a GitHub release, and irreversibly
publishes a version number. Six releases in two hours is wasteful and
makes the version log noisy. One release with six commits' worth of
content is just as useful to users and uses one notary slot instead
of six.

When the user does ask for a release, the mechanics are:

```sh
./ship-swift.sh                 # default: bump patch (0.2.0 → 0.2.1)
./ship-swift.sh --minor         # 0.2.x → 0.3.0
./ship-swift.sh --major         # 0.x.x → 1.0.0
./ship-swift.sh --version 0.2.5 # explicit
./ship-swift.sh --dry-run       # build + sign + entitlement check + package, skip notarise/staple/git/tag/release/cask
```

`ship-swift.sh` does in order:

1. Pre-flight (clean tree on `main`, `gh` auth, sibling tap present)
2. Read current version from `swift/Info.plist`, compute target, refuse
   if a tag for the target version already exists
3. `swift build -c release`
4. Rewrite `CFBundleShortVersionString` and `CFBundleVersion` in
   `swift/Info.plist` (the latter monotonically increments). If
   `plutil -lint` rejects the rewrite, the change is reverted.
5. Wrap binary + `Info.plist` + menu-bar PNGs + `.icns` in a fresh
   `swift/dist/Parakey.app`
6. Codesign with Developer ID + hardened runtime + `entitlements.plist`
7. Assert that `com.apple.security.device.audio-input` and
   `com.apple.security.device.microphone` are present in the signed
   binary's embedded entitlements; fail loudly if not
8. `notarytool submit --wait` (on a temp zip) + `xcrun stapler staple`
9. `ditto -c -k --keepParent` the stapled bundle into
   `swift/dist/Parakey.zip` (versioning lives in the GitHub release
   tag, not the filename)
10. Commit the version bump, tag `vX.Y.Z`, push `main` + tag
11. `gh release create` with the zip as the asset. Release notes
    come from `swift/release-notes/v<new_version>.md` if that file
    exists (preferred for releases with migration steps, breaking
    changes, or any narrative content); otherwise they're
    auto-generated from `git log <prev-tag>..<new-tag>`. Write the
    file before running `ship-swift.sh` to control the release body.
12. Rewrite `version` + `sha256` in the sibling Homebrew tap's
    `Casks/parakey.rb`, commit, push

With `--dry-run`, the script still builds, signs, checks embedded
entitlements, packages `swift/dist/Parakey.zip`, removes the temporary
`swift/dist/Parakey.app` bundle before exit, and reverts the temporary
Info.plist bump, but it skips notarytool submission, stapling,
git/tag/release work, and the Homebrew Cask update.

The tap lives at `../homebrew-parakey` by default; override with
`PARAKEY_HOMEBREW_TAP=/path/to/tap` if your layout differs.

**Recovery**: if any step fails, `ship-swift.sh` reverts the
`swift/Info.plist` edit so the working tree is clean again. If a
later step (push, gh release, cask) fails after the build succeeded,
the artefact is still in `swift/dist/`; re-run the failed step
manually rather than re-running `ship-swift.sh` (which would try to
bump the version a second time).

**One-time setup** (only needed on a fresh machine):

```sh
# Notary credentials so ship-swift.sh can notarise
xcrun notarytool store-credentials parakey-notary \
    --apple-id <YOUR_APPLE_ID> --team-id UJD57YVK2B \
    --password <APP_SPECIFIC_PASSWORD>

# GitHub CLI auth
gh auth login

# Sibling tap clone if you don't have it yet
git clone https://github.com/rcourtman/homebrew-parakey ../homebrew-parakey
```

## Common change recipes

- **Add a Settings toggle**: add a `private static let keyFoo`
  constant on `Settings`, then a computed property whose getter
  checks `defaults.object(forKey:) == nil` and returns the default
  inline (mirrors how every other setting handles defaults — there
  is no central `register()` call). Add a menu item under the
  *Settings* submenu via `ParakeyApp.buildSettingsItem()`, with a
  click-handler that writes through `Settings.shared.foo = …` and
  updates any live state.
- **Add a hotkey to the menu**: extend `HOTKEY_CHOICES` near the top
  of `main.swift` with `(display, keycode, isModifier)`. The menu
  is built from the list automatically.
- **Change the bundled FluidAudio version**: `swift/Package.swift`
  dependency declaration. After bumping, run `swift package update`,
  rebuild, and re-run the bench in `experiments/swift-bench/` to
  confirm latency didn't regress. Commit `Package.resolved` alongside
  `Package.swift`.
- **Add a model swap or streaming mode**: route every FluidAudio
  call through `TranscriptionWorker`. Never instantiate `AsrManager`
  outside that actor.
