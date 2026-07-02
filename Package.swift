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
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.13.0"),
        // Same fork Citadel depends on — matched so SPM resolves a single copy.
        .package(url: "https://github.com/Wellz26/swift-nio-ssh.git", "0.3.4" ..< "0.4.0"),
    ],
    targets: [
        .executableTarget(
            name: "FileBullet",
            dependencies: [
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "Sources/FileBullet",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
