// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeUsageBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ClaudeUsageBar", targets: ["ClaudeUsageBar"]),
    ],
    targets: [
        // Credentials, parsing and formatting: everything that can be tested without AppKit.
        .target(name: "UsageCore"),
        // The menu bar app itself.
        .executableTarget(name: "ClaudeUsageBar", dependencies: ["UsageCore"]),
        .testTarget(name: "UsageCoreTests", dependencies: ["UsageCore"]),
    ]
)
