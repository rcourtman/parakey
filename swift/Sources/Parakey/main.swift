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
import Darwin
import ApplicationServices
import FluidAudio
import IOKit
import UniformTypeIdentifiers

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
let CORRECTIONS_FILE_UTI = "com.local.parakey.corrections"
let CORRECTIONS_FILE_EXTENSION = "parakey-corrections"
let CORRECTIONS_FILE_NAME = "Parakey Corrections.\(CORRECTIONS_FILE_EXTENSION)"

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

struct TranscriptCorrection: Codable, Equatable, Sendable {
    let source: String
    let replacement: String
}

// MARK: - Text correction transfer

struct TranscriptCorrectionsDocument: Codable {
    let schemaVersion: Int
    let exportedAt: Date
    let appVersion: String
    let corrections: [TranscriptCorrection]
}

enum TranscriptCorrectionsDocumentError: LocalizedError {
    case unsupportedSchema(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            return "This corrections file uses schema version \(version), which this version of Parakey cannot read."
        }
    }
}

enum TranscriptCorrectionsTransfer {
    static let schemaVersion = 1
    static var contentType: UTType {
        UTType(filenameExtension: CORRECTIONS_FILE_EXTENSION)
            ?? UTType(exportedAs: CORRECTIONS_FILE_UTI, conformingTo: .json)
    }

    static func encode(_ corrections: [TranscriptCorrection]) throws -> Data {
        let document = TranscriptCorrectionsDocument(
            schemaVersion: schemaVersion,
            exportedAt: Date(),
            appVersion: currentBundleVersion(),
            corrections: normalizedTranscriptCorrections(corrections)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }

    static func decode(_ data: Data) throws -> [TranscriptCorrection] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let document = try? decoder.decode(TranscriptCorrectionsDocument.self, from: data) {
            guard document.schemaVersion == schemaVersion else {
                throw TranscriptCorrectionsDocumentError.unsupportedSchema(document.schemaVersion)
            }
            return normalizedTranscriptCorrections(document.corrections)
        }

        // Early internal builds stored the bare array. Keeping the
        // fallback costs almost nothing and makes hand-authored files
        // forgiving while the public file format settles.
        return normalizedTranscriptCorrections(try decoder.decode([TranscriptCorrection].self, from: data))
    }

