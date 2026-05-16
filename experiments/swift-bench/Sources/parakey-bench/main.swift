// parakey-bench — head-to-head benchmark of Apple SpeechAnalyzer
// (DictationTranscriber on the Apple Neural Engine, built into
// macOS 26 Tahoe) vs FluidAudio (Parakeet TDT v3 via CoreML on the
// ANE) on the same audio. Output is intentionally comparable to
// the sibling `./bench-py.py` (Python parakey-mlx, GPU/Metal), so
// all three backends can be cross-referenced in one table.
//
// Usage:
//   parakey-bench --file path/to/audio.wav [--trials 5] [--backend apple|fluid|both]
//
// Audio must be 16 kHz mono Float32 (or convertible to that —
// AVAudioFile + AVAudioPCMBuffer handles the conversion).

import Foundation
import AVFoundation
import Speech
import FluidAudio

// MARK: - CLI

struct CLIArgs {
    var file: URL
    var trials: Int = 5
    var backend: String = "both"   // "apple" | "fluid" | "both"
}

func parseArgs() -> CLIArgs {
    var iter = CommandLine.arguments.dropFirst().makeIterator()
    var file: URL? = nil
    var trials: Int = 5
    var backend: String = "both"
    while let arg = iter.next() {
        switch arg {
        case "--file":
            if let v = iter.next() { file = URL(fileURLWithPath: v) }
        case "--trials":
            if let v = iter.next(), let n = Int(v) { trials = n }
        case "--backend":
            if let v = iter.next() { backend = v }
        case "-h", "--help":
            print("""
            usage: parakey-bench --file <wav> [--trials N] [--backend apple|fluid|both]
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
    return CLIArgs(file: file, trials: trials, backend: backend)
}

// MARK: - Audio loading
//
// Both backends want 16 kHz mono Float32. AVAudioFile gives us
// whatever the file actually is; we convert with AVAudioConverter
// rather than trusting the caller to have pre-resampled.

enum AudioLoadError: Error { case openFailed, convertFailed, emptyBuffer }

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
    var fed = false
    let status = converter.convert(to: dstBuf, error: &error) { _, outStatus in
        if fed { outStatus.pointee = .endOfStream; return nil }
        fed = true; outStatus.pointee = .haveData; return srcBuf
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

// ----- FluidAudio (Parakeet TDT v3 → CoreML → ANE) ----------------------

final class FluidBackend: ASRBackend {
    let name = "fluid-ParakeetTDTv3"
    private var asr: AsrManager!

    func prepare(warmupSamples: [Float]) async throws {
        // First call downloads ~600 MB of CoreML weights to
        // ~/Library/Caches/.../FluidInference unless they're already
        // cached. `AsrManager.init` takes the loaded models directly;
        // no separate configure step.
        let models = try await AsrModels.downloadAndLoad(version: .v3)
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

func runBackend(_ backend: ASRBackend, samples: [Float], trials: Int) async throws -> [TrialResult] {
    var out: [TrialResult] = []
    for i in 0..<trials {
        let (text, t) = try await backend.run(samples: samples)
        out.append(TrialResult(elapsed: t, text: text))
        FileHandle.standardError.write(Data("    \(backend.name) trial \(i+1)/\(trials): \(fmtMs(t))\n".utf8))
    }
    return out
}

func summarize(_ name: String, _ results: [TrialResult]) {
    let times = results.map(\.elapsed)
    let p50 = percentile(times, 0.5)
    let mn = times.min() ?? 0
    let mx = times.max() ?? 0
    let texts = Set(results.map(\.text))
    print("")
    print("  \(name)")
    print("    latency:  p50=\(fmtMs(p50))  min=\(fmtMs(mn))  max=\(fmtMs(mx))")
    if texts.count == 1, let only = texts.first {
        print("    transcript: \"\(only)\"")
    } else {
        print("    transcripts (\(texts.count) distinct):")
        for t in texts.sorted() { print("      • \"\(t)\"") }
    }
}

// MARK: - Main

@main
struct ParakeyBench {
    static func main() async throws {
        let args = parseArgs()

        log("parakey-bench: \(args.file.lastPathComponent), \(args.trials) trials, backend=\(args.backend)")
        let samples = try load16kMono(url: args.file)
        let durSec = Double(samples.count) / 16_000
        log("audio: \(samples.count) samples (~\(String(format: "%.2f", durSec)) s @ 16 kHz mono)")

        // Use the same audio for warmup — it's the most representative
        // "first inference" for the same shape we'll measure.
        let warmup = samples

        var backends: [ASRBackend] = []
        if args.backend == "apple" || args.backend == "both" {
            if #available(macOS 26, *) {
                backends.append(AppleBackend())
            } else {
                print("apple backend skipped — requires macOS 26+")
            }
        }
        if args.backend == "fluid" || args.backend == "both" {
            backends.append(FluidBackend())
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
                let results = try await runBackend(backend, samples: samples, trials: args.trials)
                summarize(backend.name, results)
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
