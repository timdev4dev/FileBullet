// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "FileBullet",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.12.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "FileBullet",
            dependencies: [
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "NIOCore", package: "swift-nio"),
            ],
            path: "Sources/FileBullet",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
