// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Pero",
    platforms: [.macOS(.v15)],
    targets: [
        // Notes library core: files, index, parsing. No AppKit, so extensions can use it later.
        .target(name: "PeroKit", path: "Sources/PeroKit"),
        .executableTarget(name: "Pero", dependencies: ["PeroKit"], path: "Sources/Pero"),
        .testTarget(name: "PeroKitTests", dependencies: ["PeroKit"], path: "Tests/PeroKitTests"),
    ],
    swiftLanguageModes: [.v5]
)
