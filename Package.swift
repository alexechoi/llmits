// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LLMits",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LLMits", targets: ["LLMits"]),
    ],
    targets: [
        // Credentials, parsing, state and formatting: everything that can be tested without AppKit.
        .target(name: "UsageCore"),
        // The menu bar app itself.
        .executableTarget(name: "LLMits", dependencies: ["UsageCore"]),
        .testTarget(name: "UsageCoreTests", dependencies: ["UsageCore"]),
    ]
)
