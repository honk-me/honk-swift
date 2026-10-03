// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HonkMe",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "HonkMe", targets: ["HonkMe"]),
    ],
    targets: [
        .target(name: "HonkMe"),
        .testTarget(name: "HonkMeTests", dependencies: ["HonkMe"]),
    ],
    swiftLanguageModes: [.v6]
)
