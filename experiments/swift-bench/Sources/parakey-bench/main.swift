// parakey-bench — head-to-head benchmark of Apple SpeechAnalyzer
// (DictationTranscriber on the Apple Neural Engine, built into
// macOS 26 Tahoe) vs FluidAudio model variants via CoreML on the
// ANE on the same audio. Output is intentionally comparable to
// the sibling `./bench-py.py` (Python parakey-mlx, GPU/Metal), so
// all three backends can be cross-referenced in one table.
//
// Usage:
//   parakey-bench --file path/to/audio.wav [--trials 5] [--backend apple|v3|unified|nemotron-en|110m|fluid|both] [--redact-transcripts]
//
// Audio must be 16 kHz mono Float32 (or convertible to that —
// AVAudioFile + AVAudioPCMBuffer handles the conversion).

import Foundation
import AVFoundation
import Speech
import FluidAudio

let UNIFIED_MODEL_TRAILING_SILENCE_MS = 250
let BENCH_SAMPLE_RATE: Double = 16_000

// MARK: - CLI

struct CLIArgs {
    var file: URL
    var trials: Int = 5
    // "apple" | "v3" | "unified" | "nemotron-en" | "110m" | "fluid"
    // (= v3 + candidates + 110m) | "both" (= apple + fluid).
    // Defaults to "v3": it's the production model. Unified is an
    // English-only candidate backend; 110m remains broken upstream.
    var backend: String = "v3"
    // Ground-truth transcript for WER. If nil, falls back to a sibling
    // "<file-stem>.txt" (written by generate-test-audio.sh); if neither
    // exists, WER is skipped.
    var ref: String? = nil
    // Keep transcript/reference contents out of stdout while still
    // computing latency, memory, and WER. Used for local real-dictation
    // regression reports that should remain privacy-safe by default.
    var redactTranscripts = false
    // Candidate-model default used for final-word retention studies. Set to
    // 0 to measure the raw model, or sweep values when tuning a future model.
    var unifiedTrailingSilenceMs = UNIFIED_MODEL_TRAILING_SILENCE_MS
}

func parseArgs() -> CLIArgs {
    var iter = CommandLine.arguments.dropFirst().makeIterator()
    var file: URL? = nil
    var trials: Int = 5
    var backend: String = "v3"
    var ref: String? = nil
    var redactTranscripts = false
    var unifiedTrailingSilenceMs = UNIFIED_MODEL_TRAILING_SILENCE_MS
    while let arg = iter.next() {
        switch arg {
        case "--file":
            if let v = iter.next() { file = URL(fileURLWithPath: v) }
        case "--trials":
            if let v = iter.next(), let n = Int(v) { trials = n }
        case "--backend":
            if let v = iter.next() { backend = v }
        case "--ref":
            if let v = iter.next() { ref = v }
        case "--redact-transcripts":
            redactTranscripts = true
        case "--unified-trailing-silence-ms":
            guard let v = iter.next(), let n = Int(v), n >= 0 else {
                FileHandle.standardError.write(Data("--unified-trailing-silence-ms requires a non-negative integer\n".utf8))
                exit(2)
            }
            unifiedTrailingSilenceMs = n
        case "-h", "--help":
            print("""
            usage: parakey-bench --file <wav> [--trials N] [--backend apple|v3|unified|nemotron-en|110m|fluid|both] [--ref "text"] [--redact-transcripts]

              --backend  v3    FluidAudio Parakeet TDT v3 — production model (default)
                         unified
                              FluidAudio Parakeet Unified 0.6B offline batch
                         nemotron-en
                              FluidAudio Nemotron Speech Streaming English 0.6B, 1120 ms tier
                         110m  FluidAudio Parakeet TDT-CTC 110M (smaller English model;
                               currently fails to load — broken upstream)
                         fluid v3 + candidate FluidAudio backends + 110m head-to-head
                         apple Apple SpeechAnalyzer (macOS 26+)
                         both  apple + fluid
              --ref      reference transcript for WER; defaults to <file>.txt if present
              --redact-transcripts
                         omit reference and hypothesis text from output while still
                         reporting WER; useful for private real-dictation runs
              --unified-trailing-silence-ms <n>
                         append n ms of silence before Unified transcription
                         (default: \(UNIFIED_MODEL_TRAILING_SILENCE_MS), matching Parakey)

            For a clean per-model memory number, run one model per process
            (--backend v3, then --backend 110m) — footprint is cumulative
            when several backends run in the same process.
            """)
            exit(0)
        default:
            FileHandle.standardError.write(Data("unknown arg: \(arg)\n".utf8))
            exit(2)
        }
    }
    guard let file else {
        FileHandle.standardError.write(Data("--file is required\n".utf8))
        exit(2)
    }
    return CLIArgs(file: file,
                   trials: trials,
                   backend: backend,
                   ref: ref,
                   redactTranscripts: redactTranscripts,
                   unifiedTrailingSilenceMs: unifiedTrailingSilenceMs)
}

