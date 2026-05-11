// Parakey — push-to-talk dictation for macOS Apple Silicon.
//
// Single-file Swift menu-bar app. The whole runtime lives in this
// file: hotkey capture (`CGEventTap`), audio capture
// (`AVAudioEngine`), transcription (`FluidAudio` on the Apple
// Neural Engine), paste-at-cursor (`NSPasteboard` + `CGEvent`),
// system-audio mute (`NSAppleScript`), menu-bar UI, settings,
// rolling history, in-app updater, TCC self-healing.
//
// Section comments (`// MARK: -`) tag every major region; Cmd+Ctrl+Up
// in Xcode jumps between them. Keep them honest as you edit.
//
// Architectural invariants the build relies on are documented in
// ../../AGENTS.md — read that before refactoring concurrency,
// resource loading, or codesigning. In particular:
//   - `AudioCapture` is *not* @MainActor (AVAudioEngine tap fires on
//     an audio thread; main-actor entry would SIGTRAP under Swift 6
//     strict concurrency).
//   - `AVAudioConverter` inputBlock must return .noDataNow, never
//     .endOfStream — the latter puts the converter in a terminal
//     state and every press after the first captures silence.
//   - Resources are loaded via `Bundle.main`, never `Bundle.module`
//     — SwiftPM's auto-generated resource bundle has no Info.plist
//     and breaks `codesign --deep`.

import AppKit
import AVFoundation
import Foundation
import CoreGraphics
import ApplicationServices
import FluidAudio
import IOKit

// MARK: - Constants

let SAMPLE_RATE: Double = 16_000
let DEFAULT_HOTKEY_KEYCODE: CGKeyCode = 61  // Right Option
let MIN_CLIP_SECONDS: Double = 0.25
let MAX_RECORDING_SECONDS: TimeInterval = 120   // auto-release if held longer
let MUTE_AFTER_START_SOUND: TimeInterval = 0.18 // let the start tink finish before muting
let HISTORY_SIZE = 5

let UPDATE_CHECK_FIRST_DELAY_SECONDS: TimeInterval = 30
let UPDATE_CHECK_INTERVAL_SECONDS: TimeInterval = 6 * 3600  // 6h
let GITHUB_LATEST_RELEASE_URL = URL(string: "https://api.github.com/repos/rcourtman/parakey/releases/latest")!
let GITHUB_RELEASES_PAGE = URL(string: "https://github.com/rcourtman/parakey/releases/latest")!

let SETTINGS_SUITE = "com.local.parakey"

/// Visible state of the menu-bar item. The image stays the same
/// across all of these; only the tint colour changes — system
/// default for idle (auto-handles light/dark theme), system red
/// while recording, system yellow for transient errors, dimmed for
/// the brief loading window. This is how native macOS apps signal
/// state in the menu bar — emojis-as-state was the placeholder.
enum MenuBarState {
    case loading
    case idle
    case recording
    case busy
    case error
}

/// The hotkeys the user can pick from in Settings → Hotkey. Modifier
/// keycodes (62/61/54) are tracked via `.flagsChanged` events; the
/// F-keys are normal `.keyDown` / `.keyUp`.
struct HotkeyChoice: Equatable {
    let name: String
    let keycode: CGKeyCode
    let isModifier: Bool
    /// Which CGEventFlags mask bit fires for this modifier (nil for non-modifiers).
    let modifierFlag: CGEventFlags?
}

let HOTKEY_CHOICES: [HotkeyChoice] = [
    HotkeyChoice(name: "Right Control", keycode: 62,  isModifier: true,  modifierFlag: .maskControl),
    HotkeyChoice(name: "Right Option",  keycode: 61,  isModifier: true,  modifierFlag: .maskAlternate),
    HotkeyChoice(name: "Right Command", keycode: 54,  isModifier: true,  modifierFlag: .maskCommand),
    HotkeyChoice(name: "F5",            keycode: 96,  isModifier: false, modifierFlag: nil),
    HotkeyChoice(name: "F6",            keycode: 97,  isModifier: false, modifierFlag: nil),
    HotkeyChoice(name: "F13",           keycode: 105, isModifier: false, modifierFlag: nil),
    HotkeyChoice(name: "F18",           keycode: 79,  isModifier: false, modifierFlag: nil),
    HotkeyChoice(name: "F19",           keycode: 80,  isModifier: false, modifierFlag: nil),
]

func hotkeyChoice(forKeycode keycode: CGKeyCode) -> HotkeyChoice {
    HOTKEY_CHOICES.first(where: { $0.keycode == keycode })
        ?? HOTKEY_CHOICES.first(where: { $0.keycode == DEFAULT_HOTKEY_KEYCODE })!
}

enum TriggerMode: String { case hold, toggle }
let TRIGGER_DISPLAY: [TriggerMode: String] = [
    .hold: "Press and hold",
    .toggle: "Press to toggle",
]

// MARK: - Logger
//
// All output goes to stderr (line-buffered, so we don't lose lines
// across an abrupt exit) and to ~/Library/Logs/Parakey.log. Same
// path the Homebrew Cask install and the dev binary built by
// dev-run.sh both write to (they share a bundle id), so a single
// `tail -f` follows both.

final class Logger: @unchecked Sendable {
    static let shared = Logger()
    private let url: URL
    private let fm = FileManager.default
    private let q = DispatchQueue(label: "ParakeyLogger")

    init() {
        let logs = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? fm.createDirectory(at: logs, withIntermediateDirectories: true)
        url = logs.appendingPathComponent("Parakey.log")
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
    }

    func log(_ msg: String) {
        let stamp = ISO8601DateFormatter.timeOnly.string(from: Date())
        let line = "[\(stamp)] \(msg)\n"
        FileHandle.standardError.write(Data(line.utf8))
        q.async { [url] in
            if let h = try? FileHandle(forWritingTo: url) {
                defer { try? h.close() }
                try? h.seekToEnd()
                try? h.write(contentsOf: Data(line.utf8))
            }
        }
    }
}

func log(_ msg: String) { Logger.shared.log(msg) }

