// Parakey — push-to-talk dictation for macOS.
//
// This is the Swift successor to parakey.py. Behavioral spec lives
// in ../parakey.py; this file translates the runtime parts to native
// AppKit + AVFoundation + Speech APIs + FluidAudio on the ANE. Read
// the Python version's docstrings if anything here looks
// non-obvious — every UX decision was made there first.
//
// Scope of this MVP: menu bar icon, Right Option hotkey, record →
// transcribe → paste at cursor, three-permission menu. Settings UI,
// about dialog, history, update mechanism, and skip-version come in
// later iterations.

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

let LABEL_IDLE = "🎙"
let LABEL_REC = "🔴"
let LABEL_BUSY = "✏️"
let LABEL_LOAD = "⏳"
let LABEL_ERROR = "❌"

// MARK: - Logger
//
// All output goes to stderr (line-buffered, so we don't lose lines
// across an abrupt exit) and to ~/Library/Logs/Parakey.log, matching
// the Python app's path so the file is interchangeable between the
// two implementations.

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

    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?

    func start() {
        // Watch flagsChanged for modifier keys (Right Option lives
        // here) plus keyDown/keyUp in case we ever support non-modifier
        // hotkeys.
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
                              | (1 << CGEventType.keyUp.rawValue)
                              | (1 << CGEventType.flagsChanged.rawValue)

        // Use Unmanaged to box `self` for the C callback. We keep
        // the listener alive for the app's lifetime so the unbalanced
        // retain is intentional.
        let opaqueSelf = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { proxy, type, event, userInfo in
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
        log("HotkeyListener: tap active (watching Right Option)")
    }

    private func handle(type: CGEventType, event: CGEvent) {
        guard type == .flagsChanged else { return }
        // The CGEventField for keycode is the same for flagsChanged
        // events — it tells us which modifier just changed state.
        let keycode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        guard keycode == DEFAULT_HOTKEY_KEYCODE else { return }

        let flags = event.flags
        let isPressed = flags.contains(.maskAlternate)
        let wasPressed = lastFlags.contains(.maskAlternate)
        lastFlags = flags

        if isPressed && !wasPressed { onPress?() }
        if !isPressed && wasPressed { onRelease?() }
    }
}

// MARK: - Audio capture
//
// AVAudioEngine tap on the input node, downmix to mono / 16 kHz /
// Float32 if needed, append to a buffer while recording.

@MainActor
final class AudioCapture {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private(set) var isRunning = false

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

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.handleTap(buffer: buffer, target: targetFormat)
        }

        try engine.start()
        log("AudioCapture: engine started")
    }

    func beginRecording() {
        samples.removeAll(keepingCapacity: true)
        isRunning = true
    }

    /// Stops the recording state and returns the captured samples.
    func endRecording() -> [Float] {
        isRunning = false
        let captured = samples
        samples.removeAll(keepingCapacity: true)
        return captured
    }

    private func handleTap(buffer: AVAudioPCMBuffer, target: AVAudioFormat) {
        guard isRunning else { return }
        guard let converter else { return }

        // Compute output capacity for one-shot conversion.
        let ratio = target.sampleRate / buffer.format.sampleRate
        let outCap = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCap) else { return }

        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if fed { outStatus.pointee = .endOfStream; return nil }
            fed = true; outStatus.pointee = .haveData; return buffer
        }
        if status == .error { log("AudioCapture: convert error: \(error?.localizedDescription ?? "?")"); return }
        guard let ch = out.floatChannelData?[0] else { return }
        let arr = Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
        // Hop off the audio thread for the append; samples is owned
        // by the main actor.
        Task { @MainActor in
            self.samples.append(contentsOf: arr)
        }
    }
}

// MARK: - Transcription worker
//
// Owns the FluidAudio AsrManager. ASR work runs in the actor's
// isolated context, so the model load + every `transcribe` call
// happens on a single Swift concurrency executor — analogous to
// inference_worker.py's dedicated thread pattern.

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
// Write to general pasteboard, post Cmd+V. Same pattern as the
// Python version's paste_text() — we don't preserve / restore the
// user's previous clipboard contents (the Python version doesn't
// either; deliberate to match).

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

// MARK: - App
//
// Single class that owns the lifecycle. Mirrors the Python Parakey
// class but stripped to the MVP path: hotkey → record → transcribe
// → paste, plus a three-permission menu.