// MARK: - Audio loading
//
// Both backends want 16 kHz mono Float32. AVAudioFile gives us
// whatever the file actually is; we convert with AVAudioConverter
// rather than trusting the caller to have pre-resampled.

enum AudioLoadError: Error { case openFailed, convertFailed, emptyBuffer }

private final class SingleBufferConverterInputProvider: @unchecked Sendable {
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
            outStatus.pointee = .endOfStream
            return nil
        }

        didProvideBuffer = true
        outStatus.pointee = .haveData
        return buffer
    }
}

func load16kMono(url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let srcFormat = file.processingFormat

    // Target: 16 kHz mono Float32.
    guard let dstFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    ) else { throw AudioLoadError.openFailed }

    // Read the whole file into a buffer at the file's native rate.
    guard let srcBuf = AVAudioPCMBuffer(
        pcmFormat: srcFormat,
        frameCapacity: AVAudioFrameCount(file.length)
    ) else { throw AudioLoadError.openFailed }
    try file.read(into: srcBuf)

    // Convert in one shot. Worst-case output length = src * (dst/src).
    let ratio = dstFormat.sampleRate / srcFormat.sampleRate
    let dstCap = AVAudioFrameCount(Double(srcBuf.frameLength) * ratio + 1024)
    guard let dstBuf = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: dstCap),
          let converter = AVAudioConverter(from: srcFormat, to: dstFormat)
    else { throw AudioLoadError.convertFailed }

    var error: NSError?
    let inputProvider = SingleBufferConverterInputProvider(buffer: srcBuf)
    let status = converter.convert(to: dstBuf, error: &error) { _, outStatus in
        inputProvider.provide(outStatus: outStatus)
    }
    if status == .error { throw error ?? AudioLoadError.convertFailed }

    guard let chPtr = dstBuf.floatChannelData?[0] else { throw AudioLoadError.emptyBuffer }
    return Array(UnsafeBufferPointer(start: chPtr, count: Int(dstBuf.frameLength)))
}

// MARK: - Backends

protocol ASRBackend {
    var name: String { get }
    /// Run one transcription. Returns the transcript and elapsed seconds
    /// for inference only (model load + warmup happen in `prepare()`).
    func run(samples: [Float]) async throws -> (text: String, elapsed: Double)
    /// Load models, do whatever warmup is fair to exclude from the measured path.
    func prepare(warmupSamples: [Float]) async throws
}

// ----- Apple SpeechAnalyzer / DictationTranscriber ---------------------

@available(macOS 26, *)
final class AppleBackend: ASRBackend {
    let name = "apple-SpeechAnalyzer"
    private var localeInstalled = false

    func prepare(warmupSamples: [Float]) async throws {
        // Apple's per-locale dictation model isn't preinstalled. If the
        // bundle hasn't been fetched for this locale yet, AssetInventory
        // hands us a request that wraps an actual download. Skipping
        // this step makes `transcriber.results` emit zero events and the
        // program 'succeeds' silently with an empty transcript.
        let template = makeTranscriber()
        let installed = await DictationTranscriber.installedLocales
        let target = Locale(identifier: "en-US")
        let hasIt = installed.contains { $0.identifier(.bcp47) == target.identifier(.bcp47) }
        if !hasIt {
            log("  DictationTranscriber en-US not installed — requesting download…")
            if let request = try await AssetInventory.assetInstallationRequest(
                supporting: [template]
            ) {
                try await request.downloadAndInstall()
                log("  download + install complete")
            } else {
                log("  no install request returned — assuming locale is available")
            }
        }
        localeInstalled = true

        // First inference loads the model into the ANE; subsequent ones
        // are warm. Run a warmup so measured runs reflect steady-state.
        _ = try await transcribe(samples: warmupSamples)
    }

