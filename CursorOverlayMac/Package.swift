// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CursorOverlayMac",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "CursorOverlay", targets: ["CursorOverlay"])
    ],
    targets: [
        .executableTarget(
            name: "CursorOverlay",
            path: "Sources/CursorOverlay"
        )
    ]
)
