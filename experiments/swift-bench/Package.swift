// swift-tools-version: 6.0
//
// parakey-bench — Swift CLI that benchmarks two ASR backends against
// the same audio inputs. Output is comparable to the existing
// parakey-mlx numbers from ../../bench.py.
//
// Backends tested:
//   * Apple `SpeechAnalyzer` + `DictationTranscriber` (built into
//     macOS 26 Tahoe — uses Apple Neural Engine, no model download).
//   * FluidAudio's `AsrManager` running Parakeet TDT v3 via CoreML
//     on the ANE (model downloaded from HuggingFace on first run,
//     ~600 MB, cached thereafter).
//
// macOS 26 is required for `SpeechAnalyzer` / `DictationTranscriber`.
// FluidAudio itself targets macOS 14+, so the gating factor is
// Apple's framework, not the dependency.
import PackageDescription

let package = Package(
    name: "parakey-bench",
    platforms: [
        .macOS("26.0"),  // SpeechAnalyzer / DictationTranscriber are Tahoe-only.
    ],
    products: [
        .executable(name: "parakey-bench", targets: ["parakey-bench"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "parakey-bench",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
    ]
)