    func run(samples: [Float]) async throws -> (text: String, elapsed: Double) {
        let t0 = Date()
        let text = try await transcribe(samples: samples)
        return (text, Date().timeIntervalSince(t0))
    }

    private func makeTranscriber() -> DictationTranscriber {
        // DictationTranscriber is the dictation-focused module (auto-
        // punctuation, sentence structure), which matches Parakey's
        // workload. SpeechTranscriber is the raw-words sibling for
        // command-recognition use cases — wrong fit here.
        DictationTranscriber(
            locale: Locale(identifier: "en-US"),
            contentHints: [.shortForm],
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )
    }

    private func transcribe(samples: [Float]) async throws -> String {
        // `SpeechAnalyzer.finalizeAndFinishThroughEndOfInput()` puts the
        // analyzer (and the modules attached to it) into a terminal
        // state — you cannot push more audio afterwards. For push-to-
        // talk style benchmarks (and Parakey's real-world usage) the
        // canonical pattern is therefore a fresh analyzer+transcriber
        // per utterance, mirroring `TdtDecoderState()` on the fluid
        // side.
        let transcriber = makeTranscriber()
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Drain `transcriber.results` in a child task that starts BEFORE
        // `analyzer.start(...)`. Reading results sequentially after
        // finalize loses events on at least DictationTranscriber: the
        // module appears to discard pending results once the analyzer
        // hits its terminal state, so by the time we'd loop the stream
        // is empty. swift-scribe uses the same parallel pattern.
        let collected = Task<String, Error> {
            // SpeechAnalyzer/DictationTranscriber semantics:
            //   - `isFinal == true`  → committed text, append to finalized
            //   - `isFinal == false` → volatile preview, replace
            // For a single-shot push-to-talk utterance DictationTranscriber
            // tends to emit the entire transcript in one volatile event and
            // never marks it final, so the user-visible result is
            // `finalized + volatile`, not just `finalized`.
            var finalized = ""
            var volatileText = ""
            for try await result in transcriber.results {
                let chunk = String(result.text.characters)
                if result.isFinal {
                    finalized += chunk
                    volatileText = ""
                } else {
                    volatileText = chunk
                }
            }
            return finalized + volatileText
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: stream)

        let buffer = makePCMBuffer(samples: samples)
        continuation.yield(AnalyzerInput(buffer: buffer))
        continuation.finish()

        try await analyzer.finalizeAndFinishThroughEndOfInput()

        return try await collected.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makePCMBuffer(samples: [Float]) -> AVAudioPCMBuffer {
        // Speech.framework's DictationTranscriber rejects Float32 audio
        // with "Failed precondition: Audio sample data must be 16-bit
        // signed integers" — convert in [-1, 1] floats to clamped Int16
        // here so the analyzer gets the format it actually wants.
        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )!
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buf.frameLength = AVAudioFrameCount(samples.count)
        let dst = buf.int16ChannelData!.pointee
        for i in 0..<samples.count {
            let clamped = max(-1.0, min(1.0, samples[i]))
            dst[i] = Int16(clamped * 32767.0)
        }
        return buf
    }
}

// ----- FluidAudio (Parakeet → CoreML → ANE) -----------------------------
//
// One class, two model versions: TDT v3 (0.6B, 25-language default) and
// TDT-CTC 110M (smaller English-focused model with a fused
// preprocessor+encoder). Both load through the same `AsrModels` /
// `AsrManager` API and both decode through `TdtDecoderState` — 110M is a
// hybrid TDT-CTC, so the TDT decoder path applies unchanged.

final class FluidBackend: ASRBackend {
    let name: String
    private let version: AsrModelVersion
    private var asr: AsrManager!

    init(name: String, version: AsrModelVersion) {
        self.name = name
        self.version = version
    }

    func prepare(warmupSamples: [Float]) async throws {
        // First call downloads the CoreML weights to
        // ~/Library/Application Support/FluidAudio/ unless cached (v3 is
        // ~600 MB; 110M is smaller). `AsrManager.init` takes the loaded
        // models directly; no separate configure step.
        let models = try await AsrModels.downloadAndLoad(version: version)
        asr = AsrManager(config: .default, models: models)
        _ = try await run(samples: warmupSamples)
    }

