// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SystemEQ",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "EQCore", targets: ["EQCore"]),
        .executable(name: "SystemEQ", targets: ["SystemEQ"]),
    ],
    targets: [
        // Platform-independent preset parsing and DSP. Shared with a future iOS app.
        .target(name: "EQCore"),
        // macOS menu bar app that applies the EQ to all system audio.
        .executableTarget(name: "SystemEQ", dependencies: ["EQCore"]),
        .testTarget(
            name: "EQCoreTests",
            dependencies: ["EQCore"],
            // Synthetic curves and the output of the original Python AutoEq for them.
            resources: [.copy("Fixtures")]
        ),
    ]
)
