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
import AudioToolbox
import Foundation
import CoreGraphics
import Darwin
import ApplicationServices
import FluidAudio
import IOKit
import QuartzCore
import UniformTypeIdentifiers

// MARK: - Constants

let SAMPLE_RATE: Double = 16_000
let DEFAULT_HOTKEY_KEYCODE: CGKeyCode = 61  // Right Option
let ESCAPE_KEYCODE: CGKeyCode = 53
let MIN_CLIP_SECONDS: Double = 0.25
let MAX_RECORDING_SECONDS: TimeInterval = 120   // auto-release if held longer
let UPDATE_CHECK_FIRST_DELAY_SECONDS: TimeInterval = 30
let UPDATE_CHECK_INTERVAL_SECONDS: TimeInterval = 6 * 3600  // 6h
let GITHUB_LATEST_RELEASE_URL = URL(string: "https://api.github.com/repos/rcourtman/parakey/releases/latest")!
let GITHUB_RELEASES_PAGE = URL(string: "https://github.com/rcourtman/parakey/releases/latest")!
let HOMEBREW_CASK_TOKEN = "rcourtman/parakey/parakey"
let HOMEBREW_CASK_INSTALLED_TOKEN = "parakey"
let INSTALLED_APP_BUNDLE_PATH = "/Applications/Parakey.app"
let UPDATE_HELPER_LOG_PATH = "/tmp/parakey-update.log"
let RECORDING_HUD_EXPANDED_SIZE = NSSize(width: 232, height: 54)
let RECORDING_HUD_COLLAPSED_SIZE = NSSize(width: 58, height: 42)
let RECORDING_HUD_ANIMATE_IN_SECONDS: TimeInterval = 0.12
let RECORDING_HUD_ANIMATE_OUT_SECONDS: TimeInterval = 0.08

let SETTINGS_SUITE = "com.local.parakey"
let CORRECTIONS_FILE_UTI = "com.local.parakey.corrections"
let CORRECTIONS_FILE_EXTENSION = "parakey-corrections"
let CORRECTIONS_FILE_NAME = "Parakey Corrections.\(CORRECTIONS_FILE_EXTENSION)"

/// Visible state of the menu-bar item. Idle/loading/busy use the
/// template image so macOS handles light/dark menu bars. Recording and
/// error states use pre-tinted static frames so the state remains
/// visible even when macOS ignores contentTintColor on template images.
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

enum PasteSuffix: String { case appendSpace = "space", none, appendNewline = "newline" }
let PASTE_SUFFIX_DISPLAY: [PasteSuffix: String] = [
    .appendSpace: "Append space",
    .none: "No suffix",
    .appendNewline: "Append newline",
]

enum RecentTranscriptLimit: String, CaseIterable {
    case off
    case last1 = "1"
    case last5 = "5"

    var count: Int {
        switch self {
        case .off: return 0
        case .last1: return 1
        case .last5: return 5
        }
    }
}

let DEFAULT_RECENT_TRANSCRIPT_LIMIT = RecentTranscriptLimit.last5
let RECENT_TRANSCRIPT_LIMIT_DISPLAY: [RecentTranscriptLimit: String] = [
    .off: "Off",
    .last1: "Last 1",
    .last5: "Last 5",
]

func parseRecentTranscriptLimit(storedValue value: Any?) -> RecentTranscriptLimit? {
    if let raw = value as? String {
        return RecentTranscriptLimit(rawValue: raw)
    }
    if let number = value as? NSNumber {
        return RecentTranscriptLimit(rawValue: number.stringValue)
    }
    return nil
}

func limitedRecentTranscripts(_ transcripts: [String], limit: RecentTranscriptLimit) -> [String] {
    let count = limit.count
    guard count > 0 else { return [] }
    guard transcripts.count > count else { return transcripts }
    return Array(transcripts.prefix(count))
}

struct AudioInputDevice: Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

private let CORE_AUDIO_DEFAULT_AGGREGATE_PREFIX = "CADefaultDeviceAggregate-"

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

func normalizedAudioLevel(from samples: [Float]) -> Float {
    var sumSquares: Double = 0
    var count = 0

    for sample in samples where sample.isFinite {
        let clamped = max(-1, min(1, sample))
        sumSquares += Double(clamped * clamped)
        count += 1
    }

    return normalizedAudioLevel(sumSquares: sumSquares, sampleCount: count)
}

func normalizedAudioLevel(sumSquares: Double, sampleCount: Int) -> Float {
    guard sampleCount > 0, sumSquares > 0 else { return 0 }
    let rms = sqrt(sumSquares / Double(sampleCount))
    guard rms.isFinite, rms > 0 else { return 0 }

    // This is a voice-visibility meter, not a calibrated VU meter.
    // Keep low room tone calm, then aggressively lift speech-range RMS
    // so normal close-mic speech visibly opens the HUD without shouting.
    let decibels = 20 * log10(rms)
    let gated = (decibels + 52) / 20
    guard gated > 0.06 else { return 0 }
    let lifted = pow(max(0, min(1, gated)), 0.42)
    return Float(max(0, min(1, lifted)))
}

func visibleRecordingLevel(rawLevel: Float) -> Float {
    guard rawLevel.isFinite else { return 0 }
    return max(0, min(1, rawLevel))
}

struct TranscriptCorrectionSyncMergeResult: Equatable {
    let corrections: [TranscriptCorrection]
    let conflictingSources: [String]
}

func mergedTranscriptCorrectionsForSync(base: [TranscriptCorrection],
                                        local: [TranscriptCorrection],
                                        remote: [TranscriptCorrection]) -> TranscriptCorrectionSyncMergeResult {
    let base = normalizedTranscriptCorrections(base)
    let local = normalizedTranscriptCorrections(local)
    let remote = normalizedTranscriptCorrections(remote)

    func dictionaryBySource(_ corrections: [TranscriptCorrection]) -> [String: TranscriptCorrection] {
        Dictionary(uniqueKeysWithValues: corrections.map {
            (normalizedTranscriptCorrectionSource($0.source), $0)
        })
    }

    let baseBySource = dictionaryBySource(base)
    let localBySource = dictionaryBySource(local)
    let remoteBySource = dictionaryBySource(remote)

    var orderedSources: [String] = []
    var seenSources: Set<String> = []
    func appendSources(from corrections: [TranscriptCorrection]) {
        for correction in corrections {
            let key = normalizedTranscriptCorrectionSource(correction.source)
            if seenSources.insert(key).inserted {
                orderedSources.append(key)
            }
        }
    }

    appendSources(from: local)
    appendSources(from: remote)
    appendSources(from: base)

    var merged: [TranscriptCorrection] = []
    var conflicts: [String] = []

    for source in orderedSources {
        let baseline = baseBySource[source]
        let localCorrection = localBySource[source]
        let remoteCorrection = remoteBySource[source]

        let chosen: TranscriptCorrection?
        if localCorrection == remoteCorrection {
            chosen = localCorrection
        } else if localCorrection == baseline {
            chosen = remoteCorrection
        } else if remoteCorrection == baseline {
            chosen = localCorrection
        } else {
            conflicts.append(localCorrection?.source ?? remoteCorrection?.source ?? baseline?.source ?? source)
            continue
        }

        if let chosen {
            merged.append(chosen)
        }
    }

    return TranscriptCorrectionSyncMergeResult(corrections: merged,
                                               conflictingSources: conflicts)
}

// MARK: - Audio input devices

func audioObjectStringProperty(_ objectID: AudioObjectID,
                               selector: AudioObjectPropertySelector) -> String? {
    var address = AudioObjectPropertyAddress(mSelector: selector,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var rawValue: UnsafeRawPointer?
    var size = UInt32(MemoryLayout<UnsafeRawPointer?>.size)
    let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &rawValue)
    guard status == noErr, let rawValue else { return nil }
    let string = Unmanaged<CFString>.fromOpaque(rawValue).takeUnretainedValue() as String
    return string.isEmpty ? nil : string
}

func audioDeviceHasInputChannels(_ deviceID: AudioDeviceID) -> Bool {
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                             mScope: kAudioDevicePropertyScopeInput,
                                             mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
          size > 0 else { return false }

    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                               alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { raw.deallocate() }
    let bufferList = raw.assumingMemoryBound(to: AudioBufferList.self)
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, bufferList) == noErr else {
        return false
    }

    let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
    return buffers.contains { $0.mNumberChannels > 0 }
}

func isDefaultAggregateAudioInputPreference(_ preference: String) -> Bool {
    let trimmed = preference.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.range(of: CORE_AUDIO_DEFAULT_AGGREGATE_PREFIX,
                         options: [.anchored, .caseInsensitive]) != nil
}

func isDefaultAggregateAudioInputDevice(_ device: AudioInputDevice) -> Bool {
    isDefaultAggregateAudioInputPreference(device.uid)
        || isDefaultAggregateAudioInputPreference(device.name)
}

func availableAudioInputDevices() -> [AudioInputDevice] {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size) == noErr,
          size >= UInt32(MemoryLayout<AudioDeviceID>.size) else { return [] }

    let count = Int(size) / MemoryLayout<AudioDeviceID>.size
    var ids = Array(repeating: AudioDeviceID(0), count: count)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                     &address, 0, nil, &size, &ids) == noErr else { return [] }

    return ids.compactMap { id in
        guard audioDeviceHasInputChannels(id),
              let uid = audioObjectStringProperty(id, selector: kAudioDevicePropertyDeviceUID),
              let name = audioObjectStringProperty(id, selector: kAudioObjectPropertyName) else {
            return nil
        }
        let device = AudioInputDevice(id: id, uid: uid, name: name)
        return isDefaultAggregateAudioInputDevice(device) ? nil : device
    }
    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
}