    func run(samples: [Float]) async throws -> (text: String, elapsed: Double) {
        // TDT keeps decoder state (LSTM hidden + last-token) across
        // streaming chunks. For a single isolated utterance the
        // canonical pattern is a fresh state per transcribe call,
        // matching what Parakey's push-to-talk usage looks like.
        var state = try TdtDecoderState()
        let t0 = Date()
        let result = try await asr.transcribe(samples, decoderState: &state)
        return (result.text, Date().timeIntervalSince(t0))
    }
}

// ----- FluidAudio Unified (Parakeet Unified → CoreML → ANE) -------------
//
// English-only candidate backend. This is not a drop-in replacement for
// Parakey's production v3 path because it uses FluidAudio's Unified manager
// instead of `AsrModels` / `AsrManager`, but the benchmark interface is the
// same: one complete push-to-talk utterance in, one transcript out.

final class UnifiedBatchBackend: ASRBackend {
    let name = "fluid-ParakeetUnifiedBatch"
    private let trailingSilenceSeconds: Double
    private var asr: UnifiedAsrManager!

    init(trailingSilenceMs: Int) {
        self.trailingSilenceSeconds = Double(trailingSilenceMs) / 1000.0
    }

    func prepare(warmupSamples: [Float]) async throws {
        asr = UnifiedAsrManager()
        try await asr.loadModels()
        _ = try await run(samples: warmupSamples)
    }

    func run(samples: [Float]) async throws -> (text: String, elapsed: Double) {
        try await asr.reset()
        let paddedSamples = samplesAppendingTrailingSilence(
            samples,
            seconds: trailingSilenceSeconds
        )
        let t0 = Date()
        let text = try await asr.transcribe(paddedSamples)
        return (text, Date().timeIntervalSince(t0))
    }
}

// ----- FluidAudio Nemotron Speech Streaming (English → CoreML → ANE) ----
//
// English-only candidate backend. Nemotron is a streaming model, but for
// Parakey-style push-to-talk benchmarking we feed the full utterance and then
// finish the stream, which exercises the same final transcript path users
// would care about.

final class NemotronEnglishBackend: ASRBackend {
    let name = "fluid-NemotronEnglish1120"
    private var asr: StreamingNemotronAsrManager!

    func prepare(warmupSamples: [Float]) async throws {
        asr = StreamingNemotronAsrManager(requestedChunkSize: .ms1120)
        try await asr.loadModels()
        _ = try await run(samples: warmupSamples)
    }

    func run(samples: [Float]) async throws -> (text: String, elapsed: Double) {
        await asr.reset()
        let buffer = makeFloatPCMBuffer(samples: samples)
        let t0 = Date()
        _ = try await asr.process(audioBuffer: buffer)
        let text = try await asr.finish()
        return (text.trimmingCharacters(in: .whitespacesAndNewlines),
                Date().timeIntervalSince(t0))
    }
}

func makeFloatPCMBuffer(samples: [Float]) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: BENCH_SAMPLE_RATE,
        channels: 1,
        interleaved: false
    )!
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
    buf.frameLength = AVAudioFrameCount(samples.count)
    let dst = buf.floatChannelData!.pointee
    dst.update(from: samples, count: samples.count)
    return buf
}

func samplesAppendingTrailingSilence(_ samples: [Float],
                                     seconds: Double,
                                     sampleRate: Double = BENCH_SAMPLE_RATE) -> [Float] {
    guard seconds > 0, sampleRate > 0, !samples.isEmpty else { return samples }
    let silenceSampleCount = Int((seconds * sampleRate).rounded())
    guard silenceSampleCount > 0 else { return samples }
    return samples + Array(repeating: 0, count: silenceSampleCount)
}

// MARK: - Word error rate
//
// Standard word-level WER: edit distance between normalized token
// streams, divided by reference word count. Normalization lowercases and
// strips punctuation but does NOT do inverse text normalization, so a
// model emitting "16" against a reference of "sixteen" counts as an error
// — fine for a relative v3-vs-110m comparison on the same references, but
// keep it in mind when reading absolute numbers (and note the TTS clips
// are "too clean" to stand in for real dictation).

func werTokens(_ s: String) -> [String] {
    let lowered = s.lowercased()
    let kept = lowered.unicodeScalars.map { scalar -> Character in
        CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
    }
    return String(kept).split(separator: " ").map(String.init)
}

