// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Morphit",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "Morphit", path: "Sources/Morphit")
    ],
    swiftLanguageModes: [.v5]
)
