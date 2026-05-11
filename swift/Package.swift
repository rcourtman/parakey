// swift-tools-version: 6.0
//
// Parakey (Swift). Successor to parakey.py — same UX (menu bar
// push-to-talk dictation), native AppKit / AVFoundation, FluidAudio
// on the Apple Neural Engine. macOS 26 minimum so we can use
// SpeechAnalyzer later if we want and so FluidAudio's CoreML
// integration is happy.
import PackageDescription

let package = Package(
    name: "Parakey",
    platforms: [
        .macOS("26.0"),
    ],
    products: [
        .executable(name: "Parakey", targets: ["Parakey"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "Parakey",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
    ]
)