@MainActor
final class ParakeyApp: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let audio = AudioCapture()
    private let hotkey = HotkeyListener()
    private let asr = TranscriptionWorker()

    private var isRecording = false
    private var isBusy = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only — no dock icon.
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = LABEL_LOAD
        statusItem.menu = buildMenu(state: .loading)

        // Order matters: load ASR FIRST. Starting AVAudioEngine
        // before CoreML compiles the model serialises ANE access
        // somehow and stalls model load indefinitely. The Python
        // app has its own version of this (parakeet_mlx must be
        // warmed before the audio stream opens); here it's a fresh
        // app's CoreML compile being blocked by an active audio
        // engine. Audio + hotkey come up after ASR is ready.
        Task { @MainActor in
            do {
                try await asr.load()
                statusItem.button?.title = LABEL_IDLE

                // Hotkey first — registers Parakey in the Input
                // Monitoring TCC list even if the user hasn't
                // granted yet. macOS shows the prompt the first
                // time the tap actually receives an event.
                hotkey.onPress = { [weak self] in self?.handlePress() }
                hotkey.onRelease = { [weak self] in self?.handleRelease() }
                hotkey.start()

                // Then audio. mic permission prompt fires the first
                // time we read from the input node.
                try audio.startEngine()

                refreshMenu()
            } catch {
                log("init failed: \(error)")
                statusItem.button?.title = LABEL_ERROR
            }
        }
    }

    private func handlePress() {
        guard !isRecording && !isBusy else { return }
        isRecording = true
        audio.beginRecording()
        statusItem.button?.title = LABEL_REC
        log("press: recording")
    }

    private func handleRelease() {
        guard isRecording else { return }
        isRecording = false
        let samples = audio.endRecording()
        let dur = Double(samples.count) / SAMPLE_RATE
        if dur < MIN_CLIP_SECONDS {
            log("release: clip too short (\(String(format: "%.2f", dur)) s), discarding")
            statusItem.button?.title = LABEL_IDLE
            return
        }
        isBusy = true
        statusItem.button?.title = LABEL_BUSY
        log("release: \(String(format: "%.2f", dur)) s captured, transcribing…")

        Task { @MainActor in
            do {
                let t0 = Date()
                let text = try await asr.transcribe(samples: samples)
                let dt = Date().timeIntervalSince(t0)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                log("\(String(format: "%.2f", dur)) s audio → \(String(format: "%.2f", dt)) s → \(trimmed.count) chars")
                if !trimmed.isEmpty {
                    Paster.paste(trimmed + " ")
                }
            } catch {
                log("transcribe failed: \(error)")
            }
            isBusy = false
            statusItem.button?.title = LABEL_IDLE
        }
    }

    // MARK: Menu

    private enum State { case loading, ready }

    private func refreshMenu() {
        statusItem.menu = buildMenu(state: .ready)
    }

    private func buildMenu(state: State) -> NSMenu {
        let menu = NSMenu()

        switch state {
        case .loading:
            let m = NSMenuItem(title: "Loading speech model…", action: nil, keyEquivalent: "")
            m.isEnabled = false
            menu.addItem(m)
        case .ready:
            let m = NSMenuItem(title: "Hold Right Option to dictate", action: nil, keyEquivalent: "")
            m.isEnabled = false
            menu.addItem(m)
        }

        menu.addItem(.separator())

        // Permission rows — visible only when something is missing.
        for p in Permission.allCases {
            if !Permissions.isGranted(p) {
                let item = NSMenuItem(
                    title: "⚠ Grant \(p.rawValue) permission…",
                    action: #selector(grantPermissionClicked(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = p.rawValue
                menu.addItem(item)
            }
        }
        // Trailing separator only if any perm row was added.
        if menu.items.last?.isSeparatorItem == false,
           Permission.allCases.contains(where: { !Permissions.isGranted($0) }) {
            menu.addItem(.separator())
        }

        menu.addItem(NSMenuItem(title: "Quit Parakey",
                                action: #selector(NSApp.terminate(_:)),
                                keyEquivalent: "q"))
        return menu
    }

    @objc private func grantPermissionClicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let p = Permission(rawValue: raw) else { return }
        log("perm click: \(p.rawValue)")
        Permissions.request(p)
        // Permissions don't update synchronously; refresh the menu
        // after a short delay so the row disappears if granted.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.refreshMenu()
        }
    }
}

// MARK: - Entry point

let app = NSApplication.shared
let delegate = ParakeyApp()
app.delegate = delegate
app.run()