    static func write(_ corrections: [TranscriptCorrection], to url: URL) throws {
        let data = try encode(corrections)
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static func read(from url: URL) throws -> [TranscriptCorrection] {
        try decode(try Data(contentsOf: url))
    }
}

func normalizedTranscriptCorrectionSource(_ source: String) -> String {
    source
        .split(whereSeparator: { $0.isWhitespace })
        .joined(separator: " ")
        .lowercased()
}

func normalizedTranscriptCorrections(_ corrections: [TranscriptCorrection]) -> [TranscriptCorrection] {
    var result: [TranscriptCorrection] = []
    var indexBySource: [String: Int] = [:]

    for correction in corrections {
        let source = correction.source.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = correction.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = normalizedTranscriptCorrectionSource(source)
        guard !source.isEmpty, !replacement.isEmpty, !key.isEmpty else { continue }

        let cleaned = TranscriptCorrection(source: source, replacement: replacement)
        if let existing = indexBySource[key] {
            result[existing] = cleaned
        } else {
            indexBySource[key] = result.count
            result.append(cleaned)
        }
    }

    return result
}

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
            do {
                let h = try FileHandle(forWritingTo: url)
                defer { try? h.close() }
                _ = try h.seekToEnd()
                try h.write(contentsOf: Data(line.utf8))
            } catch {
                let fallback = "Logger: file write failed: \(error.localizedDescription)\n"
                FileHandle.standardError.write(Data(fallback.utf8))
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
    private static let keyTranscriptCorrections = "transcript_corrections"
    private static let keyTranscriptCorrectionsSyncFile = "transcript_corrections_sync_file"

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

    var transcriptCorrections: [TranscriptCorrection] {
        get {
            guard let data = defaults.data(forKey: Self.keyTranscriptCorrections) else { return [] }
            do {
                return normalizedTranscriptCorrections(try JSONDecoder().decode([TranscriptCorrection].self, from: data))
            } catch {
                log("settings: transcript correction decode failed: \(error)")
                return []
            }
        }
        set {
            let corrections = normalizedTranscriptCorrections(newValue)
            guard !corrections.isEmpty else {
                defaults.removeObject(forKey: Self.keyTranscriptCorrections)
                return
            }
            do {
                let data = try JSONEncoder().encode(corrections)
                defaults.set(data, forKey: Self.keyTranscriptCorrections)
            } catch {
                log("settings: transcript correction encode failed: \(error)")
            }
        }
    }

    var transcriptCorrectionsSyncFile: String {
        get { defaults.string(forKey: Self.keyTranscriptCorrectionsSyncFile) ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                defaults.removeObject(forKey: Self.keyTranscriptCorrectionsSyncFile)
            } else {
                defaults.set(trimmed, forKey: Self.keyTranscriptCorrectionsSyncFile)
            }
        }
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

private struct HotkeyEventSnapshot: Sendable {
    let typeRawValue: UInt32
    let keycode: CGKeyCode
    let flagsRawValue: UInt64
    let isAutoRepeat: Bool

    var flags: CGEventFlags {
        CGEventFlags(rawValue: flagsRawValue)
    }
}

private enum HotkeyTransitionAction: Equatable, Sendable {
    case press
    case release
}

private struct HotkeyTransitionResult: Equatable, Sendable {
    let suppress: Bool
    let actions: [HotkeyTransitionAction]

    static let pass = HotkeyTransitionResult(suppress: false, actions: [])
    static let suppressOnly = HotkeyTransitionResult(suppress: true, actions: [])
}

private struct HotkeyTransitionState {
    private var hotkeyModifierDown = false
    private var toggleActive = false

    mutating func resetAll() {
        hotkeyModifierDown = false
        toggleActive = false
    }

    mutating func resetToggleState() {
        toggleActive = false
    }

    mutating func transition(
        for event: HotkeyEventSnapshot,
        hotkey: HotkeyChoice,
        triggerMode: TriggerMode
    ) -> HotkeyTransitionResult {
        guard event.keycode == hotkey.keycode else { return .pass }

        // Modifier masks are side-agnostic, so the physical keycode's
        // own down state is the source of truth for right-side releases.
        var isPress = false
        var isRelease = false
        if hotkey.isModifier {
            guard event.typeRawValue == CGEventType.flagsChanged.rawValue,
                  let mask = hotkey.modifierFlag else { return .suppressOnly }
            if hotkeyModifierDown {
                isRelease = true
                hotkeyModifierDown = false
            } else if event.flags.contains(mask) {
                isPress = true
                hotkeyModifierDown = true
            }
        } else {
            if event.typeRawValue == CGEventType.keyDown.rawValue, !event.isAutoRepeat {
                isPress = true
            } else if event.typeRawValue == CGEventType.keyUp.rawValue {
                isRelease = true
            } else {
                return .suppressOnly
            }
        }

        switch triggerMode {
        case .hold:
            var actions: [HotkeyTransitionAction] = []
            if isPress { actions.append(.press) }
            if isRelease { actions.append(.release) }
            return HotkeyTransitionResult(suppress: true, actions: actions)
        case .toggle:
            // Toggle mode: every press flips between "start recording"
            // and "stop recording". Releases are no-ops.
            guard isPress else { return .suppressOnly }
            let action: HotkeyTransitionAction = toggleActive ? .release : .press
            toggleActive.toggle()
            return HotkeyTransitionResult(suppress: true, actions: [action])
        }
    }
}

@MainActor
final class HotkeyListener {

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var transitionState = HotkeyTransitionState()

    /// User's current hotkey (set via Settings → Hotkey submenu).
    var hotkey: HotkeyChoice = hotkeyChoice(forKeycode: DEFAULT_HOTKEY_KEYCODE)
    var triggerMode: TriggerMode = .hold

    /// onPress fires when a recording should start (press in hold mode,
    /// or first press in toggle mode). onRelease fires when it should
    /// stop (release in hold mode, or second press in toggle mode).
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    @discardableResult
    func start() -> Bool {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
            return true
        }

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
                              | (1 << CGEventType.keyUp.rawValue)
                              | (1 << CGEventType.flagsChanged.rawValue)

        let opaqueSelf = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let listener = Unmanaged<HotkeyListener>.fromOpaque(userInfo).takeUnretainedValue()
                let snapshot = HotkeyEventSnapshot(
                    typeRawValue: type.rawValue,
                    keycode: CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)),
                    flagsRawValue: event.flags.rawValue,
                    isAutoRepeat: type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                )
                let shouldSuppress = MainActor.assumeIsolated {
                    listener.handleTapCallback(snapshot)
                }
                return shouldSuppress ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: opaqueSelf
        ) else {
            log("CGEvent.tapCreate failed — Input Monitoring permission missing?")
            return false
        }

        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log("HotkeyListener: tap active (watching \(hotkey.name))")
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        transitionState.resetAll()
    }

    /// Replace the current hotkey choice. Safe to call at runtime —
    /// the tap stays bound, only the per-event filter changes.
    func setHotkey(_ choice: HotkeyChoice) {
        self.hotkey = choice
        self.transitionState.resetAll()
        log("HotkeyListener: hotkey changed → \(choice.name)")
    }

    func setTriggerMode(_ mode: TriggerMode) {
        // Reset toggle state when switching modes so we don't get
        // stuck in mid-toggle from a previous session.
        if mode != triggerMode { transitionState.resetToggleState() }
        triggerMode = mode
        log("HotkeyListener: trigger mode → \(mode.rawValue)")
    }

    private func handleTapCallback(_ event: HotkeyEventSnapshot) -> Bool {
        if event.typeRawValue == CGEventType.tapDisabledByTimeout.rawValue
            || event.typeRawValue == CGEventType.tapDisabledByUserInput.rawValue {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
                log("HotkeyListener: event tap re-enabled after \(event.typeRawValue)")
            }
            return false
        }

        let result = transitionState.transition(for: event, hotkey: hotkey, triggerMode: triggerMode)
        dispatchHotkeyActions(result.actions)
        return result.suppress
    }

    private func dispatchHotkeyActions(_ actions: [HotkeyTransitionAction]) {
        guard !actions.isEmpty else { return }

        Task { @MainActor [weak self] in
            self?.performHotkeyActions(actions)
        }
    }

    private func performHotkeyActions(_ actions: [HotkeyTransitionAction]) {
        for action in actions {
            switch action {
            case .press: onPress?()
            case .release: onRelease?()
            }
        }
    }

    /// Called when the recording stops via a path other than the
    /// hotkey (auto-release at max duration, app quitting, etc.) so
    /// toggle mode doesn't end up offset by one.
    func resetToggleState() {
        transitionState.resetToggleState()
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
    private var recordingGeneration: UInt64 = 0

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

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            converter = nil
            throw error
        }
        log("AudioCapture: engine started")
    }

    func beginRecording() {
        lock.lock(); defer { lock.unlock() }
        recordingGeneration &+= 1
        samples.removeAll(keepingCapacity: true)
        _isRunning = true
    }

    /// Stops recording and returns the captured samples.
    func endRecording() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        _isRunning = false
        recordingGeneration &+= 1
        let captured = samples
        samples.removeAll(keepingCapacity: true)
        return captured
    }

    private func handleTap(buffer: AVAudioPCMBuffer, target: AVAudioFormat) {
        // Snapshot the running flag under lock; bail fast if we're
        // not recording so we don't pay conversion cost for nothing.
        lock.lock()
        let running = _isRunning
        let generation = recordingGeneration
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
        let inputProvider = AudioConverterInputProvider(buffer: buffer)
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            inputProvider.provide(outStatus: outStatus)
        }
        if status == .error {
            log("AudioCapture: convert error: \(error?.localizedDescription ?? "?")")
            return
        }
        guard let ch = out.floatChannelData?[0] else { return }
        let arr = Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))

        // Re-check running under lock — endRecording() might have
        // fired during conversion, then a rapid next recording may
        // already have started. The generation token keeps straggler
        // frames out of the next clip.
        lock.lock()
        if _isRunning && recordingGeneration == generation {
            samples.append(contentsOf: arr)
        }
        lock.unlock()
    }
}