extension ISO8601DateFormatter {
    static let timeOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

// MARK: - Settings
//
// Thin wrapper around NSUserDefaults using the explicit suite name
// `com.local.parakey` (the bundle id), so settings persist at
// `~/Library/Preferences/com.local.parakey.plist`. One property per
// user-visible setting; defaults are returned inline by each getter
// when the key is missing, rather than via a central `register()`
// call.

final class Settings: @unchecked Sendable {
    private static let keyHotkeyKeycode = "hotkey_keycode"
    private static let keyTriggerMode = "trigger_mode"
    private static let keyMuteWhileRecording = "mute_while_recording"
    private static let keyShowInDock = "show_in_dock"
    private static let keyInputDevice = "input_device"
    private static let keyCheckForUpdates = "check_for_updates"
    private static let keyLastSeenVersion = "last_seen_version"
    private static let keySkippedVersions = "skipped_versions"

    private let defaults: UserDefaults

    static let shared = Settings()

    init() {
        // Bundled .app under the Cask uses bundle id com.local.parakey,
        // so `standardUserDefaults` IS the right suite. Belt and braces:
        // also try the suite-name initialiser, which works regardless
        // of bundle identification.
        self.defaults = UserDefaults(suiteName: SETTINGS_SUITE) ?? .standard
    }

    var hotkeyKeycode: CGKeyCode {
        get {
            if defaults.object(forKey: Self.keyHotkeyKeycode) == nil { return DEFAULT_HOTKEY_KEYCODE }
            return CGKeyCode(defaults.integer(forKey: Self.keyHotkeyKeycode))
        }
        set { defaults.set(Int(newValue), forKey: Self.keyHotkeyKeycode) }
    }

    var triggerMode: TriggerMode {
        get {
            if let v = defaults.string(forKey: Self.keyTriggerMode), let m = TriggerMode(rawValue: v) {
                return m
            }
            return .hold
        }
        set { defaults.set(newValue.rawValue, forKey: Self.keyTriggerMode) }
    }

    var muteWhileRecording: Bool {
        get {
            if defaults.object(forKey: Self.keyMuteWhileRecording) == nil { return true }
            return defaults.bool(forKey: Self.keyMuteWhileRecording)
        }
        set { defaults.set(newValue, forKey: Self.keyMuteWhileRecording) }
    }

    var showInDock: Bool {
        get { defaults.bool(forKey: Self.keyShowInDock) }
        set { defaults.set(newValue, forKey: Self.keyShowInDock) }
    }

    var inputDevice: String {
        get { defaults.string(forKey: Self.keyInputDevice) ?? "" }
        set { defaults.set(newValue, forKey: Self.keyInputDevice) }
    }

    var checkForUpdates: Bool {
        get {
            if defaults.object(forKey: Self.keyCheckForUpdates) == nil { return true }
            return defaults.bool(forKey: Self.keyCheckForUpdates)
        }
        set { defaults.set(newValue, forKey: Self.keyCheckForUpdates) }
    }

    var lastSeenVersion: String {
        get { defaults.string(forKey: Self.keyLastSeenVersion) ?? "" }
        set { defaults.set(newValue, forKey: Self.keyLastSeenVersion) }
    }

    var skippedVersions: [String] {
        get { (defaults.array(forKey: Self.keySkippedVersions) as? [String]) ?? [] }
        set { defaults.set(newValue, forKey: Self.keySkippedVersions) }
    }
}

// MARK: - Permissions

enum Permission: String, CaseIterable {
    case microphone = "Microphone"
    case accessibility = "Accessibility"
    case inputMonitoring = "Input Monitoring"
}

@MainActor
final class Permissions {
    static func isGranted(_ p: Permission) -> Bool {
        switch p {
        case .microphone:
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .accessibility:
            return AXIsProcessTrusted()
        case .inputMonitoring:
            return CGPreflightListenEventAccess()
        }
    }

    /// Trigger the system prompt or, if previously denied, push the
    /// user toward the right Settings pane. Returns immediately;
    /// actual grant happens asynchronously.
    static func request(_ p: Permission) {
        switch p {
        case .microphone:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                log("Microphone request: granted=\(granted)")
            }
        case .accessibility:
            // The AX-trust-with-prompt API shows a native dialog
            // when status is undetermined, falls through silently if
            // already granted. We also open Settings as a fallback
            // for the previously-denied case.
            // kAXTrustedCheckOptionPrompt is an Apple-defined CFStringRef.
            // Swift 6 strict concurrency complains about referencing the
            // global directly from an @MainActor method; bridge via a
            // string literal that matches its documented value.
            let key = "AXTrustedCheckOptionPrompt"
            _ = AXIsProcessTrustedWithOptions([key: kCFBooleanTrue!] as CFDictionary)
            openSettingsPane("Privacy_Accessibility")
        case .inputMonitoring:
            // CGRequestListenEventAccess is the canonical request
            // path for CGEventTap clients. On macOS 26 it registers
            // the app in the Input Monitoring list and shows a
            // prompt OR opens Settings as appropriate.
            _ = CGRequestListenEventAccess()
        }
    }

    private static func openSettingsPane(_ subpath: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(subpath)") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Hotkey listener
//
// Global event tap on the keyDown / keyUp / flagsChanged stream.
// Right Option is a modifier so it doesn't fire keyDown — we watch
// flagsChanged and diff the .option flag.

@MainActor
final class HotkeyListener {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lastFlags: CGEventFlags = []
    private var toggleActive = false

    /// User's current hotkey (set via Settings → Hotkey submenu).
    var hotkey: HotkeyChoice = hotkeyChoice(forKeycode: DEFAULT_HOTKEY_KEYCODE)
    var triggerMode: TriggerMode = .hold

    /// onPress fires when a recording should start (press in hold mode,
    /// or first press in toggle mode). onRelease fires when it should
    /// stop (release in hold mode, or second press in toggle mode).
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    func start() {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
                              | (1 << CGEventType.keyUp.rawValue)
                              | (1 << CGEventType.flagsChanged.rawValue)

        let opaqueSelf = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let listener = Unmanaged<HotkeyListener>.fromOpaque(userInfo).takeUnretainedValue()
                DispatchQueue.main.async { listener.handle(type: type, event: event) }
                return Unmanaged.passUnretained(event)
            },
            userInfo: opaqueSelf
        ) else {
            log("CGEvent.tapCreate failed — Input Monitoring permission missing?")
            return
        }

        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log("HotkeyListener: tap active (watching \(hotkey.name))")
    }

