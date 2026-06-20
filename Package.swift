// swift-tools-version:6.0
import PackageDescription

// Ignition Browser — menu-bar macOS app (Apple Silicon).
// No external SwiftPM deps in the skeleton.
// TODO(M6): add Sparkle (https://github.com/sparkle-project/Sparkle) as a dependency for auto-update.
let package = Package(
    name: "IgnitionBrowser",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "IgnitionBrowser", targets: ["IgnitionBrowser"])
    ],
    targets: [
        .executableTarget(
            name: "IgnitionBrowser",
            path: "Sources/IgnitionBrowser"
        ),
        .testTarget(
            name: "IgnitionBrowserTests",
            dependencies: ["IgnitionBrowser"],
            path: "Tests/IgnitionBrowserTests"
        )
    ]
)