private final class AudioConverterInputProvider: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private let lock = NSLock()
    private var didProvideBuffer = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func provide(outStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }

        if didProvideBuffer {
            outStatus.pointee = .noDataNow
            return nil
        }

        didProvideBuffer = true
        outStatus.pointee = .haveData
        return buffer
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

// MARK: - Transcript corrections
//
// Deterministic local rewrite pass for words or phrases the model
// consistently mishears. Corrections are applied to the transcript
// text before paste/history, never to audio, and replacement text is
// used exactly as the user typed it.

enum TranscriptCorrector {
    private struct Match {
        let range: NSRange
        let replacement: String
    }

    static func apply(to text: String, corrections: [TranscriptCorrection]) -> (text: String, appliedCount: Int) {
        let active = corrections
            .map { TranscriptCorrection(
                source: $0.source.trimmingCharacters(in: .whitespacesAndNewlines),
                replacement: $0.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            ) }
            .filter { !$0.source.isEmpty && !$0.replacement.isEmpty }
            .sorted { lhs, rhs in
                if lhs.source.count != rhs.source.count { return lhs.source.count > rhs.source.count }
                return lhs.source.localizedCaseInsensitiveCompare(rhs.source) == .orderedAscending
            }

        guard !text.isEmpty, !active.isEmpty else { return (text, 0) }

        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var matches: [Match] = []

        for correction in active {
            guard let pattern = pattern(for: correction.source),
                  let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            else { continue }

            regex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
                guard let range = match?.range, range.location != NSNotFound else { return }
                guard !matches.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) else { return }
                matches.append(Match(range: range, replacement: correction.replacement))
            }
        }

        guard !matches.isEmpty else { return (text, 0) }

        let rewritten = NSMutableString(string: text)
        for match in matches.sorted(by: { $0.range.location > $1.range.location }) {
            rewritten.replaceCharacters(in: match.range, with: match.replacement)
        }
        return (rewritten as String, matches.count)
    }

    private static func pattern(for source: String) -> String? {
        let parts = source
            .split(whereSeparator: { $0.isWhitespace })
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !parts.isEmpty else { return nil }
        return #"(?<![\p{L}\p{N}_])"# + parts.joined(separator: #"\s+"#) + #"(?![\p{L}\p{N}_])"#
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
    private var templateImage: NSImage?
    private var recordingImage: NSImage?
    private var errorImage: NSImage?
    private let audio = AudioCapture()
    private let hotkey = HotkeyListener()
    private let asr = TranscriptionWorker()
    private let settings = Settings.shared

    private var isRecording = false
    private var isBusy = false
    private var isReady = false
    private var isCoreRuntimeReady = false
    private var didStartUpdateCheckLoop = false
    private var permissionReadinessTimer: Timer?
    private var lastPermissionReadinessMissingKey: String?
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

    private struct CorrectionImportSummary {
        let total: Int
        let newCount: Int
        let updatedCount: Int
        let unchangedCount: Int
    }

    private enum CorrectionImportChoice {
        case merge
        case replace
    }

    private struct CorrectionSyncFileFingerprint: Equatable {
        let modifiedAt: Date?
        let size: Int?
    }

    private var correctionSyncTimer: Timer?
    private var correctionSyncFileFingerprint: CorrectionSyncFileFingerprint?
    private var isApplyingCorrectionSyncFile = false
    private var correctionSharePicker: NSSharingServicePicker?
    private var pendingSharedCorrectionsURL: URL?

    // MARK: - Lifecycle

    private func completeReadinessIfPossible(requireAllPermissions: Bool, reason: String) {
        if isReady {
            if missingPermissions().isEmpty {
                permClickCount.removeAll()
                stopPermissionReadinessMonitor()
            }
            rebuildMenu()
            return
        }

        guard isCoreRuntimeReady else {
            rebuildMenu()
            return
        }

        if requireAllPermissions {
            let missing = missingPermissions()
            guard missing.isEmpty else {
                logPermissionReadinessWait(missing)
                startPermissionReadinessMonitor(reason: reason)
                rebuildMenu()
                return
            }
        }

        hotkey.onPress = { [weak self] in self?.handlePress() }
        hotkey.onRelease = { [weak self] in self?.handleRelease() }
        guard hotkey.start() else {
            isReady = false
            isRecording = false
            isBusy = false
            hotkey.stop()
            log("readiness failed (\(reason)): hotkey listener unavailable")
            setMenuBarState(.error)
            if !missingPermissions().isEmpty {
                startPermissionReadinessMonitor(reason: reason)
            }
            rebuildMenu()
            return
        }

        isReady = true
        stopPermissionReadinessMonitor()
        setMenuBarState(.idle)

        // Belt-and-braces: clear any TCC entries stuck 'denied' from
        // an upgrade. Granted permissions stay intact. See the TCC
        // recovery section comment for why this is needed.
        recoverStaleTCCAfterUpgrade()

        rebuildMenu()
        startUpdateCheckLoop()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(settings.showInDock ? .regular : .accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        configureStatusItemImage()
        setMenuBarState(.loading)
        startCorrectionSyncIfConfigured()
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
                try audio.startEngine()
                self.isCoreRuntimeReady = true
                completeReadinessIfPossible(requireAllPermissions: false, reason: "launch")
            } catch {
                self.isCoreRuntimeReady = false
                self.isReady = false
                self.isRecording = false
                self.isBusy = false
                hotkey.stop()
                log("init failed: \(error)")
                setMenuBarState(.error)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopPermissionReadinessMonitor()
        correctionSyncTimer?.invalidate()
        correctionSyncTimer = nil
    }

    private func missingPermissions() -> [Permission] {
        Permission.allCases.filter { !Permissions.isGranted($0) }
    }

    @discardableResult
    private func logPermissionReadinessWait(_ missing: [Permission]) -> Bool {
        let key = missing.map(\.rawValue).joined(separator: "|")
        guard key != lastPermissionReadinessMissingKey else { return false }
        lastPermissionReadinessMissingKey = key
        log("readiness retry waiting for permissions: \(missing.map(\.rawValue).joined(separator: ", "))")
        return true
    }

    private func startPermissionReadinessMonitor(reason: String) {
        guard permissionReadinessTimer == nil else { return }
        log("permission readiness monitor started (\(reason))")
        permissionReadinessTimer = Timer.scheduledTimer(timeInterval: 2,
                                                        target: self,
                                                        selector: #selector(permissionReadinessTimerFired(_:)),
                                                        userInfo: nil,
                                                        repeats: true)
        permissionReadinessTimer?.tolerance = 0.5
    }

    private func stopPermissionReadinessMonitor() {
        guard permissionReadinessTimer != nil else { return }
        permissionReadinessTimer?.invalidate()
        permissionReadinessTimer = nil
        lastPermissionReadinessMissingKey = nil
        log("permission readiness monitor stopped")
    }

    @objc private func permissionReadinessTimerFired(_ timer: Timer) {
        guard isCoreRuntimeReady else {
            stopPermissionReadinessMonitor()
            return
        }

        if isReady {
            let missing = missingPermissions()
            guard !missing.isEmpty else {
                permClickCount.removeAll()
                stopPermissionReadinessMonitor()
                rebuildMenu()
                return
            }
            if logPermissionReadinessWait(missing) {
                rebuildMenu()
            }
            return
        }

        completeReadinessIfPossible(requireAllPermissions: true, reason: "permission monitor")
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        var didImport = false
        for filename in filenames {
            let url = URL(fileURLWithPath: filename)
            if importCorrectionsFromUserSelectedFile(url) {
                didImport = true
            }
        }
        sender.reply(toOpenOrPrint: didImport ? .success : .failure)
    }

    // MARK: - Menu bar appearance
    //
    // Same silhouette across all states; only the colour shifts. The
    // template image is used for idle/loading/busy (so it auto-adapts
    // to light/dark menu bar). For recording/error we swap to a
    // pre-tinted, non-template copy: NSStatusItem.button silently
    // drops contentTintColor on template images in some macOS
    // configurations, so baking the colour into the image is the only
    // reliable way to guarantee the recording state actually reads as
    // red.

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
        templateImage = image
        recordingImage = image.map { tintedCopy(of: $0, with: .systemRed) }
        errorImage = image.map { tintedCopy(of: $0, with: .systemYellow) }
        button.image = image
        button.imagePosition = .imageOnly
        if image == nil {
            button.title = "Parakey"
            log("statusItem: parakey-menubar.png not in Bundle.main — text fallback")
        }
        button.toolTip = "Parakey"
    }

    private func tintedCopy(of source: NSImage, with color: NSColor) -> NSImage {
        let size = source.size
        let tinted = NSImage(size: size)
        tinted.lockFocus()
        color.set()
        NSRect(origin: .zero, size: size).fill()
        source.draw(in: NSRect(origin: .zero, size: size),
                    from: .zero,
                    operation: .destinationIn,
                    fraction: 1.0)
        tinted.unlockFocus()
        tinted.isTemplate = false
        return tinted
    }

    private func setMenuBarState(_ state: MenuBarState) {
        guard let button = statusItem.button else { return }
        switch state {
        case .loading:
            // Subtle dim while the model compiles. nil contentTintColor
            // = system default (black/white per theme); .tertiary gives
            // a "this is here but not yet active" feel.
            button.image = templateImage
            button.contentTintColor = .tertiaryLabelColor
        case .idle:
            // Default tint — macOS auto-handles light/dark menu bar.
            button.image = templateImage
            button.contentTintColor = nil
        case .recording:
            button.image = recordingImage ?? templateImage
            button.contentTintColor = nil
        case .busy:
            // Transcribe is typically <200 ms, briefer than a perceptible
            // colour change. Leave at default; the menu's first row says
            // "Transcribing" if the user pops it open.
            button.image = templateImage
            button.contentTintColor = nil
        case .error:
            button.image = errorImage ?? templateImage
            button.contentTintColor = nil
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
                let corrected = TranscriptCorrector.apply(to: trimmed, corrections: settings.transcriptCorrections)
                if corrected.appliedCount > 0 {
                    log("transcript corrections applied: \(corrected.appliedCount)")
                }
                log("\(String(format: "%.2f", dur)) s audio → \(String(format: "%.2f", dt)) s → \(corrected.text.count) chars")
                if !corrected.text.isEmpty {
                    Paster.paste(corrected.text + " ")
                    Sounds.playDone()
                    addToHistory(corrected.text)
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
        if Permissions.isGranted(p) {
            permClickCount[p] = nil
            log("perm click ignored: \(p.rawValue) already granted")
            completeReadinessIfPossible(requireAllPermissions: true, reason: "permission already granted")
            return
        }

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
        startPermissionReadinessMonitor(reason: "permission grant")
        rebuildMenu()
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

        sub.addItem(buildCorrectionsItem())

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

        // Periodic-check toggle. The 6-hour poll plus the 30-seconds-
        // after-launch initial check catches every release; we don't
        // also expose a "Check now" action because (a) it duplicates
        // what the automatic poll already does and (b) users who want
        // to force one can quit + relaunch.
        let checkToggle = NSMenuItem(title: "Check for updates automatically",
                                     action: #selector(toggleCheckForUpdates(_:)),
                                     keyEquivalent: "")
        checkToggle.target = self
        checkToggle.state = settings.checkForUpdates ? .on : .off
        sub.addItem(checkToggle)

        parent.submenu = sub
        return parent
    }

    private func buildCorrectionsItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Text Corrections", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false

        let corrections = settings.transcriptCorrections

        let add = NSMenuItem(title: "Add Correction…",
                             action: #selector(addCorrectionClicked(_:)),
                             keyEquivalent: "")
        add.target = self
        sub.addItem(add)

        sub.addItem(.separator())

        let importItem = NSMenuItem(title: "Import Corrections…",
                                    action: #selector(importCorrectionsClicked(_:)),
                                    keyEquivalent: "")
        importItem.target = self
        sub.addItem(importItem)

        let exportItem = NSMenuItem(title: "Export Corrections…",
                                    action: #selector(exportCorrectionsClicked(_:)),
                                    keyEquivalent: "")
        exportItem.target = self
        exportItem.isEnabled = !corrections.isEmpty
        sub.addItem(exportItem)

        let shareItem = NSMenuItem(title: "Share Corrections…",
                                   action: #selector(shareCorrectionsClicked(_:)),
                                   keyEquivalent: "")
        shareItem.target = self
        shareItem.isEnabled = !corrections.isEmpty
        sub.addItem(shareItem)

        sub.addItem(.separator())

        if let syncURL = correctionSyncFileURL() {
            let syncLabel = NSMenuItem(title: "Syncing: \(syncURL.lastPathComponent)",
                                       action: nil,
                                       keyEquivalent: "")
            syncLabel.isEnabled = false
            syncLabel.toolTip = syncURL.path
            sub.addItem(syncLabel)

            let syncNow = NSMenuItem(title: "Sync Now",
                                     action: #selector(syncCorrectionsNowClicked(_:)),
                                     keyEquivalent: "")
            syncNow.target = self
            sub.addItem(syncNow)

            let stopSync = NSMenuItem(title: "Stop Syncing…",
                                      action: #selector(stopSyncingCorrectionsClicked(_:)),
                                      keyEquivalent: "")
            stopSync.target = self
            sub.addItem(stopSync)
        } else {
            let startSync = NSMenuItem(title: "Set Up Sync…",
                                       action: #selector(setUpCorrectionsSyncClicked(_:)),
                                       keyEquivalent: "")
            startSync.target = self
            sub.addItem(startSync)
        }

        sub.addItem(.separator())

        if corrections.isEmpty {
            let empty = NSMenuItem(title: "No corrections", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            sub.addItem(empty)
            parent.submenu = sub
            return parent
        }

        for (index, correction) in corrections.enumerated() {
            let item = NSMenuItem(title: correctionMenuTitle(correction),
                                  action: nil,
                                  keyEquivalent: "")
            let itemSub = NSMenu()
            itemSub.autoenablesItems = false

            let edit = NSMenuItem(title: "Edit…",
                                  action: #selector(editCorrectionClicked(_:)),
                                  keyEquivalent: "")
            edit.target = self
            edit.representedObject = index
            itemSub.addItem(edit)

            let delete = NSMenuItem(title: "Delete",
                                    action: #selector(deleteCorrectionClicked(_:)),
                                    keyEquivalent: "")
            delete.target = self
            delete.representedObject = index
            itemSub.addItem(delete)

            item.submenu = itemSub
            sub.addItem(item)
        }

        sub.addItem(.separator())

        let removeAll = NSMenuItem(title: "Remove All Corrections…",
                                   action: #selector(removeAllCorrectionsClicked(_:)),
                                   keyEquivalent: "")
        removeAll.target = self
        sub.addItem(removeAll)

        parent.submenu = sub
        return parent
    }

    private func correctionMenuTitle(_ correction: TranscriptCorrection) -> String {
        "\(clippedCorrectionText(correction.source)) → \(clippedCorrectionText(correction.replacement))"
    }

    private func clippedCorrectionText(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 32 ? String(flat.prefix(32)) + "…" : flat
    }

    @objc private func addCorrectionClicked(_ sender: NSMenuItem) {
        guard let correction = showCorrectionEditor(existing: nil) else { return }
        saveCorrection(correction)
    }

    @objc private func editCorrectionClicked(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        let corrections = settings.transcriptCorrections
        guard corrections.indices.contains(index) else { return }
        guard let correction = showCorrectionEditor(existing: corrections[index]) else { return }
        saveCorrection(correction, replacing: index)
    }

    @objc private func deleteCorrectionClicked(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        var corrections = settings.transcriptCorrections
        guard corrections.indices.contains(index) else { return }
        corrections.remove(at: index)
        updateTranscriptCorrections(corrections)
    }

    @objc private func removeAllCorrectionsClicked(_ sender: NSMenuItem) {
        guard !settings.transcriptCorrections.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove All Text Corrections?"
        alert.informativeText = "This removes every saved text correction from this Mac."
        alert.addButton(withTitle: "Remove All")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        updateTranscriptCorrections([])
    }

    @objc private func importCorrectionsClicked(_ sender: NSMenuItem) {
        showAppForModal()
        let panel = NSOpenPanel()
        panel.title = "Import Text Corrections"
        panel.message = "Choose a Parakey corrections file to import."
        panel.prompt = "Import"
        panel.allowedContentTypes = [TranscriptCorrectionsTransfer.contentType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = importCorrectionsFromUserSelectedFile(url)
    }

    @objc private func exportCorrectionsClicked(_ sender: NSMenuItem) {
        showAppForModal()
        let panel = NSSavePanel()
        panel.title = "Export Text Corrections"
        panel.message = "Save a file you can AirDrop, store in iCloud Drive, or import on another Mac."
        panel.prompt = "Export"
        panel.nameFieldStringValue = CORRECTIONS_FILE_NAME
        panel.allowedContentTypes = [TranscriptCorrectionsTransfer.contentType]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try TranscriptCorrectionsTransfer.write(settings.transcriptCorrections, to: url)
            log("correction export wrote \(settings.transcriptCorrections.count) corrections")
        } catch {
            showCorrectionTransferError(title: "Export Failed", error: error)
        }
    }

    @objc private func shareCorrectionsClicked(_ sender: NSMenuItem) {
        showAppForModal()
        do {
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("Parakey-\(UUID().uuidString)", isDirectory: true)
            let url = folder.appendingPathComponent(CORRECTIONS_FILE_NAME)
            try TranscriptCorrectionsTransfer.write(settings.transcriptCorrections, to: url)
            pendingSharedCorrectionsURL = url

            let picker = NSSharingServicePicker(items: [url])
            correctionSharePicker = picker
            if let button = statusItem.button {
                picker.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            }
            log("correction share prepared \(settings.transcriptCorrections.count) corrections")
        } catch {
            showCorrectionTransferError(title: "Share Failed", error: error)
        }
    }

    @objc private func setUpCorrectionsSyncClicked(_ sender: NSMenuItem) {
        showAppForModal()
        let alert = NSAlert()
        alert.messageText = "Set Up Text Correction Sync"
        alert.informativeText = """
            Parakey can keep corrections in one local file. Put that file in iCloud Drive, Dropbox, Syncthing, or another synced folder to keep multiple Macs aligned without a Parakey account.

            Parakey only reads and writes the file you choose.
            """
        alert.addButton(withTitle: "Create Sync File")
        alert.addButton(withTitle: "Use Existing File")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            createCorrectionsSyncFile()
        case .alertSecondButtonReturn:
            useExistingCorrectionsSyncFile()
        default:
            return
        }
    }

    @objc private func syncCorrectionsNowClicked(_ sender: NSMenuItem) {
        guard correctionSyncFileURL() != nil else { return }
        _ = refreshCorrectionSyncFromDisk(force: true, presentErrors: true)
    }

    @objc private func stopSyncingCorrectionsClicked(_ sender: NSMenuItem) {
        showAppForModal()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Stop Syncing Text Corrections?"
        alert.informativeText = "Parakey will keep the corrections already on this Mac. The sync file will not be deleted."
        alert.addButton(withTitle: "Stop Syncing")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        settings.transcriptCorrectionsSyncFile = ""
        correctionSyncTimer?.invalidate()
        correctionSyncTimer = nil
        correctionSyncFileFingerprint = nil
        rebuildMenu()
    }

    private func showAppForModal() {
        NSApp.activate(ignoringOtherApps: true)
    }

    @discardableResult
    private func importCorrectionsFromUserSelectedFile(_ url: URL) -> Bool {
        showAppForModal()
        do {
            let imported = try TranscriptCorrectionsTransfer.read(from: url)
            guard let choice = chooseCorrectionImportMode(imported: imported,
                                                          sourceName: url.lastPathComponent,
                                                          allowsEmptyReplace: false) else {
                return false
            }
            let next = corrections(afterApplying: imported, mode: choice)
            updateTranscriptCorrections(next)
            log("correction import read \(imported.count) corrections")
            return true
        } catch {
            showCorrectionTransferError(title: "Import Failed", error: error)
            return false
        }
    }

    private func createCorrectionsSyncFile() {
        let panel = NSSavePanel()
        panel.title = "Create Text Correction Sync File"
        panel.message = "Choose where Parakey should keep the sync file. A folder synced by iCloud Drive or another provider works best."
        panel.prompt = "Create"
        panel.nameFieldStringValue = CORRECTIONS_FILE_NAME
        panel.allowedContentTypes = [TranscriptCorrectionsTransfer.contentType]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try TranscriptCorrectionsTransfer.write(settings.transcriptCorrections, to: url)
            settings.transcriptCorrectionsSyncFile = url.path
            startCorrectionSyncIfConfigured()
            log("correction sync created file with \(settings.transcriptCorrections.count) corrections")
        } catch {
            showCorrectionTransferError(title: "Sync Setup Failed", error: error)
        }
    }

    private func useExistingCorrectionsSyncFile() {
        let panel = NSOpenPanel()
        panel.title = "Choose Text Correction Sync File"
        panel.message = "Choose an existing Parakey corrections file."
        panel.prompt = "Use File"
        panel.allowedContentTypes = [TranscriptCorrectionsTransfer.contentType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let imported = try TranscriptCorrectionsTransfer.read(from: url)
            guard let choice = chooseCorrectionImportMode(imported: imported,
                                                          sourceName: url.lastPathComponent,
                                                          allowsEmptyReplace: true) else {
                return
            }
            let next = corrections(afterApplying: imported, mode: choice)
            settings.transcriptCorrectionsSyncFile = url.path
            updateTranscriptCorrections(next, writeToSync: false)
            if choice == .merge {
                guard writeCorrectionsToSyncFile(presentErrors: true) else {
                    settings.transcriptCorrectionsSyncFile = ""
                    rebuildMenu()
                    return
                }
            } else {
                correctionSyncFileFingerprint = correctionSyncFingerprint(for: url)
            }
            startCorrectionSyncIfConfigured()
            log("correction sync linked file with \(imported.count) corrections")
        } catch {
            showCorrectionTransferError(title: "Sync Setup Failed", error: error)
        }
    }

    private func chooseCorrectionImportMode(imported: [TranscriptCorrection],
                                            sourceName: String,
                                            allowsEmptyReplace: Bool) -> CorrectionImportChoice? {
        let imported = normalizedTranscriptCorrections(imported)
        if imported.isEmpty {
            let alert = NSAlert()
            alert.messageText = "No Text Corrections Found"
            alert.informativeText = allowsEmptyReplace
                ? "\(sourceName) does not contain any corrections. You can still use it as an empty sync file."
                : "\(sourceName) does not contain any corrections to import."
            alert.addButton(withTitle: allowsEmptyReplace ? "Use Empty File" : "OK")
            if allowsEmptyReplace { alert.addButton(withTitle: "Cancel") }
            let response = alert.runModal()
            return allowsEmptyReplace && response == .alertFirstButtonReturn ? .replace : nil
        }

        let summary = correctionImportSummary(for: imported)
        let alert = NSAlert()
        alert.messageText = "Import Text Corrections?"
        alert.informativeText = """
            \(sourceName) contains \(summary.total) corrections.

            \(summary.newCount) new, \(summary.updatedCount) will update existing corrections, \(summary.unchangedCount) already match.

            Merge keeps local corrections that are not in the file. Replace All makes this Mac match the file exactly.
            """
        alert.addButton(withTitle: "Merge")
        alert.addButton(withTitle: "Replace All")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .merge
        case .alertSecondButtonReturn:
            return .replace
        default:
            return nil
        }
    }

    private func correctionImportSummary(for imported: [TranscriptCorrection]) -> CorrectionImportSummary {
        let existingBySource = Dictionary(uniqueKeysWithValues: settings.transcriptCorrections.map {
            (normalizedTranscriptCorrectionSource($0.source), $0)
        })

        var newCount = 0
        var updatedCount = 0
        var unchangedCount = 0

        for correction in imported {
            let key = normalizedTranscriptCorrectionSource(correction.source)
            guard let existing = existingBySource[key] else {
                newCount += 1
                continue
            }
            if existing == correction {
                unchangedCount += 1
            } else {
                updatedCount += 1
            }
        }

        return CorrectionImportSummary(
            total: imported.count,
            newCount: newCount,
            updatedCount: updatedCount,
            unchangedCount: unchangedCount
        )
    }

    private func corrections(afterApplying imported: [TranscriptCorrection],
                             mode: CorrectionImportChoice) -> [TranscriptCorrection] {
        let imported = normalizedTranscriptCorrections(imported)
        switch mode {
        case .replace:
            return imported
        case .merge:
            var merged = settings.transcriptCorrections
            var indexBySource = Dictionary(uniqueKeysWithValues: merged.enumerated().map {
                (normalizedTranscriptCorrectionSource($0.element.source), $0.offset)
            })

            for correction in imported {
                let key = normalizedTranscriptCorrectionSource(correction.source)
                if let index = indexBySource[key] {
                    merged[index] = correction
                } else {
                    indexBySource[key] = merged.count
                    merged.append(correction)
                }
            }
            return merged
        }
    }

    private func updateTranscriptCorrections(_ corrections: [TranscriptCorrection],
                                             writeToSync: Bool = true) {
        settings.transcriptCorrections = normalizedTranscriptCorrections(corrections)
        if writeToSync, !isApplyingCorrectionSyncFile {
            writeCorrectionsToSyncFile(presentErrors: false)
        }
        rebuildMenu()
    }

    private func correctionSyncFileURL() -> URL? {
        let path = settings.transcriptCorrectionsSyncFile
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func startCorrectionSyncIfConfigured() {
        correctionSyncTimer?.invalidate()
        correctionSyncTimer = nil
        guard correctionSyncFileURL() != nil else {
            correctionSyncFileFingerprint = nil
            return
        }

        _ = refreshCorrectionSyncFromDisk(force: true, presentErrors: false)
        correctionSyncTimer = Timer.scheduledTimer(timeInterval: 4,
                                                   target: self,
                                                   selector: #selector(correctionSyncTimerFired(_:)),
                                                   userInfo: nil,
                                                   repeats: true)
        correctionSyncTimer?.tolerance = 1
    }

    @objc private func correctionSyncTimerFired(_ timer: Timer) {
        _ = refreshCorrectionSyncFromDisk(force: false, presentErrors: false)
    }

    @discardableResult
    private func refreshCorrectionSyncFromDisk(force: Bool, presentErrors: Bool) -> Bool {
        guard let url = correctionSyncFileURL() else { return false }
        guard let fingerprint = correctionSyncFingerprint(for: url) else {
            if presentErrors {
                showCorrectionTransferError(title: "Sync Failed",
                                            message: "Parakey could not find the selected sync file.")
            }
            return false
        }

        guard force || fingerprint != correctionSyncFileFingerprint else { return false }

        do {
            let corrections = try TranscriptCorrectionsTransfer.read(from: url)
            isApplyingCorrectionSyncFile = true
            updateTranscriptCorrections(corrections, writeToSync: false)
            isApplyingCorrectionSyncFile = false
            correctionSyncFileFingerprint = fingerprint
            log("correction sync read \(corrections.count) corrections")
            return true
        } catch {
            isApplyingCorrectionSyncFile = false
            log("correction sync read failed: \(error)")
            if presentErrors {
                showCorrectionTransferError(title: "Sync Failed", error: error)
            }
            return false
        }
    }

    @discardableResult
    private func writeCorrectionsToSyncFile(presentErrors: Bool) -> Bool {
        guard let url = correctionSyncFileURL() else { return true }
        do {
            try TranscriptCorrectionsTransfer.write(settings.transcriptCorrections, to: url)
            correctionSyncFileFingerprint = correctionSyncFingerprint(for: url)
            log("correction sync wrote \(settings.transcriptCorrections.count) corrections")
            return true
        } catch {
            log("correction sync write failed: \(error)")
            if presentErrors {
                showCorrectionTransferError(title: "Sync Failed", error: error)
            }
            return false
        }
    }

    private func correctionSyncFingerprint(for url: URL) -> CorrectionSyncFileFingerprint? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else {
            return nil
        }
        return CorrectionSyncFileFingerprint(modifiedAt: values.contentModificationDate,
                                             size: values.fileSize)
    }

    private func showCorrectionTransferError(title: String, error: Error) {
        showCorrectionTransferError(title: title, message: error.localizedDescription)
    }

    private func showCorrectionTransferError(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showCorrectionEditor(existing: TranscriptCorrection?) -> TranscriptCorrection? {
        let alert = NSAlert()
        alert.messageText = existing == nil ? "Add Text Correction" : "Edit Text Correction"
        alert.informativeText = "Add the incorrect text Parakey typed, then the text it should paste instead."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let viewWidth: CGFloat = 360
        let labelWidth: CGFloat = 70
        let fieldWidth: CGFloat = viewWidth - labelWidth - 10
        let rowHeight: CGFloat = 24
        let viewHeight: CGFloat = 58
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: viewWidth, height: viewHeight))

        let sourceLabel = NSTextField(labelWithString: "Typed")
        sourceLabel.alignment = .right
        sourceLabel.frame = NSRect(x: 0, y: 34, width: labelWidth, height: rowHeight)

        let sourceField = NSTextField(frame: NSRect(x: labelWidth + 10, y: 34, width: fieldWidth, height: rowHeight))
        sourceField.stringValue = existing?.source ?? ""
        sourceField.placeholderString = "clawed"

        let replacementLabel = NSTextField(labelWithString: "Paste")
        replacementLabel.alignment = .right
        replacementLabel.frame = NSRect(x: 0, y: 0, width: labelWidth, height: rowHeight)

        let replacementField = NSTextField(frame: NSRect(x: labelWidth + 10, y: 0, width: fieldWidth, height: rowHeight))
        replacementField.stringValue = existing?.replacement ?? ""
        replacementField.placeholderString = "Claude"

        accessory.addSubview(sourceLabel)
        accessory.addSubview(sourceField)
        accessory.addSubview(replacementLabel)
        accessory.addSubview(replacementField)
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = sourceField

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        let source = sourceField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = replacementField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !replacement.isEmpty else {
            showCorrectionValidationError()
            return nil
        }

        return TranscriptCorrection(source: source, replacement: replacement)
    }

    private func showCorrectionValidationError() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Correction Not Saved"
        alert.informativeText = "Both fields need text."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func saveCorrection(_ correction: TranscriptCorrection, replacing index: Int? = nil) {
        var corrections = settings.transcriptCorrections
        let key = normalizedTranscriptCorrectionSource(correction.source)

        if let index, corrections.indices.contains(index) {
            corrections[index] = correction
            var keepIndex = index
            for i in corrections.indices.reversed() {
                guard i != keepIndex, normalizedTranscriptCorrectionSource(corrections[i].source) == key else { continue }
                corrections.remove(at: i)
                if i < keepIndex { keepIndex -= 1 }
            }
        } else if let duplicate = corrections.firstIndex(where: { normalizedTranscriptCorrectionSource($0.source) == key }) {
            corrections[duplicate] = correction
        } else {
            corrections.append(correction)
        }

        updateTranscriptCorrections(corrections)
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
        guard !didStartUpdateCheckLoop else { return }
        didStartUpdateCheckLoop = true
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

#if DEBUG
private enum SelfTestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

private enum ParakeySelfTest {
    static func run(arguments: [String]) -> Int32? {
        guard arguments.count >= 2, arguments[0] == "--self-test" else { return nil }
        guard arguments.count == 2 else { return fail("usage") }

        switch arguments[1] {
        case "hotkey":
            return runSuite("hotkey", testHotkey)
        case "all":
            return runSuite("all", testHotkey)
        default:
            return fail("unknown")
        }
    }

    private static func runSuite(_ name: String, _ body: () throws -> Void) -> Int32 {
        do {
            try body()
            print("PASS \(name)")
            return EXIT_SUCCESS
        } catch {
            print("FAIL \(name): \(error)")
            return EXIT_FAILURE
        }
    }

    private static func fail(_ message: String) -> Int32 {
        print("FAIL self-test: \(message)")
        return EXIT_FAILURE
    }

    private static func testHotkey() throws {
        try testHandledHotkeySuppression()
        try testFKeyAutoRepeatSuppressesWithoutAction()
        try testRightModifierReleaseWithLeftFlagStillSet()
        try testTogglePressFlipsOnceAndReleaseIsNoOp()
    }

    private static func testHandledHotkeySuppression() throws {
        var state = HotkeyTransitionState()
        let f5 = hotkeyChoice(forKeycode: 96)

        try expect(
            state.transition(for: event(.keyDown, keycode: f5.keycode), hotkey: f5, triggerMode: .hold),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "F-key keyDown should suppress and press"
        )
        try expect(
            state.transition(for: event(.keyDown, keycode: 97), hotkey: f5, triggerMode: .hold),
            equals: .pass,
            "non-hotkey keyDown should pass through"
        )
        try expect(
            state.transition(for: event(.keyUp, keycode: f5.keycode), hotkey: f5, triggerMode: .hold),
            equals: HotkeyTransitionResult(suppress: true, actions: [.release]),
            "F-key keyUp should suppress and release"
        )
    }

    private static func testFKeyAutoRepeatSuppressesWithoutAction() throws {
        var state = HotkeyTransitionState()
        let f5 = hotkeyChoice(forKeycode: 96)

        try expect(
            state.transition(for: event(.keyDown, keycode: f5.keycode), hotkey: f5, triggerMode: .hold),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "initial F-key keyDown should press"
        )
        try expect(
            state.transition(for: event(.keyDown, keycode: f5.keycode, isAutoRepeat: true), hotkey: f5, triggerMode: .hold),
            equals: .suppressOnly,
            "F-key autorepeat keyDown should suppress without action"
        )
    }

    private static func testRightModifierReleaseWithLeftFlagStillSet() throws {
        var state = HotkeyTransitionState()
        let rightOption = hotkeyChoice(forKeycode: 61)
        let alternate = CGEventFlags.maskAlternate.rawValue

        try expect(
            state.transition(for: event(.flagsChanged, keycode: rightOption.keycode, flags: alternate), hotkey: rightOption, triggerMode: .hold),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "right modifier flagsChanged should press"
        )
        try expect(
            state.transition(for: event(.flagsChanged, keycode: rightOption.keycode, flags: alternate), hotkey: rightOption, triggerMode: .hold),
            equals: HotkeyTransitionResult(suppress: true, actions: [.release]),
            "right modifier release should be recognized while left-side flag remains set"
        )
    }

    private static func testTogglePressFlipsOnceAndReleaseIsNoOp() throws {
        var state = HotkeyTransitionState()
        let f5 = hotkeyChoice(forKeycode: 96)

        try expect(
            state.transition(for: event(.keyDown, keycode: f5.keycode), hotkey: f5, triggerMode: .toggle),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "first toggle press should start"
        )
        try expect(
            state.transition(for: event(.keyUp, keycode: f5.keycode), hotkey: f5, triggerMode: .toggle),
            equals: .suppressOnly,
            "toggle release should be a no-op"
        )
        try expect(
            state.transition(for: event(.keyDown, keycode: f5.keycode), hotkey: f5, triggerMode: .toggle),
            equals: HotkeyTransitionResult(suppress: true, actions: [.release]),
            "second toggle press should stop"
        )
    }

    private static func event(
        _ type: CGEventType,
        keycode: CGKeyCode,
        flags: UInt64 = 0,
        isAutoRepeat: Bool = false
    ) -> HotkeyEventSnapshot {
        HotkeyEventSnapshot(
            typeRawValue: type.rawValue,
            keycode: keycode,
            flagsRawValue: flags,
            isAutoRepeat: isAutoRepeat
        )
    }

    private static func expect(
        _ actual: HotkeyTransitionResult,
        equals expected: HotkeyTransitionResult,
        _ message: String
    ) throws {
        guard actual == expected else {
            throw SelfTestFailure.failed("\(message): got \(actual), expected \(expected)")
        }
    }
}

if let status = ParakeySelfTest.run(arguments: Array(CommandLine.arguments.dropFirst())) {
    exit(status)
}
#endif

let app = NSApplication.shared
let delegate = ParakeyApp()
app.delegate = delegate
app.run()