func wordEditDistance(_ ref: [String], _ hyp: [String]) -> Int {
    let n = ref.count, m = hyp.count
    if n == 0 { return m }
    if m == 0 { return n }
    var prev = Array(0...m)
    var curr = [Int](repeating: 0, count: m + 1)
    for i in 1...n {
        curr[0] = i
        for j in 1...m {
            let cost = ref[i - 1] == hyp[j - 1] ? 0 : 1
            curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
        }
        swap(&prev, &curr)
    }
    return prev[m]
}

func werPercent(reference: String, hypothesis: String) -> Double {
    let ref = werTokens(reference)
    let hyp = werTokens(hypothesis)
    guard !ref.isEmpty else { return hyp.isEmpty ? 0 : 100 }
    return Double(wordEditDistance(ref, hyp)) / Double(ref.count) * 100
}

func finalWordRetention(reference: String, hypothesis: String) -> (retained: Bool, expected: String, actualLast: String?)? {
    guard let expected = werTokens(reference).last else { return nil }
    let actualLast = werTokens(hypothesis).last
    return (actualLast == expected, expected, actualLast)
}

// MARK: - Memory
//
// `phys_footprint` is what Activity Monitor reports as "Memory" and is the
// closest single number to a model's resident cost. It does not capture
// everything the ANE allocates out of process, so treat it as a
// comparative signal between models, not an absolute RAM ceiling.

func footprintBytes() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? info.phys_footprint : 0
}

func fmtMB(_ bytes: UInt64) -> String { String(format: "%6.1f MB", Double(bytes) / (1024 * 1024)) }

// MARK: - Bench harness

struct TrialResult {
    let elapsed: Double
    let text: String
}

func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let idx = max(0, min(sorted.count - 1, Int(Double(sorted.count - 1) * p)))
    return sorted[idx]
}

func fmtMs(_ s: Double) -> String { String(format: "%7.1f ms", s * 1000) }

func runBackend(_ backend: ASRBackend, samples: [Float], trials: Int) async throws -> (results: [TrialResult], peak: UInt64) {
    var out: [TrialResult] = []
    var peak = footprintBytes()
    for i in 0..<trials {
        let (text, t) = try await backend.run(samples: samples)
        out.append(TrialResult(elapsed: t, text: text))
        peak = max(peak, footprintBytes())
        FileHandle.standardError.write(Data("    \(backend.name) trial \(i+1)/\(trials): \(fmtMs(t))\n".utf8))
    }
    return (out, peak)
}

func redactedTextLabel(_ text: String) -> String {
    "<redacted \(text.count) chars>"
}

func summarize(_ name: String,
               _ results: [TrialResult],
               reference: String?,
               baseline: UInt64,
               peak: UInt64,
               redactTranscripts: Bool) {
    let times = results.map(\.elapsed)
    let p50 = percentile(times, 0.5)
    let mn = times.min() ?? 0
    let mx = times.max() ?? 0
    let texts = Set(results.map(\.text))
    let delta = peak >= baseline ? peak - baseline : 0
    print("")
    print("  \(name)")
    print("    latency:  p50=\(fmtMs(p50))  min=\(fmtMs(mn))  max=\(fmtMs(mx))")
    print("    memory:   peak=\(fmtMB(peak))  Δ-from-start=\(fmtMB(delta))")
    func werTag(_ text: String) -> String {
        guard let reference else { return "" }
        return " [WER \(String(format: "%.1f%%", werPercent(reference: reference, hypothesis: text)))]"
    }
    func finalWordTag(_ text: String) -> String {
        guard let reference,
              let retention = finalWordRetention(reference: reference, hypothesis: text)
        else { return "" }
        if redactTranscripts {
            return " [final-word retained=\(retention.retained)]"
        }
        let actualLast = retention.actualLast ?? "<none>"
        return " [final-word retained=\(retention.retained) expected=\"\(retention.expected)\" actual-last=\"\(actualLast)\"]"
    }
    if texts.count == 1, let only = texts.first {
        let display = redactTranscripts ? redactedTextLabel(only) : "\"\(only)\""
        print("    transcript:\(werTag(only))\(finalWordTag(only)) \(display)")
    } else {
        print("    transcripts (\(texts.count) distinct):")
        for t in texts.sorted() {
            let display = redactTranscripts ? redactedTextLabel(t) : "\"\(t)\""
            print("      •\(werTag(t))\(finalWordTag(t)) \(display)")
        }
    }
}

// MARK: - Main