func audioInputDevice(matching preference: String,
                      in devices: [AudioInputDevice] = availableAudioInputDevices()) -> AudioInputDevice? {
    let trimmed = preference.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard !isDefaultAggregateAudioInputPreference(trimmed) else { return nil }
    return devices.first { $0.uid == trimmed }
        ?? devices.first { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
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
    private static let keyPasteSuffix = "paste_suffix"
    private static let keyRecentTranscripts = "recent_transcripts"
    private static let keyShowRecordingWaveform = "show_recording_waveform"
    private static let legacyKeyShowRecordingIndicator = "show_recording_indicator"
    private static let keyMuteWhileRecording = "mute_while_recording"
    private static let keyPlayFeedbackSounds = "play_feedback_sounds"
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

    var pasteSuffix: PasteSuffix {
        get {
            if let v = defaults.string(forKey: Self.keyPasteSuffix), let s = PasteSuffix(rawValue: v) {
                return s
            }
            return .appendSpace
        }
        set { defaults.set(newValue.rawValue, forKey: Self.keyPasteSuffix) }
    }

    var recentTranscriptLimit: RecentTranscriptLimit {
        get {
            parseRecentTranscriptLimit(storedValue: defaults.object(forKey: Self.keyRecentTranscripts))
                ?? DEFAULT_RECENT_TRANSCRIPT_LIMIT
        }
        set { defaults.set(newValue.rawValue, forKey: Self.keyRecentTranscripts) }
    }

    var showRecordingWaveform: Bool {
        get {
            if defaults.object(forKey: Self.keyShowRecordingWaveform) != nil {
                return defaults.bool(forKey: Self.keyShowRecordingWaveform)
            }
            if defaults.object(forKey: Self.legacyKeyShowRecordingIndicator) != nil {
                return defaults.bool(forKey: Self.legacyKeyShowRecordingIndicator)
            }
            return true
        }
        set { defaults.set(newValue, forKey: Self.keyShowRecordingWaveform) }
    }

    var muteWhileRecording: Bool {
        get {
            if defaults.object(forKey: Self.keyMuteWhileRecording) == nil { return true }
            return defaults.bool(forKey: Self.keyMuteWhileRecording)
        }
        set { defaults.set(newValue, forKey: Self.keyMuteWhileRecording) }
    }

    var playFeedbackSounds: Bool {
        get {
            if defaults.object(forKey: Self.keyPlayFeedbackSounds) == nil { return true }
            return defaults.bool(forKey: Self.keyPlayFeedbackSounds)
        }
        set { defaults.set(newValue, forKey: Self.keyPlayFeedbackSounds) }
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

enum Permission: String, CaseIterable, Equatable {
    case microphone = "Microphone"
    case accessibility = "Accessibility"
    case inputMonitoring = "Input Monitoring"
}

private enum ReadinessTransition: Equatable {
    case rebuildMenuOnly
    case blockForPermissions([Permission])
    case startHotkeyListener
}

private func readinessTransition(
    isReady: Bool,
    isCoreRuntimeReady: Bool,
    missingPermissions: [Permission]
) -> ReadinessTransition {
    if isReady {
        return missingPermissions.isEmpty
            ? .rebuildMenuOnly
            : .blockForPermissions(missingPermissions)
    }

    guard isCoreRuntimeReady else {
        return .rebuildMenuOnly
    }

    return missingPermissions.isEmpty
        ? .startHotkeyListener
        : .blockForPermissions(missingPermissions)
}

private enum AudioRouteChangeAction: Equatable {
    case ignore
    case rebuildMenuOnly
    case deferRefresh
    case restartNow
}

private func audioRouteChangeAction(isTerminating: Bool,
                                    isRestartingAudioInput: Bool,
                                    isCoreRuntimeReady: Bool,
                                    isRecording: Bool,
                                    isBusy: Bool,
                                    hasStartupTask: Bool) -> AudioRouteChangeAction {
    guard !isTerminating, !isRestartingAudioInput else { return .ignore }
    guard isCoreRuntimeReady else { return .rebuildMenuOnly }
    guard !isRecording, !isBusy, !hasStartupTask else { return .deferRefresh }
    return .restartNow
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
    case cancel
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
    private var suppressEscapeKeyUp = false

    mutating func resetAll() {
        hotkeyModifierDown = false
        toggleActive = false
        suppressEscapeKeyUp = false
    }

    mutating func resetToggleState() {
        toggleActive = false
    }

    mutating func transition(
        for event: HotkeyEventSnapshot,
        hotkey: HotkeyChoice,
        triggerMode: TriggerMode,
        isRecording: Bool
    ) -> HotkeyTransitionResult {
        if event.keycode == ESCAPE_KEYCODE {
            return transitionEscape(for: event, isRecording: isRecording)
        }

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

    private mutating func transitionEscape(
        for event: HotkeyEventSnapshot,
        isRecording: Bool
    ) -> HotkeyTransitionResult {
        if event.typeRawValue == CGEventType.keyDown.rawValue {
            if event.isAutoRepeat, suppressEscapeKeyUp {
                return .suppressOnly
            }
            guard isRecording else { return .pass }
            suppressEscapeKeyUp = true
            return event.isAutoRepeat
                ? .suppressOnly
                : HotkeyTransitionResult(suppress: true, actions: [.cancel])
        }

        if event.typeRawValue == CGEventType.keyUp.rawValue, suppressEscapeKeyUp {
            suppressEscapeKeyUp = false
            return .suppressOnly
        }

        return .pass
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
    /// onCancel fires for Escape while a recording is active.
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onCancel: (() -> Void)?
    var isRecordingActive: (() -> Bool)?

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

        let result = transitionState.transition(for: event,
                                                hotkey: hotkey,
                                                triggerMode: triggerMode,
                                                isRecording: isRecordingActive?() ?? false)
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
            case .cancel: onCancel?()
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
    private var converterInputFormat: AVAudioFormat?
    private var manuallyMixInputToMono = false
    private let lock = NSLock()
    private var samples: [Float] = []
    private var _isRunning = false
    private var latestLevel: Float = 0
    private var latestLevelSequence: UInt64 = 0
    private var recordingGeneration: UInt64 = 0
    private var configurationObserver: NSObjectProtocol?

    var onConfigurationChange: (@Sendable () -> Void)?

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isRunning
    }

    func startEngine(inputDevicePreference: String = "") throws {
        let input = engine.inputNode
        applyInputDevicePreference(inputDevicePreference, to: input)
        let inputFormat = input.outputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: SAMPLE_RATE,
            channels: 1,
            interleaved: false
        ) else { throw NSError(domain: "Parakey", code: -1) }

        let sourceFormat = converterSourceFormat(for: inputFormat)
        converterInputFormat = sourceFormat
        manuallyMixInputToMono = inputFormat.channelCount > 1 && sourceFormat.channelCount == 1
        converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        let mixLabel = manuallyMixInputToMono ? " via manual mono mix" : ""
        log("AudioCapture: input \(inputFormat.sampleRate) Hz \(inputFormat.channelCount)ch\(mixLabel) → \(targetFormat.sampleRate) Hz mono")

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
        installConfigurationObserver()
        log("AudioCapture: engine started")
    }

    func stopEngine() {
        removeConfigurationObserver()

        lock.lock()
        _isRunning = false
        latestLevel = 0
        latestLevelSequence &+= 1
        recordingGeneration &+= 1
        samples.removeAll(keepingCapacity: true)
        lock.unlock()

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        converterInputFormat = nil
        manuallyMixInputToMono = false
    }

    private func installConfigurationObserver() {
        removeConfigurationObserver()
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            self?.onConfigurationChange?()
        }
    }

    private func removeConfigurationObserver() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
    }

    func beginRecording() {
        lock.lock(); defer { lock.unlock() }
        recordingGeneration &+= 1
        samples.removeAll(keepingCapacity: true)
        latestLevel = 0
        latestLevelSequence &+= 1
        _isRunning = true
    }

    /// Stops recording and returns the captured samples.
    func endRecording() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        _isRunning = false
        latestLevel = 0
        latestLevelSequence &+= 1
        recordingGeneration &+= 1
        let captured = samples
        samples.removeAll(keepingCapacity: true)
        return captured
    }

    func latestRecordingLevelSnapshot() -> (level: Float, sequence: UInt64) {
        lock.lock(); defer { lock.unlock() }
        return _isRunning ? (latestLevel, latestLevelSequence) : (0, latestLevelSequence)
    }

    private func handleTap(buffer: AVAudioPCMBuffer, target: AVAudioFormat) {
        // Snapshot the running flag under lock; bail fast if we're
        // not recording so we don't pay conversion cost for nothing.
        lock.lock()
        let running = _isRunning
        let generation = recordingGeneration
        lock.unlock()
        guard running, let converter else { return }

        let converterInput = preparedConverterInputBuffer(from: buffer) ?? buffer
        let ratio = target.sampleRate / converterInput.format.sampleRate
        let outCap = AVAudioFrameCount(Double(converterInput.frameLength) * ratio + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCap) else { return }

        // .noDataNow vs .endOfStream: this is reusing the same
        // AVAudioConverter across every tap callback (~50 Hz). If we
        // signal .endOfStream after the buffer, the converter goes
        // into a terminal state and produces 0 samples on every
        // subsequent call — exactly the "first capture was 0.10s,
        // every press after that was 0.00s" bug we saw before this
        // fix. .noDataNow means "I'm out of input *for this call*,
        // but the stream continues" and leaves the converter usable.
        let inputProvider = AudioConverterInputProvider(buffer: converterInput)
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            inputProvider.provide(outStatus: outStatus)
        }
        if status == .error {
            log("AudioCapture: convert error: \(error?.localizedDescription ?? "?")")
            return
        }
        guard let ch = out.floatChannelData?[0] else { return }
        let frameCount = Int(out.frameLength)
        var arr: [Float] = []
        arr.reserveCapacity(frameCount)
        var sumSquares: Double = 0
        var finiteSampleCount = 0
        for sample in UnsafeBufferPointer(start: ch, count: frameCount) {
            arr.append(sample)
            guard sample.isFinite else { continue }
            let clamped = max(-1, min(1, sample))
            sumSquares += Double(clamped * clamped)
            finiteSampleCount += 1
        }
        let level = normalizedAudioLevel(sumSquares: sumSquares,
                                         sampleCount: finiteSampleCount)

        // Re-check running under lock — endRecording() might have
        // fired during conversion, then a rapid next recording may
        // already have started. The generation token keeps straggler
        // frames out of the next clip.
        lock.lock()
        if _isRunning && recordingGeneration == generation {
            samples.append(contentsOf: arr)
            latestLevel = level
            latestLevelSequence &+= 1
        }
        lock.unlock()
    }

    private func converterSourceFormat(for inputFormat: AVAudioFormat) -> AVAudioFormat {
        guard inputFormat.channelCount > 1,
              let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: inputFormat.sampleRate,
                                             channels: 1,
                                             interleaved: false) else {
            return inputFormat
        }
        return monoFormat
    }

    private func preparedConverterInputBuffer(from buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard manuallyMixInputToMono else { return buffer }
        guard let monoFormat = converterInputFormat,
              let channels = buffer.floatChannelData else {
            return nil
        }

        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        guard channelCount > 1, frameCount > 0 else { return buffer }
        guard let out = AVAudioPCMBuffer(pcmFormat: monoFormat,
                                         frameCapacity: AVAudioFrameCount(frameCount)),
              let mono = out.floatChannelData?[0] else {
            return nil
        }

        var channelRMS = Array(repeating: 0.0, count: channelCount)
        for channelIndex in 0..<channelCount {
            var sumSquares = 0.0
            let source = channels[channelIndex]
            for frameIndex in 0..<frameCount {
                let sample = source[frameIndex]
                guard sample.isFinite else { continue }
                let clamped = max(-1, min(1, sample))
                sumSquares += Double(clamped * clamped)
            }
            channelRMS[channelIndex] = sqrt(sumSquares / Double(frameCount))
        }

        let peak = channelRMS.max() ?? 0
        let activeChannels = channelRMS.enumerated()
            .filter { pair in peak > 0 && pair.element >= peak * 0.25 }
            .map { $0.offset }
        let selectedChannels = activeChannels.isEmpty ? [0] : activeChannels
        let scale = Float(1.0 / Double(selectedChannels.count))

        for frameIndex in 0..<frameCount {
            var mixed: Float = 0
            for channelIndex in selectedChannels {
                mixed += channels[channelIndex][frameIndex] * scale
            }
            mono[frameIndex] = mixed
        }
        out.frameLength = AVAudioFrameCount(frameCount)
        return out
    }

    private func applyInputDevicePreference(_ preference: String, to input: AVAudioInputNode) {
        let trimmed = preference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !isDefaultAggregateAudioInputPreference(trimmed) else { return }

        guard let device = audioInputDevice(matching: trimmed) else {
            log("AudioCapture: saved input device unavailable, using system default")
            return
        }
        guard let unit = input.audioUnit else {
            log("AudioCapture: input audio unit unavailable, using system default")
            return
        }

        var deviceID = device.id
        let status = AudioUnitSetProperty(unit,
                                          kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global,
                                          0,
                                          &deviceID,
                                          UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            log("AudioCapture: input device switch failed (\(status)), using system default")
            return
        }
        log("AudioCapture: selected input \(device.name)")
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

    func load(progressHandler: DownloadUtils.ProgressHandler? = nil) async throws {
        if ready, asr != nil {
            log("ASR: already ready")
            return
        }

        log("ASR: downloading + loading Parakeet TDT v3 CoreML weights…")
        let t0 = Date()
        let models = try await AsrModels.downloadAndLoad(version: .v3, progressHandler: progressHandler)
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

func pastedText(from correctedTranscript: String, suffix: PasteSuffix) -> String {
    switch suffix {
    case .appendSpace:
        return correctedTranscript + " "
    case .none:
        return correctedTranscript
    case .appendNewline:
        return correctedTranscript + "\n"
    }
}

func speechModelStartupStatusTitle(_ progress: DownloadUtils.DownloadProgress) -> String {
    switch progress.phase {
    case .listing:
        return "Checking speech model files…"
    case .downloading(let completedFiles, let totalFiles):
        guard totalFiles > 0 else { return "Loading cached speech model…" }
        let downloadFraction = min(max(progress.fractionCompleted / 0.5, 0), 1)
        let percent = min(100, max(0, Int((downloadFraction * 20).rounded()) * 5))
        return "Downloading speech model… \(percent)% (\(completedFiles)/\(totalFiles))"
    case .compiling:
        return "Preparing speech model…"
    }
}

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
// Short system sounds: Tink on recording start, Pop after a
// successful paste. Loaded from /System/Library/Sounds so we don't
// have to bundle audio resources.

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

func currentBundleBuild() -> String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
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

func shellSingleQuoted(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
}

func updateHelperScript(pid: pid_t,
                        brewPath: String,
                        targetVersion: String,
                        appPath: String = INSTALLED_APP_BUNDLE_PATH,
                        releasesPageURL: String = GITHUB_RELEASES_PAGE.absoluteString,
                        logPath: String = UPDATE_HELPER_LOG_PATH) -> String {
    #"""
    #!/bin/bash
    set -u

    LOG=\#(shellSingleQuoted(logPath))
    BREW=\#(shellSingleQuoted(brewPath))
    TARGET_VERSION=\#(shellSingleQuoted(targetVersion))
    APP_PATH=\#(shellSingleQuoted(appPath))
    RELEASES_PAGE=\#(shellSingleQuoted(releasesPageURL))
    PARAKEY_PID=\#(pid)
    CASK_TOKEN=\#(shellSingleQuoted(HOMEBREW_CASK_TOKEN))
    INFO_PLIST="$APP_PATH/Contents/Info.plist"

    timestamp() {
        /bin/date -u '+%Y-%m-%dT%H:%M:%SZ'
    }

    log() {
        echo "[$(timestamp)] $*" >>"$LOG"
    }

    fail() {
        log "$*"
        /usr/bin/open "$RELEASES_PAGE"
        exit 1
    }

    app_version() {
        /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST" 2>/dev/null || true
    }

    version_at_least() {
        /usr/bin/awk -v actual="$1" -v target="$2" '
            BEGIN {
                actual_count = split(actual, actual_parts, ".")
                target_count = split(target, target_parts, ".")
                for (i = 1; i <= 4; i++) {
                    actual_part = i <= actual_count ? actual_parts[i] : "0"
                    target_part = i <= target_count ? target_parts[i] : "0"
                    sub(/[^0-9].*$/, "", actual_part)
                    sub(/[^0-9].*$/, "", target_part)
                    actual_number = actual_part == "" ? 0 : actual_part + 0
                    target_number = target_part == "" ? 0 : target_part + 0
                    if (actual_number > target_number) { exit 0 }
                    if (actual_number < target_number) { exit 1 }
                }
                exit 0
            }'
    }

    run_brew() {
        log "Running: $BREW $*"
        "$BREW" "$@" >>"$LOG" 2>&1
    }

    wait_for_parakey_exit() {
        for _ in {1..60}; do
            if ! kill -0 "$PARAKEY_PID" 2>/dev/null; then
                return 0
            fi
            sleep 0.5
        done

        log "Parakey was still running after 30s; sending TERM before updating."
        kill -TERM "$PARAKEY_PID" 2>/dev/null || true
        for _ in {1..20}; do
            if ! kill -0 "$PARAKEY_PID" 2>/dev/null; then
                return 0
            fi
            sleep 0.5
        done

        fail "Parakey did not quit, so the app bundle was not touched."
    }

    installed_target_version() {
        local installed
        installed="$(app_version)"
        log "Installed app version: ${installed:-unknown}"
        [ -n "$installed" ] && version_at_least "$installed" "$TARGET_VERSION"
    }

    {
        echo "[$(timestamp)] Parakey update starting"
        echo "Target version: $TARGET_VERSION"
        echo "Current installed version: $(app_version)"
        echo "Brew: $BREW"
        echo "Cask: $CASK_TOKEN"
        echo "App: $APP_PATH"
    } >"$LOG"

    wait_for_parakey_exit

    if ! run_brew update; then
        fail "brew update failed; leaving the existing app in place."
    fi

    if ! run_brew upgrade --cask "$CASK_TOKEN"; then
        fail "brew cask upgrade failed; leaving the existing app in place."
    fi

    if ! installed_target_version; then
        log "brew upgrade completed without installing v$TARGET_VERSION; forcing cask reinstall."
        if ! run_brew reinstall --cask "$CASK_TOKEN"; then
            fail "brew cask reinstall failed; leaving the existing app in place."
        fi
    fi

    if ! installed_target_version; then
        fail "Expected Parakey v$TARGET_VERSION or newer after update, but the installed app is still $(app_version)."
    fi

    log "Update complete; relaunching Parakey."
    /usr/bin/open "$APP_PATH"
    """#
}

// MARK: - App
//
// Single class that owns the lifecycle and the AppKit menu-bar UI.
// All UI state lives here; subsystems (HotkeyListener, AudioCapture,
// TranscriptionWorker, UpdateCheck, …) hold their own state but
// call back into `ParakeyApp` for anything that touches the menu.

@MainActor
final class CorrectionShareCleanupDelegate: NSObject, @preconcurrency NSSharingServicePickerDelegate, NSSharingServiceDelegate {
    private let cleanup: (String) -> Void

    init(cleanup: @escaping (String) -> Void) {
        self.cleanup = cleanup
    }

    private func runCleanup(reason: String) {
        cleanup(reason)
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker,
                              delegateFor sharingService: NSSharingService) -> NSSharingServiceDelegate? {
        self
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker,
                              didChoose service: NSSharingService?) {
        if service == nil {
            runCleanup(reason: "dismissed")
        }
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        runCleanup(reason: "shared")
    }

    func sharingService(_ sharingService: NSSharingService,
                        didFailToShareItems items: [Any],
                        error: Error) {
        runCleanup(reason: "share failed")
    }
}

private final class RecordingHUDView: NSView {
    var level: Float = 0 {
        didSet { needsDisplay = true }
    }

    var phase: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let capsuleBounds = bounds.insetBy(dx: 1, dy: 1)
        let capsule = NSBezierPath(roundedRect: capsuleBounds,
                                   xRadius: capsuleBounds.height / 2,
                                   yRadius: capsuleBounds.height / 2)
        NSColor(calibratedWhite: 0.06, alpha: 0.9).setFill()
        capsule.fill()

        let clamped = CGFloat(max(0, min(1, level)))

        let recordDotRect = NSRect(x: 17, y: bounds.midY - 6, width: 12, height: 12)
        NSColor.systemRed.withAlphaComponent(0.18 + (0.22 * clamped)).setFill()
        NSBezierPath(ovalIn: recordDotRect.insetBy(dx: -5, dy: -5)).fill()
        NSColor.systemRed.withAlphaComponent(0.92).setFill()
        NSBezierPath(ovalIn: recordDotRect).fill()

        guard clamped > 0.001 else { return }

        let barCount = 29
        let barWidth: CGFloat = 3
        let barGap: CGFloat = 3
        let minHeight: CGFloat = 3
        let maxHeight: CGFloat = 28
        let startX: CGFloat = 46
        let centerY = bounds.midY
        let centerIndex = CGFloat(barCount - 1) / 2

        for index in 0..<barCount {
            let i = CGFloat(index)
            let distance = abs(i - centerIndex) / centerIndex
            let envelope = pow(max(0, 1 - distance), 0.55)
            let ripple = (sin((i * 0.74) + phase) + 1) / 2
            let fineRipple = (sin((i * 1.73) - (phase * 0.7)) + 1) / 2
            let motion = (ripple * 0.68) + (fineRipple * 0.32)
            let quietShape = 0.06 + (0.1 * envelope)
            let activeShape = 0.16 + (envelope * (0.5 + (0.5 * motion)))
            let activity = max(quietShape, min(1, quietShape + (clamped * activeShape)))
            let height = minHeight + ((maxHeight - minHeight) * activity)
            let x = startX + CGFloat(index) * (barWidth + barGap)
            let rect = NSRect(x: x,
                              y: centerY - (height / 2),
                              width: barWidth,
                              height: height)
            let path = NSBezierPath(roundedRect: rect,
                                    xRadius: barWidth / 2,
                                    yRadius: barWidth / 2)
            let hue = NSColor.systemRed.blended(withFraction: 0.16, of: .white) ?? .systemRed
            hue.withAlphaComponent(0.28 + (0.72 * activity)).setFill()
            path.fill()
        }
    }
}

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
    private var isTerminating = false
    private var didStartUpdateCheckLoop = false
    private var startupTask: Task<Void, Never>?
    private var startupStatusTitle = "Loading speech model…"
    private var startupFailure: StartupFailure?
    private var didTouchAudioEngine = false
    private var permissionReadinessTimer: Timer?
    private var lastPermissionReadinessMissingKey: String?
    private var didMuteThisRecording: Bool = false
    private var maxDurationWorkItem: DispatchWorkItem?
    private var isRestartingAudioInput = false
    private var pendingAudioRouteRefresh = false
    private var recordingLevelTimer: Timer?
    private var recordingVisualLevel: Float = 0
    private var recordingHUDPhase: CGFloat = 0
    private var lastRecordingLevelSequence: UInt64 = 0
    private var staleRecordingLevelTicks = 0
    private var recordingHUDPanel: NSPanel?
    private var recordingHUDView: RecordingHUDView?
    private var recordingHUDAnimationToken = 0

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

    private enum StartupFailureStage {
        case speechModel
        case audioInput
        case hotkeyListener

        var statusTitle: String {
            switch self {
            case .speechModel: return "Speech model failed to load"
            case .audioInput: return "Audio input failed to start"
            case .hotkeyListener: return "Hotkey listener failed to start"
            }
        }

        var retryTitle: String {
            switch self {
            case .speechModel: return "Retry Loading Speech Model"
            case .audioInput: return "Retry Audio Startup"
            case .hotkeyListener: return "Retry Hotkey Startup"
            }
        }
    }

    private struct StartupFailure {
        let stage: StartupFailureStage
        let detail: String

        var statusTitle: String { stage.statusTitle }
        var retryTitle: String { stage.retryTitle }
    }

    private struct CorrectionSyncFileFingerprint: Equatable {
        let modifiedAt: Date?
        let size: Int?
    }

    private var correctionSyncTimer: Timer?
    private var correctionSyncFileFingerprint: CorrectionSyncFileFingerprint?
    private var correctionSyncBaselineCorrections: [TranscriptCorrection] = []
    private var isApplyingCorrectionSyncFile = false
    private var correctionSharePicker: NSSharingServicePicker?
    private var correctionShareCleanupDelegate: CorrectionShareCleanupDelegate?
    private var pendingSharedCorrectionsURL: URL?

    // MARK: - Lifecycle

    private func completeReadinessIfPossible(reason: String) {
        let missing = (isReady || isCoreRuntimeReady) ? missingPermissions() : []
        switch readinessTransition(isReady: isReady,
                                   isCoreRuntimeReady: isCoreRuntimeReady,
                                   missingPermissions: missing) {
        case .rebuildMenuOnly:
            if isReady {
                permClickCount.removeAll()
                stopPermissionReadinessMonitor()
            }
            rebuildMenu()
            return
        case .blockForPermissions(let missing):
            enterPermissionBlockedState(missing: missing, reason: reason)
            return
        case .startHotkeyListener:
            break
        }

        hotkey.onPress = { [weak self] in self?.handlePress() }
        hotkey.onRelease = { [weak self] in self?.handleRelease() }
        hotkey.onCancel = { [weak self] in self?.cancelActiveRecording(reason: "escape") }
        hotkey.isRecordingActive = { [weak self] in self?.isRecording == true }
        guard hotkey.start() else {
            isReady = false
            isRecording = false
            isBusy = false
            hotkey.onPress = nil
            hotkey.onRelease = nil
            hotkey.onCancel = nil
            hotkey.isRecordingActive = nil
            hotkey.resetToggleState()
            hotkey.stop()
            log("readiness failed (\(reason)): hotkey listener unavailable")
            setMenuBarState(.error)
            if missingPermissions().isEmpty {
                startupFailure = StartupFailure(stage: .hotkeyListener,
                                                detail: "The keyboard event tap could not be started.")
            } else {
                startPermissionReadinessMonitor(reason: reason)
            }
            rebuildMenu()
            return
        }

        isReady = true
        startupStatusTitle = "Ready"
        startupFailure = nil
        stopPermissionReadinessMonitor()
        setMenuBarState(.idle)

        rebuildMenu()
        startUpdateCheckLoop()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        recoverStaleTCCAfterUpgrade()

        NSApp.setActivationPolicy(settings.showInDock ? .regular : .accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        configureStatusItemImage()
        setMenuBarState(.loading)
        startCorrectionSyncIfConfigured()
        rebuildMenu()

        audio.onConfigurationChange = { [weak self] in
            Task { @MainActor in
                self?.handleAudioConfigurationChange()
            }
        }

        // Configure hotkey listener up front so it picks up the user's
        // saved choice the moment the tap goes live.
        hotkey.setHotkey(hotkeyChoice(forKeycode: settings.hotkeyKeycode))
        hotkey.setTriggerMode(settings.triggerMode)

        startStartup(reason: "launch")
    }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        startupTask?.cancel()
        startupTask = nil
        stopPermissionReadinessMonitor()
        correctionSyncTimer?.invalidate()
        correctionSyncTimer = nil
        cleanupPendingSharedCorrections(reason: "terminate")
        audio.onConfigurationChange = nil
        cancelRecordingForTermination()
    }

    private func cleanupPendingSharedCorrections(reason: String) {
        correctionSharePicker = nil
        correctionShareCleanupDelegate = nil

        guard let url = pendingSharedCorrectionsURL else { return }
        pendingSharedCorrectionsURL = nil

        let folder = url.deletingLastPathComponent().standardizedFileURL
        let tempRoot = FileManager.default.temporaryDirectory.standardizedFileURL.path
        let normalizedTempRoot = tempRoot.hasSuffix("/") ? tempRoot : "\(tempRoot)/"

        guard url.lastPathComponent == CORRECTIONS_FILE_NAME,
              folder.lastPathComponent.hasPrefix("Parakey-"),
              folder.path.hasPrefix(normalizedTempRoot)
        else {
            log("correction share cleanup skipped (\(reason)): unexpected temp file")
            return
        }

        do {
            try FileManager.default.removeItem(at: folder)
            log("correction share cleanup completed (\(reason))")
        } catch {
            log("correction share cleanup failed (\(reason))")
        }
    }

    private func startStartup(reason: String) {
        guard startupTask == nil else {
            log("startup ignored (\(reason)): already in progress")
            rebuildMenu()
            return
        }

        prepareForStartupAttempt()

        // Load ASR FIRST, then audio + hotkey. Reversing this order
        // makes the first-launch CoreML compile of the ANE Encoder
        // hang. The bench under experiments/swift-bench/ never opens
        // an audio session so it doesn't see this.
        startupTask = Task { @MainActor in
            var stage = StartupFailureStage.speechModel
            defer {
                startupTask = nil
                rebuildMenu()
            }

            do {
                try await asr.load { [weak self] progress in
                    Task { @MainActor in
                        self?.updateSpeechModelStartupProgress(progress)
                    }
                }
                guard !Task.isCancelled, !isTerminating else { return }

                stage = .audioInput
                startupStatusTitle = "Starting audio input…"
                rebuildMenu()

                didTouchAudioEngine = true
                try audio.startEngine(inputDevicePreference: settings.inputDevice)
                guard !Task.isCancelled, !isTerminating else { return }

                isCoreRuntimeReady = true
                startupFailure = nil
                startupStatusTitle = "Finishing setup…"
                completeReadinessIfPossible(reason: reason)
            } catch {
                guard !Task.isCancelled, !isTerminating else { return }
                recordStartupFailure(stage: stage, error: error, reason: reason)
            }
        }
    }

    private func prepareForStartupAttempt() {
        cancelMaxDurationAutoRelease()

        if isRecording || audio.isRunning {
            _ = audio.endRecording()
        }
        stopRecordingLevelMeter()
        unmuteIfWeMuted()

        isReady = false
        isCoreRuntimeReady = false
        isRecording = false
        isBusy = false
        startupFailure = nil
        startupStatusTitle = "Loading speech model…"

        hotkey.onPress = nil
        hotkey.onRelease = nil
        hotkey.onCancel = nil
        hotkey.isRecordingActive = nil
        hotkey.resetToggleState()
        hotkey.stop()
        if didTouchAudioEngine {
            audio.stopEngine()
        }

        setMenuBarState(.loading)
        rebuildMenu()
    }

    private func updateSpeechModelStartupProgress(_ progress: DownloadUtils.DownloadProgress) {
        guard startupTask != nil, !isTerminating else { return }
        let next = speechModelStartupStatusTitle(progress)
        guard next != startupStatusTitle else { return }
        startupStatusTitle = next
        rebuildMenu()
    }

    private func recordStartupFailure(stage: StartupFailureStage, error: Error, reason: String) {
        isCoreRuntimeReady = false
        isReady = false
        isRecording = false
        isBusy = false
        stopRecordingLevelMeter()

        hotkey.onPress = nil
        hotkey.onRelease = nil
        hotkey.onCancel = nil
        hotkey.isRecordingActive = nil
        hotkey.resetToggleState()
        hotkey.stop()
        if didTouchAudioEngine {
            audio.stopEngine()
        }

        let detail = error.localizedDescription
        startupFailure = StartupFailure(stage: stage, detail: detail)
        log("startup failed (\(reason), \(stage)): \(error)")
        setMenuBarState(.error)
        if !missingPermissions().isEmpty {
            startPermissionReadinessMonitor(reason: reason)
        }
        rebuildMenu()
    }

    private func enterPermissionBlockedState(missing: [Permission]? = nil, reason: String) {
        let missing = missing ?? missingPermissions()
        guard !missing.isEmpty else {
            completeReadinessIfPossible(reason: reason)
            return
        }

        cancelMaxDurationAutoRelease()
        if isRecording || audio.isRunning {
            _ = audio.endRecording()
        }
        stopRecordingLevelMeter()
        unmuteIfWeMuted()

        isReady = false
        isRecording = false
        isBusy = false
        hotkey.onPress = nil
        hotkey.onRelease = nil
        hotkey.onCancel = nil
        hotkey.isRecordingActive = nil
        hotkey.resetToggleState()
        hotkey.stop()

        logPermissionReadinessWait(missing)
        startPermissionReadinessMonitor(reason: reason)
        setMenuBarState(.loading)
        rebuildMenu()
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

        if isReady {
            let missing = missingPermissions()
            guard !missing.isEmpty else {
                permClickCount.removeAll()
                stopPermissionReadinessMonitor()
                rebuildMenu()
                return
            }
            enterPermissionBlockedState(missing: missing, reason: "permission monitor")
            return
        }

        completeReadinessIfPossible(reason: "permission monitor")
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
    // Same silhouette across all states; only colour shifts. The
    // template image is used for idle/loading/busy so it auto-adapts to
    // light/dark menu bar. For recording/error we swap to pre-rendered,
    // non-template images: NSStatusItem.button silently drops
    // contentTintColor on template images in some macOS configurations,
    // so baking the colour into the image is the only reliable way to
    // guarantee the recording state actually reads.

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
        let rect = NSRect(origin: .zero, size: size)
        let tinted = NSImage(size: size)
        tinted.lockFocus()
        drawTintedIcon(source, in: rect, color: color)
        tinted.unlockFocus()
        tinted.isTemplate = false
        return tinted
    }

    private func drawTintedIcon(_ source: NSImage, in rect: NSRect, color: NSColor) {
        source.draw(in: rect,
                    from: NSRect(origin: .zero, size: source.size),
                    operation: .sourceOver,
                    fraction: 1.0)
        color.set()
        rect.fill(using: .sourceAtop)
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

    private func startRecordingLevelMeter() {
        recordingLevelTimer?.invalidate()
        recordingLevelTimer = nil
        recordingVisualLevel = 0
        lastRecordingLevelSequence = 0
        staleRecordingLevelTicks = 0
        recordingHUDPhase = 0
        setMenuBarState(.recording)
        if settings.showRecordingWaveform {
            showRecordingHUD(level: 0)
        }
        let timer = Timer(timeInterval: 1.0 / 24.0,
                          target: self,
                          selector: #selector(recordingLevelTimerFired(_:)),
                          userInfo: nil,
                          repeats: true)
        timer.tolerance = 1.0 / 48.0
        RunLoop.main.add(timer, forMode: .common)
        recordingLevelTimer = timer
    }

    private func stopRecordingLevelMeter(resetImage: Bool = true) {
        recordingLevelTimer?.invalidate()
        recordingLevelTimer = nil
        recordingVisualLevel = 0
        lastRecordingLevelSequence = 0
        staleRecordingLevelTicks = 0
        recordingHUDPhase = 0
        hideRecordingHUD()
        if resetImage, isRecording {
            setMenuBarState(.recording)
        }
    }

    @objc private func recordingLevelTimerFired(_ timer: Timer) {
        guard isRecording else {
            stopRecordingLevelMeter()
            return
        }
        let snapshot = audio.latestRecordingLevelSnapshot()
        if snapshot.sequence == lastRecordingLevelSequence {
            staleRecordingLevelTicks += 1
        } else {
            lastRecordingLevelSequence = snapshot.sequence
            staleRecordingLevelTicks = 0
        }
        let unsuppressedLevel = staleRecordingLevelTicks > 8 ? 0 : snapshot.level
        let rawLevel = visibleRecordingLevel(rawLevel: unsuppressedLevel)
        let attack: Float = rawLevel > recordingVisualLevel ? 0.65 : 0.28
        recordingVisualLevel += (rawLevel - recordingVisualLevel) * attack
        recordingHUDPhase += 0.34 + (CGFloat(recordingVisualLevel) * 0.42)
        if settings.showRecordingWaveform {
            if recordingHUDPanel?.isVisible == true {
                updateRecordingHUD(level: recordingVisualLevel)
            } else {
                showRecordingHUD(level: recordingVisualLevel)
            }
        } else {
            hideRecordingHUD()
        }
    }

    private func showRecordingHUD(level: Float) {
        guard settings.showRecordingWaveform else { return }
        let panel = recordingHUDPanel ?? makeRecordingHUDPanel()
        recordingHUDPanel = panel
        let shouldAnimate = !panel.isVisible
        if let view = recordingHUDView {
            view.level = level
            view.phase = recordingHUDPhase
        }
        if shouldAnimate {
            animateRecordingHUDIn(panel)
        } else {
            recordingHUDAnimationToken += 1
            panel.alphaValue = 1
            panel.setFrame(recordingHUDFrame(size: RECORDING_HUD_EXPANDED_SIZE), display: true)
            panel.orderFrontRegardless()
        }
    }

    private func updateRecordingHUD(level: Float) {
        recordingHUDView?.level = level
        recordingHUDView?.phase = recordingHUDPhase
    }

    private func hideRecordingHUD() {
        recordingHUDView?.level = 0
        recordingHUDView?.phase = 0
        guard let panel = recordingHUDPanel else { return }
        recordingHUDAnimationToken += 1
        guard panel.isVisible else {
            panel.alphaValue = 1
            panel.setFrame(recordingHUDFrame(size: RECORDING_HUD_EXPANDED_SIZE), display: false)
            return
        }

        let token = recordingHUDAnimationToken
        let collapsedFrame = recordingHUDFrame(size: RECORDING_HUD_COLLAPSED_SIZE)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = RECORDING_HUD_ANIMATE_OUT_SECONDS
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(collapsedFrame, display: true)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak panel, weak self] in
            Task { @MainActor [weak panel, weak self] in
                guard let self, let panel else { return }
                guard self.recordingHUDAnimationToken == token else { return }
                panel.orderOut(nil)
                panel.alphaValue = 1
                panel.setFrame(self.recordingHUDFrame(size: RECORDING_HUD_EXPANDED_SIZE),
                               display: false)
            }
        }
    }

    private func makeRecordingHUDPanel() -> NSPanel {
        let size = RECORDING_HUD_EXPANDED_SIZE
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        let view = RecordingHUDView(frame: NSRect(origin: .zero, size: size))
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        recordingHUDView = view
        return panel
    }

    private func animateRecordingHUDIn(_ panel: NSPanel) {
        recordingHUDAnimationToken += 1
        let startFrame = recordingHUDFrame(size: RECORDING_HUD_COLLAPSED_SIZE)
        let finalFrame = recordingHUDFrame(size: RECORDING_HUD_EXPANDED_SIZE)
        panel.alphaValue = 0.7
        panel.setFrame(startFrame, display: true)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = RECORDING_HUD_ANIMATE_IN_SECONDS
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(finalFrame, display: true)
            panel.animator().alphaValue = 1
        }
    }

    private func recordingHUDFrame(size: NSSize) -> NSRect {
        let screen = screenForRecordingHUD()
        let visible = screen.visibleFrame
        return NSRect(x: visible.midX - (size.width / 2),
                      y: visible.minY + 84,
                      width: size.width,
                      height: size.height)
    }

    private func screenForRecordingHUD() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            return screen
        }
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            return screen
        }
        preconditionFailure("NSScreen.screens unexpectedly empty")
    }

    // MARK: - Recording loop

    private func handlePress() {
        guard isReady, !isRecording, !isBusy, !isTerminating else { return }
        let missing = missingPermissions()
        guard missing.isEmpty else {
            enterPermissionBlockedState(missing: missing, reason: "hotkey press")
            return
        }
        isRecording = true
        startRecordingLevelMeter()
        if settings.playFeedbackSounds {
            Sounds.playStart()
        }
        muteIfNeededForRecording()
        audio.beginRecording()
        log("press: recording")

        scheduleMaxDurationAutoRelease()
        rebuildMenu()
    }

    private func handleRelease() {
        guard isRecording, !isTerminating else { return }
        let missing = missingPermissions()
        guard missing.isEmpty else {
            enterPermissionBlockedState(missing: missing, reason: "hotkey release")
            return
        }

        isRecording = false
        stopRecordingLevelMeter()
        cancelMaxDurationAutoRelease()
        unmuteIfWeMuted()

        let samples = audio.endRecording()
        let dur = Double(samples.count) / SAMPLE_RATE
        if dur < MIN_CLIP_SECONDS {
            log("release: clip too short (\(String(format: "%.2f", dur)) s), discarding")
            setMenuBarState(.idle)
            rebuildMenu()
            return
        }
        isBusy = true
        setMenuBarState(.busy)
        rebuildMenu()
        log("release: \(String(format: "%.2f", dur)) s captured, transcribing")

        Task { @MainActor in
            do {
                let t0 = Date()
                let text = try await asr.transcribe(samples: samples)
                let dt = Date().timeIntervalSince(t0)
                if !isTerminating {
                    let missing = missingPermissions()
                    guard missing.isEmpty else {
                        enterPermissionBlockedState(missing: missing, reason: "transcription complete")
                        return
                    }
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let corrected = TranscriptCorrector.apply(to: trimmed, corrections: settings.transcriptCorrections)
                    if corrected.appliedCount > 0 {
                        log("transcript corrections applied: \(corrected.appliedCount)")
                    }
                    log("\(String(format: "%.2f", dur)) s audio → \(String(format: "%.2f", dt)) s → \(corrected.text.count) chars")
                    if !corrected.text.isEmpty {
                        let missing = missingPermissions()
                        guard missing.isEmpty else {
                            enterPermissionBlockedState(missing: missing, reason: "paste")
                            return
                        }
                        Paster.paste(pastedText(from: corrected.text, suffix: settings.pasteSuffix))
                        if settings.playFeedbackSounds {
                            Sounds.playDone()
                        }
                        addToHistory(corrected.text)
                    }
                }
            } catch {
                log("transcribe failed: \(error)")
            }
            isBusy = false
            setMenuBarState(.idle)
            rebuildMenu()
            runDeferredAudioRouteRefreshIfNeeded()
        }
    }

    private func cancelActiveRecording(reason: String) {
        guard isRecording || audio.isRunning else {
            hotkey.resetToggleState()
            return
        }

        cancelMaxDurationAutoRelease()
        _ = audio.endRecording()
        isRecording = false
        stopRecordingLevelMeter()
        hotkey.resetToggleState()
        unmuteIfWeMuted()
        setMenuBarState(.idle)
        rebuildMenu()
        log("recording canceled (\(reason))")
        runDeferredAudioRouteRefreshIfNeeded()
    }

    // Quit cancels any in-flight recording instead of releasing it:
    // release intentionally starts transcription/paste/history work,
    // while termination only needs to discard audio and restore mute.
    private func cancelRecordingForTermination() {
        cancelMaxDurationAutoRelease()
        hotkey.onPress = nil
        hotkey.onRelease = nil
        hotkey.onCancel = nil
        hotkey.isRecordingActive = nil
        hotkey.stop()

        let hadActiveRecording = isRecording || audio.isRunning
        let hadMute = didMuteThisRecording
        if hadActiveRecording {
            _ = audio.endRecording()
        }
        stopRecordingLevelMeter()
        audio.stopEngine()
        isRecording = false
        isBusy = false
        hotkey.resetToggleState()
        unmuteIfWeMuted()

        if hadActiveRecording || hadMute {
            log("terminate: active recording canceled")
        }
    }

    private func muteIfNeededForRecording() {
        guard settings.muteWhileRecording else { return }
        // Only mute if we wouldn't be stomping a user-set mute.
        if !SystemAudio.isMuted() {
            SystemAudio.mute()
            didMuteThisRecording = true
            log("output muted")
        }
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
        let next = limitedRecentTranscripts([text] + history,
                                            limit: settings.recentTranscriptLimit)
        guard next != history else { return }
        history = next
        rebuildMenu()
    }

    private func applyRecentTranscriptLimit() {
        let next = limitedRecentTranscripts(history, limit: settings.recentTranscriptLimit)
        guard next.count != history.count else { return }
        let removed = history.count - next.count
        history = next
        log("recent transcript history trimmed by \(removed) entr\(removed == 1 ? "y" : "ies")")
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

    @objc private func clearHistoryClicked(_ sender: NSMenuItem) {
        guard !history.isEmpty else { return }
        let count = history.count
        history.removeAll()
        log("history cleared (\(count) entries)")
        rebuildMenu()
    }

    @objc private func quitClicked(_ sender: NSMenuItem) {
        NSApp.terminate(self)
    }

    @objc private func cancelRecordingClicked(_ sender: NSMenuItem) {
        cancelActiveRecording(reason: "menu")
    }

    @objc private func copyDiagnosticsClicked(_ sender: NSMenuItem) {
        let text = diagnosticsText()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        log("diagnostics copied to clipboard")
    }

    // MARK: - Menu

    private func rebuildMenu() {
        statusItem.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // Status row.
        let statusTitle = menuStatusTitle()
        let status = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        status.isEnabled = false
        if let failure = startupFailure {
            status.toolTip = failure.detail
        }
        menu.addItem(status)

        menu.addItem(.separator())

        if isRecording {
            let cancel = NSMenuItem(title: "Cancel Recording",
                                    action: #selector(cancelRecordingClicked(_:)),
                                    keyEquivalent: "")
            cancel.target = self
            menu.addItem(cancel)
            menu.addItem(.separator())
        }

        if let failure = startupFailure {
            let retry = NSMenuItem(title: failure.retryTitle,
                                   action: #selector(retryStartupClicked(_:)),
                                   keyEquivalent: "")
            retry.target = self
            retry.toolTip = failure.detail
            retry.isEnabled = startupTask == nil
            menu.addItem(retry)
            menu.addItem(.separator())
        }

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
                sub.autoenablesItems = false
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

            let clear = NSMenuItem(title: "Clear Recent Transcripts",
                                   action: #selector(clearHistoryClicked(_:)),
                                   keyEquivalent: "")
            clear.target = self
            menu.addItem(clear)

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

        let diagnostics = NSMenuItem(title: "Copy Diagnostics",
                                     action: #selector(copyDiagnosticsClicked(_:)),
                                     keyEquivalent: "")
        diagnostics.target = self
        menu.addItem(diagnostics)

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

    private func menuStatusTitle() -> String {
        if isRecording {
            return "Recording..."
        }
        if isBusy {
            return "Transcribing..."
        }
        if isReady {
            let hk = hotkey.hotkey.name
            let verb = settings.triggerMode == .hold ? "Hold" : "Press"
            return "\(verb) \(hk) to dictate"
        }
        if let failure = startupFailure {
            return failure.statusTitle
        }
        if startupTask != nil {
            return startupStatusTitle
        }
        if !missingPermissions().isEmpty {
            return "Grant permissions to finish setup"
        }
        if isCoreRuntimeReady {
            return "Starting hotkey listener…"
        }
        return "Parakey is not ready"
    }

    private func diagnosticsText() -> String {
        let generated = ISO8601DateFormatter().string(from: Date())
        let bundlePath = Bundle.main.bundlePath
        let installKind: String
        if bundlePath == "/Applications/Parakey.app" {
            installKind = "Applications app"
        } else if bundlePath == "/tmp/Parakey-dev.app" {
            installKind = "signed dev app"
        } else {
            installKind = "other"
        }

        let devices = availableAudioInputDevices()
        let savedInput = settings.inputDevice.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedInput = audioInputDevice(matching: savedInput, in: devices)
        let inputLabel: String
        if savedInput.isEmpty || isDefaultAggregateAudioInputPreference(savedInput) {
            inputLabel = "System default"
        } else if let selectedInput {
            inputLabel = "\(selectedInput.name) (available)"
        } else {
            inputLabel = "Saved device unavailable"
        }

        let startupText: String
        if let failure = startupFailure {
            startupText = "\(failure.statusTitle): \(failure.detail)"
        } else if startupTask != nil {
            startupText = startupStatusTitle
        } else {
            startupText = isCoreRuntimeReady ? "Runtime ready" : "Runtime not ready"
        }

        let permissions = Permission.allCases
            .map { "- \($0.rawValue): \(Permissions.isGranted($0) ? "granted" : "missing")" }
            .joined(separator: "\n")
        let availableInputs = devices.isEmpty
            ? "None reported"
            : devices.map(\.name).joined(separator: ", ")
        let pendingUpdateText = pendingUpdate.map { "v\($0.version)" } ?? "none"

        return """
        Parakey diagnostics
        Generated: \(generated)
        App version: \(currentBundleVersion()) (\(currentBundleBuild()))
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Bundle ID: \(Bundle.main.bundleIdentifier ?? "unknown")
        Bundle path: \(bundlePath)
        Install kind: \(installKind)

        Status: \(menuStatusTitle())
        Startup: \(startupText)
        Core runtime ready: \(isCoreRuntimeReady)
        Ready for dictation: \(isReady)
        Recording active: \(isRecording)
        Transcribing: \(isBusy)

        Permissions:
        \(permissions)

        Settings:
        - Hotkey: \(hotkey.hotkey.name)
        - Trigger mode: \(TRIGGER_DISPLAY[settings.triggerMode] ?? settings.triggerMode.rawValue)
        - Paste behavior: \(PASTE_SUFFIX_DISPLAY[settings.pasteSuffix] ?? settings.pasteSuffix.rawValue)
        - Recent transcripts: \(RECENT_TRANSCRIPT_LIMIT_DISPLAY[settings.recentTranscriptLimit] ?? settings.recentTranscriptLimit.rawValue)
        - Recording waveform: \(settings.showRecordingWaveform)
        - Mute while recording: \(settings.muteWhileRecording)
        - Feedback sounds: \(settings.playFeedbackSounds)
        - Show in Dock: \(settings.showInDock)
        - Automatic update checks: \(settings.checkForUpdates)
        - Pending update: \(pendingUpdateText)

        Microphone:
        - Selected: \(inputLabel)
        - Available inputs: \(availableInputs)

        Logs: ~/Library/Logs/Parakey.log
        Privacy: transcript text and text-correction contents are not included.
        """
    }

    @objc private func retryStartupClicked(_ sender: NSMenuItem) {
        startStartup(reason: "manual retry")
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
            completeReadinessIfPossible(reason: "permission already granted")
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

        // Paste behavior submenu.
        let pasteParent = NSMenuItem(title: "Paste Behavior", action: nil, keyEquivalent: "")
        let pasteSub = NSMenu()
        pasteSub.autoenablesItems = false
        for suffix in [PasteSuffix.appendSpace, .none, .appendNewline] {
            let item = NSMenuItem(title: PASTE_SUFFIX_DISPLAY[suffix] ?? suffix.rawValue,
                                  action: #selector(selectPasteSuffix(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.state = (suffix == settings.pasteSuffix) ? .on : .off
            item.representedObject = suffix.rawValue
            pasteSub.addItem(item)
        }
        pasteParent.submenu = pasteSub
        sub.addItem(pasteParent)

        // Recent transcript history submenu.
        let recentParent = NSMenuItem(title: "Recent Transcripts", action: nil, keyEquivalent: "")
        let recentSub = NSMenu()
        recentSub.autoenablesItems = false
        for limit in RecentTranscriptLimit.allCases {
            let item = NSMenuItem(title: RECENT_TRANSCRIPT_LIMIT_DISPLAY[limit] ?? limit.rawValue,
                                  action: #selector(selectRecentTranscriptLimit(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.state = (limit == settings.recentTranscriptLimit) ? .on : .off
            item.representedObject = limit.rawValue
            recentSub.addItem(item)
        }
        recentParent.submenu = recentSub
        sub.addItem(recentParent)

        sub.addItem(buildInputDeviceItem())

        sub.addItem(buildCorrectionsItem())

        // Recording waveform toggle.
        let waveform = NSMenuItem(title: "Show recording waveform",
                                  action: #selector(toggleRecordingWaveform(_:)),
                                  keyEquivalent: "")
        waveform.target = self
        waveform.state = settings.showRecordingWaveform ? .on : .off
        sub.addItem(waveform)

        // Mute toggle.
        let mute = NSMenuItem(title: "Mute system audio while recording",
                              action: #selector(toggleMute(_:)),
                              keyEquivalent: "")
        mute.target = self
        mute.state = settings.muteWhileRecording ? .on : .off
        sub.addItem(mute)

        // Feedback sound toggle.
        let sounds = NSMenuItem(title: "Play feedback sounds",
                                action: #selector(toggleFeedbackSounds(_:)),
                                keyEquivalent: "")
        sounds.target = self
        sounds.state = settings.playFeedbackSounds ? .on : .off
        sub.addItem(sounds)

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

    private func buildInputDeviceItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false

        let devices = availableAudioInputDevices()
        let rawSavedPreference = settings.inputDevice.trimmingCharacters(in: .whitespacesAndNewlines)
        let savedPreference = isDefaultAggregateAudioInputPreference(rawSavedPreference) ? "" : rawSavedPreference
        let selectedDevice = audioInputDevice(matching: savedPreference, in: devices)
        let canSwitch = !isRecording && !isBusy && !isTerminating

        let system = NSMenuItem(title: "System default",
                                action: #selector(selectInputDevice(_:)),
                                keyEquivalent: "")
        system.target = self
        system.representedObject = ""
        system.state = (savedPreference.isEmpty || selectedDevice == nil) ? .on : .off
        system.isEnabled = canSwitch
        sub.addItem(system)

        if !savedPreference.isEmpty && selectedDevice == nil {
            let unavailable = NSMenuItem(title: "Unavailable: \(savedPreference)",
                                         action: nil,
                                         keyEquivalent: "")
            unavailable.isEnabled = false
            sub.addItem(unavailable)
        }

        if !devices.isEmpty {
            sub.addItem(.separator())
        }

        for device in devices {
            let item = NSMenuItem(title: device.name,
                                  action: #selector(selectInputDevice(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = device.uid
            item.toolTip = device.uid
            item.state = (selectedDevice?.uid == device.uid) ? .on : .off
            item.isEnabled = canSwitch
            sub.addItem(item)
        }

        parent.submenu = sub
        return parent
    }

    @objc private func selectInputDevice(_ sender: NSMenuItem) {
        guard !isRecording, !isBusy, !isTerminating,
              let preference = sender.representedObject as? String else { return }

        settings.inputDevice = preference
        let label = preference.isEmpty
            ? "system default"
            : (audioInputDevice(matching: preference)?.name ?? preference)
        log("input device selected: \(label)")
        restartAudioForInputDeviceChange()
    }

    private func restartAudioForInputDeviceChange() {
        restartAudioInput(reason: "input device change")
    }

    private func handleAudioConfigurationChange() {
        switch audioRouteChangeAction(isTerminating: isTerminating,
                                      isRestartingAudioInput: isRestartingAudioInput,
                                      isCoreRuntimeReady: isCoreRuntimeReady,
                                      isRecording: isRecording,
                                      isBusy: isBusy,
                                      hasStartupTask: startupTask != nil) {
        case .ignore:
            return
        case .rebuildMenuOnly:
            log("AudioCapture: audio configuration changed")
            rebuildMenu()
        case .deferRefresh:
            log("AudioCapture: audio configuration changed")
            pendingAudioRouteRefresh = true
            log("AudioCapture: audio route refresh deferred")
            rebuildMenu()
        case .restartNow:
            log("AudioCapture: audio configuration changed")
            rebuildMenu()
            restartAudioInput(reason: "audio configuration change")
        }
    }

    private func runDeferredAudioRouteRefreshIfNeeded() {
        guard pendingAudioRouteRefresh,
              !isRecording, !isBusy, startupTask == nil, isCoreRuntimeReady, !isTerminating else { return }
        pendingAudioRouteRefresh = false
        restartAudioInput(reason: "deferred audio configuration change")
    }

    private func restartAudioInput(reason: String) {
        guard !isRestartingAudioInput else { return }
        guard isCoreRuntimeReady else {
            rebuildMenu()
            return
        }

        pendingAudioRouteRefresh = false
        isRestartingAudioInput = true
        isReady = false
        isRecording = false
        isBusy = false
        hotkey.stop()
        setMenuBarState(.loading)
        rebuildMenu()
        audio.stopEngine()

        Task { @MainActor in
            defer { isRestartingAudioInput = false }
            do {
                didTouchAudioEngine = true
                try audio.startEngine(inputDevicePreference: settings.inputDevice)
                isCoreRuntimeReady = true
                completeReadinessIfPossible(reason: reason)
            } catch {
                isCoreRuntimeReady = false
                isReady = false
                isRecording = false
                isBusy = false
                hotkey.stop()
                recordStartupFailure(stage: .audioInput, error: error, reason: reason)
            }
        }
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
            cleanupPendingSharedCorrections(reason: "new share")

            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("Parakey-\(UUID().uuidString)", isDirectory: true)
            let url = folder.appendingPathComponent(CORRECTIONS_FILE_NAME)
            try TranscriptCorrectionsTransfer.write(settings.transcriptCorrections, to: url)
            pendingSharedCorrectionsURL = url

            let picker = NSSharingServicePicker(items: [url])
            let cleanupDelegate = CorrectionShareCleanupDelegate { [weak self] reason in
                self?.cleanupPendingSharedCorrections(reason: reason)
            }
            picker.delegate = cleanupDelegate
            correctionSharePicker = picker
            correctionShareCleanupDelegate = cleanupDelegate
            if let button = statusItem.button {
                picker.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            } else {
                cleanupPendingSharedCorrections(reason: "missing status button")
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
        correctionSyncBaselineCorrections = []
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
                correctionSyncBaselineCorrections = normalizedTranscriptCorrections(next)
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
            correctionSyncBaselineCorrections = []
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
            correctionSyncBaselineCorrections = normalizedTranscriptCorrections(corrections)
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
            var correctionsToWrite = normalizedTranscriptCorrections(settings.transcriptCorrections)
            if let knownFingerprint = correctionSyncFileFingerprint,
               let currentFingerprint = correctionSyncFingerprint(for: url),
               currentFingerprint != knownFingerprint {
                let remoteCorrections = try TranscriptCorrectionsTransfer.read(from: url)
                let merge = mergedTranscriptCorrectionsForSync(
                    base: correctionSyncBaselineCorrections,
                    local: correctionsToWrite,
                    remote: remoteCorrections
                )
                if !merge.conflictingSources.isEmpty {
                    stopCorrectionSyncAfterConflict(conflictingSources: merge.conflictingSources)
                    log("correction sync stopped after \(merge.conflictingSources.count) conflicting corrections")
                    return false
                }
                correctionsToWrite = merge.corrections
                settings.transcriptCorrections = correctionsToWrite
            }

            try TranscriptCorrectionsTransfer.write(correctionsToWrite, to: url)
            correctionSyncFileFingerprint = correctionSyncFingerprint(for: url)
            correctionSyncBaselineCorrections = correctionsToWrite
            log("correction sync wrote \(correctionsToWrite.count) corrections")
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

    private func stopCorrectionSyncAfterConflict(conflictingSources: [String]) {
        settings.transcriptCorrectionsSyncFile = ""
        correctionSyncTimer?.invalidate()
        correctionSyncTimer = nil
        correctionSyncFileFingerprint = nil
        correctionSyncBaselineCorrections = []
        rebuildMenu()

        let exampleCount = min(conflictingSources.count, 3)
        let examples = conflictingSources.prefix(exampleCount).joined(separator: "\n")
        let remaining = conflictingSources.count - exampleCount
        let remainingText = remaining > 0 ? "\n…and \(remaining) more." : ""
        showAppForModal()
        showCorrectionTransferError(
            title: "Text Correction Sync Conflict",
            message: """
            The sync file changed before this Mac wrote its latest text correction edits. Parakey kept the corrections on this Mac and stopped syncing so it would not overwrite the file.

            Reconnect the sync file after importing or resolving the conflicting correction\(conflictingSources.count == 1 ? "" : "s"):
            \(examples)\(remainingText)
            """
        )
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

    private func showCorrectionEditor(existing: TranscriptCorrection?,
                                      prefillSource: String = "") -> TranscriptCorrection? {
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
        sourceField.stringValue = existing?.source ?? prefillSource.trimmingCharacters(in: .whitespacesAndNewlines)
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

    @objc private func selectPasteSuffix(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let suffix = PasteSuffix(rawValue: raw) else { return }
        settings.pasteSuffix = suffix
        rebuildMenu()
    }

    @objc private func selectRecentTranscriptLimit(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let limit = RecentTranscriptLimit(rawValue: raw) else { return }
        settings.recentTranscriptLimit = limit
        applyRecentTranscriptLimit()
        rebuildMenu()
    }

    @objc private func toggleRecordingWaveform(_ sender: NSMenuItem) {
        settings.showRecordingWaveform.toggle()
        sender.state = settings.showRecordingWaveform ? .on : .off
        if settings.showRecordingWaveform, isRecording {
            showRecordingHUD(level: recordingVisualLevel)
        } else {
            hideRecordingHUD()
        }
    }

    @objc private func toggleMute(_ sender: NSMenuItem) {
        settings.muteWhileRecording.toggle()
        sender.state = settings.muteWhileRecording ? .on : .off
    }

    @objc private func toggleFeedbackSounds(_ sender: NSMenuItem) {
        settings.playFeedbackSounds.toggle()
        sender.state = settings.playFeedbackSounds ? .on : .off
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

            Local-only dictation. No cloud transcription, no telemetry.
            Network: model download, optional update check and install.
            Permissions: microphone audio, paste-at-cursor, push-to-talk hotkey.

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
        guard let release = pendingUpdate else { return }
        // Two paths: brew-installed users get the automated
        // upgrade-and-relaunch flow, source / non-brew installs
        // get the GitHub Releases page opened.
        if let brew = findBrew(), isBrewInstall(brewPath: brew) {
            spawnUpdateHelper(brewPath: brew, targetVersion: release.version)
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

    private func isBrewInstall(brewPath: String) -> Bool {
        guard Bundle.main.bundlePath == INSTALLED_APP_BUNDLE_PATH else { return false }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: brewPath)
        proc.arguments = ["list", "--cask", "--versions", HOMEBREW_CASK_INSTALLED_TOKEN]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            log("update: brew install check failed: \(error)")
            return false
        }
    }

    private func findBrew() -> String? {
        for path in ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    private func spawnUpdateHelper(brewPath: String, targetVersion: String) {
        // Detached shell helper that waits for THIS process to exit,
        // refreshes Homebrew, upgrades/reinstalls the cask, verifies the
        // installed bundle version, then re-opens /Applications/Parakey.app.
        // We can't run brew in-process because it replaces the bundle we're
        // executing from.
        let script = updateHelperScript(pid: getpid(),
                                        brewPath: brewPath,
                                        targetVersion: targetVersion)
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
        case "readiness":
            return runSuite("readiness", testReadiness)
        case "paste":
            return runSuite("paste", testPasteSuffixFormatting)
        case "history":
            return runSuite("history", testRecentTranscriptLimit)
        case "corrections":
            return runSuite("corrections", testTranscriptCorrections)
        case "audio-level":
            return runSuite("audio-level", testAudioLevelMetering)
        case "update":
            return runSuite("update", testUpdateHelperScript)
        case "all":
            return runSuite("all", testAll)
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

    private static func testAll() throws {
        try testHotkey()
        try testReadiness()
        try testPasteSuffixFormatting()
        try testRecentTranscriptLimit()
        try testTranscriptCorrections()
        try testAudioLevelMetering()
        try testAudioInputDeviceFiltering()
        try testSpeechModelStartupStatus()
        try testAudioRouteChangeDecision()
        try testUpdateHelperScript()
    }

    private static func testHotkey() throws {
        try testHandledHotkeySuppression()
        try testFKeyAutoRepeatSuppressesWithoutAction()
        try testRightModifierReleaseWithLeftFlagStillSet()
        try testTogglePressFlipsOnceAndReleaseIsNoOp()
        try testEscapePassesThroughWhenNotRecording()
        try testEscapeSuppressesCancelRepeatAndKeyUpWhileRecording()
    }

    private static func testReadiness() throws {
        try expect(
            readinessTransition(isReady: false,
                                isCoreRuntimeReady: false,
                                missingPermissions: []),
            equals: .rebuildMenuOnly,
            "not-ready app without core runtime should wait and rebuild only"
        )
        try expect(
            readinessTransition(isReady: false,
                                isCoreRuntimeReady: true,
                                missingPermissions: [.microphone]),
            equals: .blockForPermissions([.microphone]),
            "core-ready app with missing microphone should block"
        )
        try expect(
            readinessTransition(isReady: true,
                                isCoreRuntimeReady: true,
                                missingPermissions: [.accessibility]),
            equals: .blockForPermissions([.accessibility]),
            "ready app with missing accessibility should block"
        )
        try expect(
            readinessTransition(isReady: false,
                                isCoreRuntimeReady: true,
                                missingPermissions: []),
            equals: .startHotkeyListener,
            "core-ready app with all permissions should start hotkey"
        )
        try expect(
            readinessTransition(isReady: true,
                                isCoreRuntimeReady: true,
                                missingPermissions: []),
            equals: .rebuildMenuOnly,
            "ready app with all permissions should remain ready and rebuild only"
        )
    }

    private static func testPasteSuffixFormatting() throws {
        try expect(
            pastedText(from: "hello world", suffix: .appendSpace),
            equals: "hello world ",
            "append-space suffix should preserve the existing default"
        )
        try expect(
            pastedText(from: "hello world", suffix: .none),
            equals: "hello world",
            "no suffix should paste corrected transcript unchanged"
        )
        try expect(
            pastedText(from: "hello world", suffix: .appendNewline),
            equals: "hello world\n",
            "append-newline suffix should add a single newline"
        )
        try expect(
            pastedText(from: "hello world ", suffix: .appendSpace),
            equals: "hello world  ",
            "suffix formatting should not trim or rewrite corrected text"
        )
    }

    private static func testRecentTranscriptLimit() throws {
        let transcripts = ["newest", "second", "third", "fourth", "fifth", "sixth"]

        try expect(
            limitedRecentTranscripts(transcripts, limit: .off),
            equals: [],
            "off should keep no recent transcripts"
        )
        try expect(
            limitedRecentTranscripts(transcripts, limit: .last1),
            equals: ["newest"],
            "last-one history should keep only the newest transcript"
        )
        try expect(
            limitedRecentTranscripts(transcripts, limit: .last5),
            equals: ["newest", "second", "third", "fourth", "fifth"],
            "last-five history should preserve the current default cap"
        )
        try expect(
            parseRecentTranscriptLimit(storedValue: NSNumber(value: 1)),
            equals: .last1,
            "numeric defaults writes should be accepted for last-one history"
        )
    }

    private static func testAudioLevelMetering() throws {
        try expect(
            normalizedAudioLevel(from: Array(repeating: 0, count: 128)),
            equals: 0,
            "silence should map to zero recording level"
        )

        let lowVoice = normalizedAudioLevel(from: Array(repeating: 0.004, count: 128))
        let quiet = normalizedAudioLevel(from: Array(repeating: 0.01, count: 128))
        let normal = normalizedAudioLevel(from: Array(repeating: 0.12, count: 128))
        let loud = normalizedAudioLevel(from: Array(repeating: 4.0, count: 128))

        guard lowVoice > 0 else {
            throw SelfTestFailure.failed("low close-mic voice should rise above the visual gate")
        }
        guard quiet > 0 else {
            throw SelfTestFailure.failed("quiet speech-like input should rise above zero")
        }
        guard normal > quiet else {
            throw SelfTestFailure.failed("higher RMS should produce a higher visual level")
        }
        try expect(
            loud,
            equals: 1,
            "out-of-range samples should clamp to maximum visual level"
        )

        try expect(
            normalizedAudioLevel(from: [.nan, .infinity, -.infinity]),
            equals: 0,
            "non-finite samples should not produce a visible level"
        )
        try expect(
            visibleRecordingLevel(rawLevel: .nan),
            equals: 0,
            "visible recording level should ignore non-finite input"
        )
        try expect(
            visibleRecordingLevel(rawLevel: 0.8),
            equals: 0.8,
            "visible recording level should pass through normal input immediately"
        )
        try expect(
            visibleRecordingLevel(rawLevel: 1.2),
            equals: 1,
            "visible recording level should clamp high input"
        )
    }

    private static func testTranscriptCorrections() throws {
        let normalized = normalizedTranscriptCorrections([
            TranscriptCorrection(source: "  Yeti   Nano  ", replacement: "  Blue mic  "),
            TranscriptCorrection(source: "yeti nano", replacement: "USB mic"),
            TranscriptCorrection(source: "", replacement: "ignored"),
            TranscriptCorrection(source: "empty replacement", replacement: "   ")
        ])
        try expect(
            normalized,
            equals: [TranscriptCorrection(source: "yeti nano", replacement: "USB mic")],
            "normalization should trim, drop incomplete entries, collapse duplicate sources, and keep the latest replacement"
        )

        let applied = TranscriptCorrector.apply(
            to: "parakeet tdt and parakeetish and PARakeet",
            corrections: [
                TranscriptCorrection(source: "parakeet", replacement: "Parakey"),
                TranscriptCorrection(source: "parakeet tdt", replacement: "Parakeet TDT")
            ]
        )
        try expect(
            applied.text,
            equals: "Parakeet TDT and parakeetish and Parakey",
            "corrections should prefer longer phrases and respect word boundaries"
        )
        try expect(
            applied.appliedCount,
            equals: 2,
            "correction count should track applied non-overlapping replacements"
        )

        let transferred = try TranscriptCorrectionsTransfer.decode(
            TranscriptCorrectionsTransfer.encode([
                TranscriptCorrection(source: "  Right Option  ", replacement: "R-Option")
            ])
        )
        try expect(
            transferred,
            equals: [TranscriptCorrection(source: "Right Option", replacement: "R-Option")],
            "document transfer should round-trip normalized corrections"
        )

        let legacyData = try JSONEncoder().encode([
            TranscriptCorrection(source: "  old phrase  ", replacement: "new phrase")
        ])
        try expect(
            try TranscriptCorrectionsTransfer.decode(legacyData),
            equals: [TranscriptCorrection(source: "old phrase", replacement: "new phrase")],
            "legacy bare-array correction files should remain importable"
        )

        let remoteOnlyChange = mergedTranscriptCorrectionsForSync(
            base: [TranscriptCorrection(source: "old phrase", replacement: "old")],
            local: [TranscriptCorrection(source: "old phrase", replacement: "old")],
            remote: [TranscriptCorrection(source: "old phrase", replacement: "remote")]
        )
        try expect(
            remoteOnlyChange,
            equals: TranscriptCorrectionSyncMergeResult(
                corrections: [TranscriptCorrection(source: "old phrase", replacement: "remote")],
                conflictingSources: []
            ),
            "sync merge should accept remote changes when local has not changed"
        )

        let nonConflictingMerge = mergedTranscriptCorrectionsForSync(
            base: [
                TranscriptCorrection(source: "shared", replacement: "old"),
                TranscriptCorrection(source: "removed locally", replacement: "old")
            ],
            local: [TranscriptCorrection(source: "shared", replacement: "local")],
            remote: [
                TranscriptCorrection(source: "shared", replacement: "old"),
                TranscriptCorrection(source: "removed locally", replacement: "old"),
                TranscriptCorrection(source: "remote only", replacement: "remote")
            ]
        )
        try expect(
            nonConflictingMerge,
            equals: TranscriptCorrectionSyncMergeResult(
                corrections: [
                    TranscriptCorrection(source: "shared", replacement: "local"),
                    TranscriptCorrection(source: "remote only", replacement: "remote")
                ],
                conflictingSources: []
            ),
            "sync merge should combine non-conflicting local edits, local deletes, and remote additions"
        )

        let conflictingMerge = mergedTranscriptCorrectionsForSync(
            base: [TranscriptCorrection(source: "same source", replacement: "old")],
            local: [TranscriptCorrection(source: "same source", replacement: "local")],
            remote: [TranscriptCorrection(source: "same source", replacement: "remote")]
        )
        try expect(
            conflictingMerge,
            equals: TranscriptCorrectionSyncMergeResult(corrections: [],
                                                        conflictingSources: ["same source"]),
            "sync merge should report same-source edits that changed differently on both sides"
        )
    }

    private static func testAudioInputDeviceFiltering() throws {
        let pseudo = AudioInputDevice(id: 1,
                                      uid: "CADefaultDeviceAggregate-42159-0",
                                      name: "CADefaultDeviceAggregate-42159-0")
        let real = AudioInputDevice(id: 2,
                                    uid: "real-yeti-nano",
                                    name: "Yeti Nano")

        try expect(
            isDefaultAggregateAudioInputDevice(pseudo),
            equals: true,
            "CoreAudio default aggregate devices should be recognized"
        )
        try expect(
            isDefaultAggregateAudioInputDevice(real),
            equals: false,
            "named microphones should remain selectable"
        )
        try expect(
            audioInputDevice(matching: pseudo.uid, in: [pseudo, real])?.uid,
            equals: nil,
            "CoreAudio default aggregate preferences should fall back to system default"
        )
        try expect(
            audioInputDevice(matching: "Yeti Nano", in: [real])?.uid,
            equals: "real-yeti-nano",
            "named microphone preferences should still resolve by display name"
        )
    }

    private static func testSpeechModelStartupStatus() throws {
        try expect(
            speechModelStartupStatusTitle(.init(fractionCompleted: 0,
                                                phase: .listing)),
            equals: "Checking speech model files…",
            "listing phase should be visible during first-launch model setup"
        )
        try expect(
            speechModelStartupStatusTitle(.init(fractionCompleted: 0.25,
                                                phase: .downloading(completedFiles: 2, totalFiles: 4))),
            equals: "Downloading speech model… 50% (2/4)",
            "download phase should show quantized progress"
        )
        try expect(
            speechModelStartupStatusTitle(.init(fractionCompleted: 0.5,
                                                phase: .downloading(completedFiles: 0, totalFiles: 0))),
            equals: "Loading cached speech model…",
            "cached model load should not pretend to download files"
        )
        try expect(
            speechModelStartupStatusTitle(.init(fractionCompleted: 1,
                                                phase: .compiling(modelName: "Encoder.mlmodelc"))),
            equals: "Preparing speech model…",
            "compile phase should be visible without exposing model internals"
        )
    }

    private static func testUpdateHelperScript() throws {
        try expect(
            shellSingleQuoted("a'b"),
            equals: "'a'\"'\"'b'",
            "shell quoting should preserve embedded single quotes"
        )

        let script = updateHelperScript(pid: 123,
                                        brewPath: "/opt/homebrew/bin/brew",
                                        targetVersion: "9.8.7",
                                        appPath: "/Applications/Parakey.app",
                                        releasesPageURL: "https://example.test/releases",
                                        logPath: "/tmp/parakey-update.log")
        for fragment in [
            "TARGET_VERSION='9.8.7'",
            "PARAKEY_PID=123",
            "CASK_TOKEN='rcourtman/parakey/parakey'",
            "PlistBuddy -c \"Print :CFBundleShortVersionString\"",
            "version_at_least \"$installed\" \"$TARGET_VERSION\"",
            "run_brew update",
            "run_brew upgrade --cask \"$CASK_TOKEN\"",
            "run_brew reinstall --cask \"$CASK_TOKEN\"",
            "installed_target_version",
            "/usr/bin/open \"$APP_PATH\""
        ] {
            guard script.contains(fragment) else {
                throw SelfTestFailure.failed("update helper script missing fragment: \(fragment)")
            }
        }

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("parakey-update-self-test-\(UUID().uuidString).sh")
        try script.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-n", tmp.path]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw SelfTestFailure.failed("update helper script should pass bash -n")
        }
    }

    private static func testAudioRouteChangeDecision() throws {
        try expect(
            audioRouteChangeAction(isTerminating: true,
                                   isRestartingAudioInput: false,
                                   isCoreRuntimeReady: true,
                                   isRecording: false,
                                   isBusy: false,
                                   hasStartupTask: false),
            equals: .ignore,
            "route changes during termination should be ignored"
        )
        try expect(
            audioRouteChangeAction(isTerminating: false,
                                   isRestartingAudioInput: false,
                                   isCoreRuntimeReady: false,
                                   isRecording: false,
                                   isBusy: false,
                                   hasStartupTask: false),
            equals: .rebuildMenuOnly,
            "route changes before runtime readiness should only refresh the menu"
        )
        try expect(
            audioRouteChangeAction(isTerminating: false,
                                   isRestartingAudioInput: false,
                                   isCoreRuntimeReady: true,
                                   isRecording: true,
                                   isBusy: false,
                                   hasStartupTask: false),
            equals: .deferRefresh,
            "route changes during recording should defer the restart"
        )
        try expect(
            audioRouteChangeAction(isTerminating: false,
                                   isRestartingAudioInput: false,
                                   isCoreRuntimeReady: true,
                                   isRecording: false,
                                   isBusy: false,
                                   hasStartupTask: false),
            equals: .restartNow,
            "idle ready route changes should restart audio immediately"
        )
    }

    private static func testHandledHotkeySuppression() throws {
        var state = HotkeyTransitionState()
        let f5 = hotkeyChoice(forKeycode: 96)

        try expect(
            state.transition(for: event(.keyDown, keycode: f5.keycode), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "F-key keyDown should suppress and press"
        )
        try expect(
            state.transition(for: event(.keyDown, keycode: 97), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: .pass,
            "non-hotkey keyDown should pass through"
        )
        try expect(
            state.transition(for: event(.keyUp, keycode: f5.keycode), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.release]),
            "F-key keyUp should suppress and release"
        )
    }

    private static func testFKeyAutoRepeatSuppressesWithoutAction() throws {
        var state = HotkeyTransitionState()
        let f5 = hotkeyChoice(forKeycode: 96)

        try expect(
            state.transition(for: event(.keyDown, keycode: f5.keycode), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "initial F-key keyDown should press"
        )
        try expect(
            state.transition(for: event(.keyDown, keycode: f5.keycode, isAutoRepeat: true), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: .suppressOnly,
            "F-key autorepeat keyDown should suppress without action"
        )
    }

    private static func testRightModifierReleaseWithLeftFlagStillSet() throws {
        var state = HotkeyTransitionState()
        let rightOption = hotkeyChoice(forKeycode: 61)
        let alternate = CGEventFlags.maskAlternate.rawValue

        try expect(
            state.transition(for: event(.flagsChanged, keycode: rightOption.keycode, flags: alternate), hotkey: rightOption, triggerMode: .hold, isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "right modifier flagsChanged should press"
        )
        try expect(
            state.transition(for: event(.flagsChanged, keycode: rightOption.keycode, flags: alternate), hotkey: rightOption, triggerMode: .hold, isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.release]),
            "right modifier release should be recognized while left-side flag remains set"
        )
    }

    private static func testTogglePressFlipsOnceAndReleaseIsNoOp() throws {
        var state = HotkeyTransitionState()
        let f5 = hotkeyChoice(forKeycode: 96)

        try expect(
            state.transition(for: event(.keyDown, keycode: f5.keycode), hotkey: f5, triggerMode: .toggle, isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "first toggle press should start"
        )
        try expect(
            state.transition(for: event(.keyUp, keycode: f5.keycode), hotkey: f5, triggerMode: .toggle, isRecording: false),
            equals: .suppressOnly,
            "toggle release should be a no-op"
        )
        try expect(
            state.transition(for: event(.keyDown, keycode: f5.keycode), hotkey: f5, triggerMode: .toggle, isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.release]),
            "second toggle press should stop"
        )
    }

    private static func testEscapePassesThroughWhenNotRecording() throws {
        var state = HotkeyTransitionState()
        let f5 = hotkeyChoice(forKeycode: 96)

        try expect(
            state.transition(for: event(.keyDown, keycode: ESCAPE_KEYCODE), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: .pass,
            "Escape keyDown should pass through when not recording"
        )
        try expect(
            state.transition(for: event(.keyDown, keycode: ESCAPE_KEYCODE, isAutoRepeat: true), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: .pass,
            "Escape autorepeat should pass through when not recording"
        )
        try expect(
            state.transition(for: event(.keyUp, keycode: ESCAPE_KEYCODE), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: .pass,
            "Escape keyUp should pass through when not recording"
        )
    }

    private static func testEscapeSuppressesCancelRepeatAndKeyUpWhileRecording() throws {
        var state = HotkeyTransitionState()
        let f5 = hotkeyChoice(forKeycode: 96)

        try expect(
            state.transition(for: event(.keyDown, keycode: ESCAPE_KEYCODE), hotkey: f5, triggerMode: .hold, isRecording: true),
            equals: HotkeyTransitionResult(suppress: true, actions: [.cancel]),
            "Escape keyDown should suppress and cancel while recording"
        )
        try expect(
            state.transition(for: event(.keyDown, keycode: ESCAPE_KEYCODE, isAutoRepeat: true), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: .suppressOnly,
            "Escape autorepeat from a canceled press should stay suppressed"
        )
        try expect(
            state.transition(for: event(.keyUp, keycode: ESCAPE_KEYCODE), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: .suppressOnly,
            "paired Escape keyUp should stay suppressed after cancel"
        )
        try expect(
            state.transition(for: event(.keyUp, keycode: ESCAPE_KEYCODE), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: .pass,
            "later Escape keyUp should pass through once the canceled press is complete"
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

    private static func expect<T: Equatable>(
        _ actual: T,
        equals expected: T,
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
