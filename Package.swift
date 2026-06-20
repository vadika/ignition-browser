// swift-tools-version:6.0
import PackageDescription

// Ignition Browser — menu-bar macOS app (Apple Silicon).
let package = Package(
    name: "IgnitionBrowser",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "IgnitionBrowser", targets: ["IgnitionBrowser"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "IgnitionBrowser",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/IgnitionBrowser"
        ),
        .testTarget(
            name: "IgnitionBrowserTests",
            dependencies: ["IgnitionBrowser"],
            path: "Tests/IgnitionBrowserTests"
        )
    ]
)