    /// Replace the current hotkey choice. Safe to call at runtime —
    /// the tap stays bound, only the per-event filter changes.
    func setHotkey(_ choice: HotkeyChoice) {
        self.hotkey = choice
        self.lastFlags = []
        self.toggleActive = false
        log("HotkeyListener: hotkey changed → \(choice.name)")
    }

    func setTriggerMode(_ mode: TriggerMode) {
        // Reset toggle state when switching modes so we don't get
        // stuck in mid-toggle from a previous session.
        if mode != triggerMode { toggleActive = false }
        triggerMode = mode
        log("HotkeyListener: trigger mode → \(mode.rawValue)")
    }

    private func handle(type: CGEventType, event: CGEvent) {
        let keycode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard keycode == hotkey.keycode else { return }

        // Modifier keys fire .flagsChanged with the same keycode field.
        // Diff the relevant modifier bit against the previous flags
        // snapshot to detect press / release transitions. Non-modifier
        // keys fire ordinary .keyDown / .keyUp.
        var isPress = false
        var isRelease = false
        if hotkey.isModifier {
            guard type == .flagsChanged, let mask = hotkey.modifierFlag else { return }
            let nowPressed = event.flags.contains(mask)
            let wasPressed = lastFlags.contains(mask)
            lastFlags = event.flags
            isPress = nowPressed && !wasPressed
            isRelease = !nowPressed && wasPressed
        } else {
            if type == .keyDown { isPress = true }
            else if type == .keyUp { isRelease = true }
            else { return }
        }

        switch triggerMode {
        case .hold:
            if isPress { onPress?() }
            if isRelease { onRelease?() }
        case .toggle:
            // Toggle mode: every press flips between "start recording"
            // and "stop recording". Releases are no-ops.
            guard isPress else { return }
            if toggleActive { onRelease?() } else { onPress?() }
            toggleActive.toggle()
        }
    }

    /// Called when the recording stops via a path other than the
    /// hotkey (auto-release at max duration, app quitting, etc.) so
    /// toggle mode doesn't end up offset by one.
    func resetToggleState() {
        toggleActive = false
    }
}

// MARK: - Audio capture
//
// AVAudioEngine tap on the input node, downmix to mono / 16 kHz /
// Float32 if needed, append to a buffer while recording.
//
// Deliberately NOT @MainActor. AVAudioEngine's installTap delivers
// callbacks on an audio worker thread. Under Swift 6 strict
// concurrency, calling a @MainActor method from that thread triggers
// dispatch_assert_queue_fail (SIGTRAP) and kills the process. We
// instead guard mutable state with NSLock and let the tap callback
// run wherever AVFoundation calls it.

final class AudioCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    private var samples: [Float] = []
    private var _isRunning = false

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isRunning
    }

    func startEngine() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: SAMPLE_RATE,
            channels: 1,
            interleaved: false
        ) else { throw NSError(domain: "Parakey", code: -1) }

        converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        log("AudioCapture: input \(inputFormat.sampleRate) Hz \(inputFormat.channelCount)ch → \(targetFormat.sampleRate) Hz mono")

        // Capture targetFormat by value into the closure. self is
        // weak so the engine doesn't keep AudioCapture alive past
        // its owner. The closure runs on AVFoundation's audio
        // thread — handleTap is non-isolated and uses NSLock for
        // any shared-state access.
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.handleTap(buffer: buffer, target: targetFormat)
        }

        try engine.start()
        log("AudioCapture: engine started")
    }

    func beginRecording() {
        lock.lock(); defer { lock.unlock() }
        samples.removeAll(keepingCapacity: true)
        _isRunning = true
    }

    /// Stops recording and returns the captured samples.
    func endRecording() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        _isRunning = false
        let captured = samples
        samples.removeAll(keepingCapacity: true)
        return captured
    }

    private func handleTap(buffer: AVAudioPCMBuffer, target: AVAudioFormat) {
        // Snapshot the running flag under lock; bail fast if we're
        // not recording so we don't pay conversion cost for nothing.
        lock.lock()
        let running = _isRunning
        lock.unlock()
        guard running, let converter else { return }

        let ratio = target.sampleRate / buffer.format.sampleRate
        let outCap = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCap) else { return }

        // .noDataNow vs .endOfStream: this is reusing the same
        // AVAudioConverter across every tap callback (~50 Hz). If we
        // signal .endOfStream after the buffer, the converter goes
        // into a terminal state and produces 0 samples on every
        // subsequent call — exactly the "first capture was 0.10s,
        // every press after that was 0.00s" bug we saw before this
        // fix. .noDataNow means "I'm out of input *for this call*,
        // but the stream continues" and leaves the converter usable.
        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if fed { outStatus.pointee = .noDataNow; return nil }
            fed = true; outStatus.pointee = .haveData; return buffer
        }
        if status == .error {
            log("AudioCapture: convert error: \(error?.localizedDescription ?? "?")")
            return
        }
        guard let ch = out.floatChannelData?[0] else { return }
        let arr = Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))

        // Re-check running under lock — endRecording() might have
        // fired during conversion and we don't want straggler frames
        // appearing in the next clip.
        lock.lock()
        if _isRunning { samples.append(contentsOf: arr) }
        lock.unlock()
    }
}

// MARK: - Transcription worker
//
// Owns the FluidAudio AsrManager. ASR work runs in the actor's
// isolated context, so the model load + every `transcribe` call
// happens on a single Swift concurrency executor. Necessary because
// the Apple Neural Engine doesn't tolerate concurrent inference
// calls against the same compiled CoreML graph — serialising
// through the actor is what keeps that contract.

