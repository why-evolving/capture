// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Capture",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Capture", targets: ["Capture"])],
    targets: [
        .target(name: "CaptureCore"),
        .executableTarget(name: "Capture", dependencies: ["CaptureCore"]),
        .testTarget(name: "CaptureCoreTests", dependencies: ["CaptureCore"])
    ],
    swiftLanguageModes: [.v5]
)
