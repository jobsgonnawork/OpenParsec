// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MicSidecarMac",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "MicSidecarReceiver", targets: ["MicSidecarReceiver"])
    ],
    targets: [
        .executableTarget(
            name: "MicSidecarReceiver",
            path: "Sources/MicSidecarReceiver"
        )
    ]
)
