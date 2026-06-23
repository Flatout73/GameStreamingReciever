// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "ReceiverGame",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/KevinVitale/SwiftSDL.git", from: "0.2.0-alpha.20")
    ],
    targets: [
        .systemLibrary(
            name: "CFFmpeg",
            pkgConfig: "libavcodec libavutil libswscale",
            providers: [
                .brew(["ffmpeg"])
            ]
        ),
        .executableTarget(
            name: "ReceiverGame",
            dependencies: [
                "SwiftSDL",
                "CFFmpeg"
            ],
            resources: [
                .process("Resources")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
