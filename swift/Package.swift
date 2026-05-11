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