actor TranscriptionWorker {
    private var asr: AsrManager?
    private(set) var ready = false

    func load() async throws {
        log("ASR: downloading + loading Parakeet TDT v3 CoreML weights…")
        let t0 = Date()
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        asr = AsrManager(config: .default, models: models)
        ready = true
        log("ASR: ready in \(String(format: "%.2f", Date().timeIntervalSince(t0))) s")
    }

    func transcribe(samples: [Float]) async throws -> String {
        guard let asr else { throw NSError(domain: "Parakey", code: -2) }
        var state = try TdtDecoderState()
        let result = try await asr.transcribe(samples, decoderState: &state)
        return result.text
    }
}

// MARK: - Paste at cursor
//
// Write to general pasteboard, post Cmd+V. We deliberately don't
// preserve and restore the user's previous clipboard contents —
// trying to round-trip it racily fights with paste-managers and
// other clipboard observers, and most users find a clipboard that
// silently reverts itself more surprising than one that ends up
// holding whatever they last dictated.

@MainActor
enum Paster {
    private static let virtualKeyV: CGKeyCode = 0x09  // ANSI 'v'

    static func paste(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        let src = CGEventSource(stateID: .combinedSessionState)
        guard
            let down = CGEvent(keyboardEventSource: src, virtualKey: virtualKeyV, keyDown: true),
            let up = CGEvent(keyboardEventSource: src, virtualKey: virtualKeyV, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

// MARK: - System audio mute
//
// Mute the system output volume during recording so an open Zoom /
// Music / browser tab doesn't get captured back into the mic and
// transcribed alongside the user's voice. Done via NSAppleScript
// since there's no public AVFoundation knob for it. On release we
// only unmute if WE were the ones who muted — leave alone if the
// user had already
// muted manually).

enum SystemAudio {
    // NSAppleScript isn't Sendable so we can't memoise it across
    // threads under Swift 6 strict concurrency. AppleScript compile
    // is microseconds — happy to take the per-call cost.
    static func isMuted() -> Bool {
        var err: NSDictionary?
        let script = NSAppleScript(source: "output muted of (get volume settings)")
        guard let result = script?.executeAndReturnError(&err) else { return false }
        return result.booleanValue
    }

    static func mute() {
        var err: NSDictionary?
        _ = NSAppleScript(source: "set volume with output muted")?.executeAndReturnError(&err)
    }

    static func unmute() {
        var err: NSDictionary?
        _ = NSAppleScript(source: "set volume without output muted")?.executeAndReturnError(&err)
    }
}

// MARK: - Sounds
//
// Two short system sounds — Tink on recording start, Pop on
// finished transcribe. Loaded from /System/Library/Sounds so we
// don't have to bundle audio resources.

@MainActor
enum Sounds {
    private static let start: NSSound? = NSSound(contentsOfFile: "/System/Library/Sounds/Tink.aiff", byReference: true)
    private static let done:  NSSound? = NSSound(contentsOfFile: "/System/Library/Sounds/Pop.aiff",  byReference: true)

    static func playStart() { start?.stop(); start?.play() }
    static func playDone()  { done?.stop();  done?.play() }
}

// MARK: - Bundle version helpers

func currentBundleVersion() -> String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
}

func parseSemver(_ s: String) -> [Int] {
    // Strip leading whitespace + 'v', split on '.', take leading
    // digit run from each chunk. Tolerant by design; "" returns []
    // which compares less than any real version.
    let trimmed = s.trimmingCharacters(in: .whitespaces)
        .drop(while: { $0 == "v" || $0 == "V" })
    return trimmed.split(separator: ".").map { chunk in
        var n = 0; var seen = false
        for c in chunk {
            if let d = c.wholeNumberValue { n = n * 10 + d; seen = true }
            else { break }
        }
        return seen ? n : 0
    }
}

func isNewer(_ candidate: String, than current: String) -> Bool {
    let a = parseSemver(candidate)
    let b = parseSemver(current)
    for i in 0..<max(a.count, b.count) {
        let x = i < a.count ? a[i] : 0
        let y = i < b.count ? b[i] : 0
        if x != y { return x > y }
    }
    return false
}

// MARK: - TCC recovery
//
// macOS's TCC database occasionally ends up with a DENIED entry
// for our bundle id that the user can't easily clear (typical
// trigger: an upgrade that changes the signed binary while a
// previous denial is still cached). On a fresh launch after an
// upgrade (CFBundleShortVersionString differs from
// settings.lastSeenVersion), we proactively `tccutil reset` any
// DENIED entry for `com.local.parakey`. GRANTED entries stay
// intact — we never reset away permissions the user gave us.
//
// The companion to this is the click-twice-to-reset retry in the
// permission rows: if the user clicks a ⚠ row, sees the OS dialog
// say nothing useful, and clicks the same row again, the second
// click runs `tccutil reset` to clear stuck state and re-request.

enum TCC {
    /// Maps the human-readable permission name we use in the menu to
    /// the TCC service identifier `tccutil reset` accepts. Input
    /// Monitoring is "ListenEvent" internally.
    static let serviceName: [Permission: String] = [
        .microphone: "Microphone",
        .accessibility: "Accessibility",
        .inputMonitoring: "ListenEvent",
    ]

    static func reset(_ p: Permission, bundleID: String) {
        guard let service = serviceName[p] else { return }
        let proc = Process()
        proc.launchPath = "/usr/bin/tccutil"
        proc.arguments = ["reset", service, bundleID]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            log("  tccutil reset \(service) \(bundleID) → exit \(proc.terminationStatus)")
        } catch {
            log("  tccutil reset \(service) failed: \(error)")
        }
    }
}

// MARK: - Update check
//
// Hits the GitHub Releases API once at boot + every 6 h. When a newer
// version is found AND it's not in the user's skipped list, a
// submenu inserts itself at the top of the menu: What's new /
// Update now / Skip vX.Y.Z.

struct GitHubRelease: Sendable {
    let tagName: String      // 'v0.1.7'
    let version: String      // '0.1.7' (no v)
    let body: String         // release notes, raw markdown
    let htmlURL: String
}

enum UpdateCheck {
    static func fetchLatest() async -> GitHubRelease? {
        var req = URLRequest(url: GITHUB_LATEST_RELEASE_URL)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String, !tag.isEmpty else {
                return nil
            }
            return GitHubRelease(
                tagName: tag,
                version: tag.drop(while: { $0 == "v" || $0 == "V" }).description,
                body: (json["body"] as? String) ?? "",
                htmlURL: (json["html_url"] as? String) ?? GITHUB_RELEASES_PAGE.absoluteString
            )
        } catch {
            return nil
        }
    }
}

