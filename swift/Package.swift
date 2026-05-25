// swift-tools-version: 6.0
//
// Parakey — single-file Swift menu-bar push-to-talk dictation app
// for macOS Apple Silicon. Native AppKit / AVFoundation, FluidAudio
// driving Parakeet TDT v3 on the Apple Neural Engine. macOS 26
// minimum: required for the Hardened Runtime microphone entitlement
// (`com.apple.security.device.audio-input`) and FluidAudio's CoreML
// integration; also keeps the door open for SpeechAnalyzer if a
// future backend swap is wanted.
import PackageDescription

let package = Package(
    name: "Parakey",
    platforms: [
        .macOS("14.0"),
    ],
    products: [
        .executable(name: "Parakey", targets: ["Parakey"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git",
                 revision: "fb8b779380a978da636253b52d6106975de293d5"),
    ],
    targets: [
        .executableTarget(
            name: "Parakey",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
            // No `resources:` here on purpose. SwiftPM bundles them as
            // a `<Package>_<Target>.bundle` directory next to the
            // executable, which `codesign --deep` won't accept as a
            // signable component because it lacks Info.plist. Instead,
            // the menubar PNGs are copied into Contents/Resources/ by
            // dev-run.sh and ship-swift.sh — the canonical .app layout
            // where Bundle.main finds them via the standard search
            // path. Source PNGs live in swift/Resources/ at the repo
            // root, NOT in the SwiftPM target, so SwiftPM never sees them.
        ),
    ]
)