@main
struct ParakeyBench {
    static func main() async throws {
        let args = parseArgs()

        var runSummary = "parakey-bench: \(args.file.lastPathComponent), \(args.trials) trials, backend=\(args.backend)"
        if args.backend == "unified" || args.backend == "both" {
            runSummary += ", unified-trailing-silence-ms=\(args.unifiedTrailingSilenceMs)"
        }
        log(runSummary)
        let samples = try load16kMono(url: args.file)
        let durSec = Double(samples.count) / 16_000
        log("audio: \(samples.count) samples (~\(String(format: "%.2f", durSec)) s @ 16 kHz mono)")

        // Reference for WER: explicit --ref wins, else a sibling
        // "<stem>.txt" (written by generate-test-audio.sh).
        let reference: String? = {
            if let r = args.ref { return r }
            let sidecar = args.file.deletingPathExtension().appendingPathExtension("txt")
            if let text = try? String(contentsOf: sidecar, encoding: .utf8) {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return nil
        }()
        if let reference {
            let display = args.redactTranscripts ? redactedTextLabel(reference) : "\"\(reference)\""
            log("reference: \(display)")
        } else {
            log("no reference (--ref or <file>.txt) — WER skipped")
        }

        // Use the same audio for warmup — it's the most representative
        // "first inference" for the same shape we'll measure.
        let warmup = samples

        let known = ["apple", "v3", "unified", "nemotron-en", "110m", "fluid", "both"]
        guard known.contains(args.backend) else {
            FileHandle.standardError.write(Data("unknown --backend \"\(args.backend)\" (expected \(known.joined(separator: "|")))\n".utf8))
            exit(2)
        }
        var backends: [ASRBackend] = []
        if args.backend == "apple" || args.backend == "both" {
            if #available(macOS 26, *) {
                backends.append(AppleBackend())
            } else {
                print("apple backend skipped — requires macOS 26+")
            }
        }
        if args.backend == "v3" || args.backend == "fluid" || args.backend == "both" {
            backends.append(FluidBackend(name: "fluid-ParakeetTDTv3", version: .v3))
        }
        if args.backend == "unified" || args.backend == "fluid" || args.backend == "both" {
            backends.append(UnifiedBatchBackend(trailingSilenceMs: args.unifiedTrailingSilenceMs))
        }
        if args.backend == "nemotron-en" || args.backend == "fluid" || args.backend == "both" {
            backends.append(NemotronEnglishBackend())
        }
        if args.backend == "110m" || args.backend == "fluid" || args.backend == "both" {
            // Kept wired up but off the default path: as of the current
            // tested FluidAudio revision the 110m CoreML bundle won't load — missing
            // CtcHead.mlmodelc plus a decoder shape mismatch (2×1×640 vs
            // 1×1×640). prepare() fails gracefully and the run continues.
            // Re-test with --backend 110m once it's fixed upstream.
            backends.append(FluidBackend(name: "fluid-ParakeetTDTCTC110M", version: .tdtCtc110m))
        }

        // Footprint before any model loads. Δ-from-start is only a clean
        // per-model cost when one backend runs per process; with several in
        // one run the earlier models stay resident (see --help).
        let baseline = footprintBytes()
        log("baseline footprint: \(fmtMB(baseline))")
        if backends.count > 1 {
            log("note: \(backends.count) backends in one process — memory is cumulative; run one --backend per process for clean per-model numbers")
        }

        for backend in backends {
            log("preparing \(backend.name)…")
            let prepT0 = Date()
            do {
                try await backend.prepare(warmupSamples: warmup)
            } catch {
                log("  prepare(\(backend.name)) FAILED: \(error)")
                continue
            }
            let prepDt = Date().timeIntervalSince(prepT0)
            log("  ready in \(fmtMs(prepDt)) (model load + 1 warmup inference)")

            do {
                let (results, peak) = try await runBackend(backend, samples: samples, trials: args.trials)
                summarize(backend.name,
                          results,
                          reference: reference,
                          baseline: baseline,
                          peak: peak,
                          redactTranscripts: args.redactTranscripts)
            } catch {
                log("  run(\(backend.name)) FAILED: \(error)")
            }
        }
    }
}

/// stderr write that flushes immediately — print(...) buffering eats
/// the last line before a crash, which made this benchmark feel
/// broken when it wasn't.
func log(_ s: String) {
    FileHandle.standardError.write(Data((s + "\n").utf8))
}