// MARK: - App
//
// Single class that owns the lifecycle and the AppKit menu-bar UI.
// All UI state lives here; subsystems (HotkeyListener, AudioCapture,
// TranscriptionWorker, UpdateCheck, …) hold their own state but
// call back into `ParakeyApp` for anything that touches the menu.

@MainActor
final class ParakeyApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let audio = AudioCapture()
    private let hotkey = HotkeyListener()
    private let asr = TranscriptionWorker()
    private let settings = Settings.shared

    private var isRecording = false
    private var isBusy = false
    private var isReady = false
    private var didMuteThisRecording: Bool = false
    private var maxDurationWorkItem: DispatchWorkItem?
    private var muteWorkItem: DispatchWorkItem?

    /// Last N transcripts, newest first. Shown in the History submenu.
    private var history: [String] = []

    /// In-session click counter per permission. Click #2 onwards
    /// resets the matching TCC entry before re-requesting — belt
    /// and braces for stuck DENIED entries macOS occasionally caches.
    private var permClickCount: [Permission: Int] = [:]

    /// Latest release detected by the periodic check. nil = no update,
    /// or user has skipped it.
    private var pendingUpdate: GitHubRelease?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(settings.showInDock ? .regular : .accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        configureStatusItemImage()
        setMenuBarState(.loading)
        rebuildMenu()

        // Configure hotkey listener up front so it picks up the user's
        // saved choice the moment the tap goes live.
        hotkey.setHotkey(hotkeyChoice(forKeycode: settings.hotkeyKeycode))
        hotkey.setTriggerMode(settings.triggerMode)

        // Load ASR FIRST, then audio + hotkey. Reversing this order
        // makes the first-launch CoreML compile of the ANE Encoder
        // hang. The bench under experiments/swift-bench/ never opens
        // an audio session so it doesn't see this.
        Task { @MainActor in
            do {
                try await asr.load()
                self.isReady = true
                setMenuBarState(.idle)

                hotkey.onPress   = { [weak self] in self?.handlePress() }
                hotkey.onRelease = { [weak self] in self?.handleRelease() }
                hotkey.start()
                try audio.startEngine()

                // Belt-and-braces: clear any TCC entries stuck
                // 'denied' from an upgrade. Granted permissions
                // stay intact. See the TCC recovery section comment
                // for why this is needed.
                recoverStaleTCCAfterUpgrade()

                rebuildMenu()

                // Periodic update poll. First check 30 s after boot
                // so we never compete with model load; then every 6 h.
                startUpdateCheckLoop()
            } catch {
                log("init failed: \(error)")
                setMenuBarState(.error)
            }
        }
    }

    // MARK: - Menu bar appearance
    //
    // One template image (parakey-menubar.png), tinted to indicate
    // state. Same image across all states means the icon stays
    // visually-anchored in the menu bar — only colour shifts. This
    // is how Apple-native menu bar utilities work (Tailscale, Bartender,
    // 1Password): the icon identifies the app, state is conveyed via
    // colour and the menu's first row text.

    private func configureStatusItemImage() {
        guard let button = statusItem.button else { return }
        // The PNG lives in Contents/Resources/ of our .app bundle
        // (the canonical macOS layout — same place release.sh /
        // dev-run.sh copy it). NSImage(named:) on the main bundle
        // finds it under that path automatically; Bundle.module is
        // deliberately not used here so codesign --deep doesn't have
        // to grapple with a SwiftPM resource bundle.
        let image = NSImage(named: "parakey-menubar")
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        button.image = image
        button.imagePosition = .imageOnly
        if image == nil {
            button.title = "Parakey"
            log("statusItem: parakey-menubar.png not in Bundle.main — text fallback")
        }
        button.toolTip = "Parakey"
    }

    private func setMenuBarState(_ state: MenuBarState) {
        guard let button = statusItem.button else { return }
        switch state {
        case .loading:
            // Subtle dim while the model compiles. nil contentTintColor
            // = system default (black/white per theme); .tertiary gives
            // a "this is here but not yet active" feel.
            button.contentTintColor = .tertiaryLabelColor
        case .idle:
            // Default tint — macOS auto-handles light/dark menu bar.
            button.contentTintColor = nil
        case .recording:
            button.contentTintColor = .systemRed
        case .busy:
            // Transcribe is typically <200 ms, briefer than a perceptible
            // colour change. Leave at default; the menu's first row says
            // "Transcribing" if the user pops it open.
            button.contentTintColor = nil
        case .error:
            button.contentTintColor = .systemYellow
        }
    }

    // MARK: - Recording loop

    private func handlePress() {
        guard isReady, !isRecording, !isBusy else { return }
        isRecording = true
        audio.beginRecording()
        setMenuBarState(.recording)
        Sounds.playStart()
        log("press: recording")

        // Mute system audio shortly after the start sound finishes,
        // so the Tink itself isn't suppressed but anything that
        // starts playing during dictation is. Restored on release.
        scheduleMute()
        scheduleMaxDurationAutoRelease()
    }

    private func handleRelease() {
        guard isRecording else { return }
        isRecording = false
        cancelMute()
        cancelMaxDurationAutoRelease()
        unmuteIfWeMuted()

        let samples = audio.endRecording()
        let dur = Double(samples.count) / SAMPLE_RATE
        if dur < MIN_CLIP_SECONDS {
            log("release: clip too short (\(String(format: "%.2f", dur)) s), discarding")
            setMenuBarState(.idle)
            return
        }
        isBusy = true
        setMenuBarState(.busy)
        log("release: \(String(format: "%.2f", dur)) s captured, transcribing")

        Task { @MainActor in
            do {
                let t0 = Date()
                let text = try await asr.transcribe(samples: samples)
                let dt = Date().timeIntervalSince(t0)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                log("\(String(format: "%.2f", dur)) s audio → \(String(format: "%.2f", dt)) s → \(trimmed.count) chars")
                if !trimmed.isEmpty {
                    Paster.paste(trimmed + " ")
                    Sounds.playDone()
                    addToHistory(trimmed)
                }
            } catch {
                log("transcribe failed: \(error)")
            }
            isBusy = false
            setMenuBarState(.idle)
        }
    }

    private func scheduleMute() {
        guard settings.muteWhileRecording else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRecording else { return }
            // Only mute if we wouldn't be stomping a user-set mute.
            if !SystemAudio.isMuted() {
                SystemAudio.mute()
                self.didMuteThisRecording = true
                log("output muted")
            }
        }
        muteWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + MUTE_AFTER_START_SOUND, execute: work)
    }

    private func cancelMute() {
        muteWorkItem?.cancel()
        muteWorkItem = nil
    }

    private func unmuteIfWeMuted() {
        guard didMuteThisRecording else { return }
        didMuteThisRecording = false
        SystemAudio.unmute()
        log("output unmuted")
    }

    private func scheduleMaxDurationAutoRelease() {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRecording else { return }
            log("max recording duration reached, releasing")
            self.hotkey.resetToggleState()
            self.handleRelease()
        }
        maxDurationWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + MAX_RECORDING_SECONDS, execute: work)
    }

    private func cancelMaxDurationAutoRelease() {
        maxDurationWorkItem?.cancel()
        maxDurationWorkItem = nil
    }

    // MARK: - History

    private func addToHistory(_ text: String) {
        history.insert(text, at: 0)
        if history.count > HISTORY_SIZE { history.removeLast(history.count - HISTORY_SIZE) }
        rebuildMenu()
    }

    /// 60-char preview with ellipsis. Newlines collapsed so a multi-
    /// line transcript still renders as one menu row.
    private func previewLine(for text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 60 ? String(flat.prefix(60)) + "…" : flat
    }

    @objc private func historyClicked(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
        log("history copied to clipboard (\(s.count) chars)")
    }

    @objc private func quitClicked(_ sender: NSMenuItem) {
        NSApp.terminate(self)
    }

    // MARK: - Menu

    private func rebuildMenu() {
        statusItem.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // Status row.
        let statusTitle: String
        if !isReady {
            statusTitle = "Loading speech model…"
        } else {
            let hk = hotkey.hotkey.name
            let verb = settings.triggerMode == .hold ? "Hold" : "Press"
            statusTitle = "\(verb) \(hk) to dictate"
        }
        let status = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        menu.addItem(.separator())

        // Update submenu (lazy — only present when an update exists).
        if let release = pendingUpdate, !settings.skippedVersions.contains(release.version) {
            menu.addItem(buildUpdateItem(for: release))
            menu.addItem(.separator())
        }

        // Permission rows — visible only while something is missing.
        var addedPermRow = false
        for p in Permission.allCases where !Permissions.isGranted(p) {
            menu.addItem(buildPermissionItem(p))
            addedPermRow = true
        }
        if addedPermRow { menu.addItem(.separator()) }

        // History: newest transcript inline (one-click to copy back to
        // the clipboard), older ones hidden inside a Recent submenu so
        // the top level stays scannable. The most common re-paste need
        // — "drop what I just dictated into a second place" — is then
        // a single click rather than a hover-into-submenu.
        if let newest = history.first {
            let inline = NSMenuItem(title: previewLine(for: newest),
                                    action: #selector(historyClicked(_:)),
                                    keyEquivalent: "")
            inline.target = self
            inline.representedObject = newest
            inline.toolTip = newest
            menu.addItem(inline)

            if history.count > 1 {
                let parent = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
                let sub = NSMenu()
                for entry in history.dropFirst() {
                    let item = NSMenuItem(title: previewLine(for: entry),
                                          action: #selector(historyClicked(_:)),
                                          keyEquivalent: "")
                    item.target = self
                    item.representedObject = entry
                    item.toolTip = entry
                    sub.addItem(item)
                }
                parent.submenu = sub
                menu.addItem(parent)
            }

            menu.addItem(.separator())
        }

        // Settings submenu.
        menu.addItem(buildSettingsItem())
        menu.addItem(.separator())

        // About + Quit.
        let about = NSMenuItem(title: "About Parakey",
                               action: #selector(showAboutClicked(_:)),
                               keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        // Route through our own selector rather than `NSApp.terminate(_:)`
        // directly. macOS auto-decorates items whose action is the
        // system terminate: selector with a destructive-action glyph
        // (visible in the state-column slot), which is the *only* item
        // in the menu that gets such an indicator — every other row
        // sits flush against the left edge. The wrapper produces the
        // identical behaviour with no auto-glyph.
        let quit = NSMenuItem(title: "Quit Parakey",
                              action: #selector(quitClicked(_:)),
                              keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    // MARK: - Permission row + click-twice-to-reset

    private func buildPermissionItem(_ p: Permission) -> NSMenuItem {
        let clicks = permClickCount[p] ?? 0
        let title: String
        if clicks >= 1 {
            // First click already happened; permission still denied,
            // so signal explicitly that a second click will reset
            // any stuck TCC state and re-request.
            title = "⚠ Grant \(p.rawValue) (try again — will reset stuck state)…"
        } else {
            title = "⚠ Grant \(p.rawValue) permission…"
        }
        let item = NSMenuItem(title: title,
                              action: #selector(grantPermissionClicked(_:)),
                              keyEquivalent: "")
        item.target = self
        item.representedObject = p.rawValue
        return item
    }

    @objc private func grantPermissionClicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let p = Permission(rawValue: raw) else { return }
        let clicks = (permClickCount[p] ?? 0) + 1
        permClickCount[p] = clicks
        log("perm click #\(clicks): \(p.rawValue)")

        if clicks >= 2 {
            // Click #2+: scrub TCC before re-requesting. The most
            // common cause of "I clicked Grant but nothing happened"
            // is a stuck TCC entry that survived an upgrade.
            log("  resetting TCC for \(p.rawValue) before retry")
            TCC.reset(p, bundleID: Bundle.main.bundleIdentifier ?? "com.local.parakey")
        }
        Permissions.request(p)

        // Permissions don't update synchronously. Refresh after a
        // short delay so the row disappears once granted (or its
        // title changes to the retry hint).
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.rebuildMenu()
        }
    }

    // MARK: - Settings submenu

    private func buildSettingsItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false

        // Hotkey submenu.
        let hkParent = NSMenuItem(title: "Hotkey", action: nil, keyEquivalent: "")
        let hkSub = NSMenu()
        hkSub.autoenablesItems = false
        for choice in HOTKEY_CHOICES {
            let item = NSMenuItem(title: choice.name,
                                  action: #selector(selectHotkey(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.state = (choice.keycode == hotkey.hotkey.keycode) ? .on : .off
            item.representedObject = Int(choice.keycode)
            hkSub.addItem(item)
        }
        hkParent.submenu = hkSub
        sub.addItem(hkParent)

        // Trigger mode submenu.
        let tmParent = NSMenuItem(title: "Trigger mode", action: nil, keyEquivalent: "")
        let tmSub = NSMenu()
        tmSub.autoenablesItems = false
        for mode in [TriggerMode.hold, .toggle] {
            let item = NSMenuItem(title: TRIGGER_DISPLAY[mode] ?? mode.rawValue,
                                  action: #selector(selectTriggerMode(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.state = (mode == settings.triggerMode) ? .on : .off
            item.representedObject = mode.rawValue
            tmSub.addItem(item)
        }
        tmParent.submenu = tmSub
        sub.addItem(tmParent)

        // Mute toggle.
        let mute = NSMenuItem(title: "Mute system audio while recording",
                              action: #selector(toggleMute(_:)),
                              keyEquivalent: "")
        mute.target = self
        mute.state = settings.muteWhileRecording ? .on : .off
        sub.addItem(mute)

        // Dock toggle.
        let dock = NSMenuItem(title: "Show Parakey in Dock",
                              action: #selector(toggleDock(_:)),
                              keyEquivalent: "")
        dock.target = self
        dock.state = settings.showInDock ? .on : .off
        sub.addItem(dock)

        // Periodic-check toggle. The label ends in "automatically" so it
        // reads distinctly from the "Check for updates now…" action below
        // — matches the macOS convention (e.g. Mail, Software Update).
        let checkToggle = NSMenuItem(title: "Check for updates automatically",
                                     action: #selector(toggleCheckForUpdates(_:)),
                                     keyEquivalent: "")
        checkToggle.target = self
        checkToggle.state = settings.checkForUpdates ? .on : .off
        sub.addItem(checkToggle)

        // Immediate-check action.
        let checkNow = NSMenuItem(title: "Check for updates now…",
                                  action: #selector(checkForUpdatesNowClicked(_:)),
                                  keyEquivalent: "")
        checkNow.target = self
        sub.addItem(checkNow)

        parent.submenu = sub
        return parent
    }

    @objc private func selectHotkey(_ sender: NSMenuItem) {
        guard let kc = sender.representedObject as? Int else { return }
        let choice = hotkeyChoice(forKeycode: CGKeyCode(kc))
        settings.hotkeyKeycode = choice.keycode
        hotkey.setHotkey(choice)
        rebuildMenu()
    }

    @objc private func selectTriggerMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let m = TriggerMode(rawValue: raw) else { return }
        settings.triggerMode = m
        hotkey.setTriggerMode(m)
        rebuildMenu()
    }

    @objc private func toggleMute(_ sender: NSMenuItem) {
        settings.muteWhileRecording.toggle()
        sender.state = settings.muteWhileRecording ? .on : .off
    }

    @objc private func toggleDock(_ sender: NSMenuItem) {
        settings.showInDock.toggle()
        sender.state = settings.showInDock ? .on : .off
        NSApp.setActivationPolicy(settings.showInDock ? .regular : .accessory)
    }

    @objc private func toggleCheckForUpdates(_ sender: NSMenuItem) {
        settings.checkForUpdates.toggle()
        sender.state = settings.checkForUpdates ? .on : .off
    }

    // MARK: - About dialog

    @objc private func showAboutClicked(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = "Parakey \(currentBundleVersion())"
        alert.informativeText = """
            Lightweight push-to-talk dictation for Apple Silicon Macs.

            Hotkey:  \(hotkey.hotkey.name)
            Mode:    \(TRIGGER_DISPLAY[settings.triggerMode] ?? settings.triggerMode.rawValue)
            Model:   FluidAudio · Parakeet TDT v3 (CoreML / ANE)

            Maintained by Richard Courtman.
            github.com/rcourtman/parakey · MIT licensed
            """
        // Use our app icon instead of NSAlert's default exclamation
        // mark. .icns lives in Contents/Resources/Parakey.icns;
        // NSImage(named:) on Bundle.main resolves it by filename
        // sans extension.
        if let icon = NSImage(named: "Parakey") {
            alert.icon = icon
        }
        alert.runModal()
    }

    // MARK: - Update flow

    private func startUpdateCheckLoop() {
        Task.detached { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(UPDATE_CHECK_FIRST_DELAY_SECONDS * 1_000_000_000))
            while !Task.isCancelled {
                await self?.tickUpdateCheck()
                try? await Task.sleep(nanoseconds: UInt64(UPDATE_CHECK_INTERVAL_SECONDS * 1_000_000_000))
            }
        }
    }

    private func tickUpdateCheck() async {
        guard settings.checkForUpdates else { return }
        guard let release = await UpdateCheck.fetchLatest() else { return }
        await MainActor.run { self.handleFetchedRelease(release) }
    }

    private func handleFetchedRelease(_ release: GitHubRelease) {
        let current = currentBundleVersion()
        guard isNewer(release.version, than: current) else { return }
        if settings.skippedVersions.contains(release.version) {
            log("update available (v\(release.version)) but user skipped — staying quiet")
            return
        }
        log("update available: \(current) → v\(release.version)")
        pendingUpdate = release
        rebuildMenu()
    }

    /// Reference to the currently-shown 'Check for updates now…' menu
    /// item so we can update its title from the network result.
    /// Settled here because Swift 6 strict concurrency forbids
    /// sending an NSMenuItem across the actor boundary inside a
    /// Task.detached closure.
    private weak var checkNowItem: NSMenuItem?

    @objc private func checkForUpdatesNowClicked(_ sender: NSMenuItem) {
        sender.title = "Checking for updates…"
        sender.action = nil
        checkNowItem = sender
        Task { @MainActor in
            let release = await UpdateCheck.fetchLatest()
            var hadUpdate = false
            if let release {
                self.handleFetchedRelease(release)
                hadUpdate = self.pendingUpdate != nil
            }
            guard let item = self.checkNowItem else { return }
            item.title = hadUpdate ? "✓ Update available" : "✓ You're up to date"
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self, let item = self.checkNowItem else { return }
                item.title = "Check for updates now…"
                item.action = #selector(self.checkForUpdatesNowClicked(_:))
            }
        }
    }

    private func buildUpdateItem(for release: GitHubRelease) -> NSMenuItem {
        let parent = NSMenuItem(title: "Update to v\(release.version)",
                                action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false

        let whatsNew = NSMenuItem(title: "What's new…",
                                  action: #selector(whatsNewClicked(_:)),
                                  keyEquivalent: "")
        whatsNew.target = self
        sub.addItem(whatsNew)

        let updateNow = NSMenuItem(title: "Update now…",
                                   action: #selector(updateNowClicked(_:)),
                                   keyEquivalent: "")
        updateNow.target = self
        sub.addItem(updateNow)

        let skip = NSMenuItem(title: "Skip v\(release.version)",
                              action: #selector(skipVersionClicked(_:)),
                              keyEquivalent: "")
        skip.target = self
        sub.addItem(skip)

        parent.submenu = sub
        return parent
    }

    @objc private func whatsNewClicked(_ sender: NSMenuItem) {
        guard let release = pendingUpdate else { return }
        let alert = NSAlert()
        alert.messageText = "Parakey v\(release.version)"
        var body = release.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty { body = "(No release notes available for this version.)" }
        else if body.count > 1500 { body = String(body.prefix(1500)) + "\n\n…" }
        alert.informativeText = body
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Open in Browser")
        let response = alert.runModal()
        if response == .alertSecondButtonReturn,
           let url = URL(string: release.htmlURL) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func updateNowClicked(_ sender: NSMenuItem) {
        // Two paths: brew-installed users get the automated
        // upgrade-and-relaunch flow, source / non-brew installs
        // get the GitHub Releases page opened.
        if isBrewInstall(), let brew = findBrew() {
            spawnUpdateHelper(brewPath: brew)
        } else {
            log("update click: not a brew install or no brew, opening releases page")
            NSWorkspace.shared.open(GITHUB_RELEASES_PAGE)
        }
    }

    @objc private func skipVersionClicked(_ sender: NSMenuItem) {
        guard let release = pendingUpdate else { return }
        var skipped = settings.skippedVersions
        if !skipped.contains(release.version) {
            skipped.append(release.version)
            settings.skippedVersions = skipped
            log("user skipped v\(release.version); suppressing until a newer release")
        }
        pendingUpdate = nil
        rebuildMenu()
    }

    private func isBrewInstall() -> Bool {
        Bundle.main.bundlePath == "/Applications/Parakey.app"
    }

    private func findBrew() -> String? {
        for path in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    private func spawnUpdateHelper(brewPath: String) {
        // Detached shell helper that waits for THIS process to exit,
        // runs `brew upgrade --cask parakey`, then re-opens
        // /Applications/Parakey.app. We can't run `brew upgrade`
        // in-process because brew will try to replace the very
        // bundle we're executing from; the indirection through a
        // detached shell is what lets the upgrade actually complete.
        let pid = getpid()
        let script = """
            #!/bin/bash
            set -u
            for _ in $(seq 1 60); do
                if ! kill -0 \(pid) 2>/dev/null; then break; fi
                sleep 0.5
            done
            if ! "\(brewPath)" upgrade --cask parakey >/tmp/parakey-update.log 2>&1; then
                /usr/bin/open "\(GITHUB_RELEASES_PAGE.absoluteString)"
                exit 1
            fi
            /usr/bin/open "/Applications/Parakey.app"
            """
        let helperPath = "/tmp/parakey-update-\(UUID().uuidString.prefix(8)).sh"
        do {
            try script.write(toFile: helperPath, atomically: true, encoding: .utf8)
            _ = chmod(helperPath, 0o755)
        } catch {
            log("update: writing helper failed: \(error)")
            return
        }
        let proc = Process()
        proc.launchPath = "/bin/bash"
        proc.arguments = [helperPath]
        try? proc.run()
        log("update helper spawned at \(helperPath); quitting for upgrade")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
        }
    }

    // MARK: - TCC stale-state recovery on upgrade

    private func recoverStaleTCCAfterUpgrade() {
        let last = settings.lastSeenVersion
        let current = currentBundleVersion()
        guard !last.isEmpty else {
            // First-ever launch — just record the version. No state
            // to recover.
            settings.lastSeenVersion = current
            return
        }
        guard last != current else { return }
        log("upgrade detected: \(last) → \(current); checking for stale TCC state")
        let bundleID = Bundle.main.bundleIdentifier ?? "com.local.parakey"
        for p in Permission.allCases {
            if Permissions.isGranted(p) { continue }
            TCC.reset(p, bundleID: bundleID)
        }
        settings.lastSeenVersion = current
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = ParakeyApp()
app.delegate = delegate
app.run()
