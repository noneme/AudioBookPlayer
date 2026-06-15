// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "abPlayerSwift",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(name: "abPlayerUI", targets: ["abPlayerUI"]),
        .executable(name: "abPlayerApp", targets: ["abPlayerApp"]),
        .library(name: "abPlayerCore", targets: ["abPlayerCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.6.0"),
        .package(path: "Vendor/ffmpeg-kit-spm")
    ],
    targets: [
        .target(
            name: "abPlayerCore",
            dependencies: [
                "SwiftSoup",
                .product(name: "ffmpegkit", package: "ffmpeg-kit-spm"),
                .product(name: "libavcodec", package: "ffmpeg-kit-spm"),
                .product(name: "libavdevice", package: "ffmpeg-kit-spm"),
                .product(name: "libavfilter", package: "ffmpeg-kit-spm"),
                .product(name: "libavformat", package: "ffmpeg-kit-spm"),
                .product(name: "libavutil", package: "ffmpeg-kit-spm"),
                .product(name: "libswresample", package: "ffmpeg-kit-spm"),
                .product(name: "libswscale", package: "ffmpeg-kit-spm")
            ],
            path: "Sources/abPlayerCore",
            resources: [
                .copy("Resources/akniga_decrypt.js")
            ]
        ),
        .target(
            name: "abPlayerUI",
            dependencies: ["abPlayerCore"],
            path: "Sources/abPlayerApp",
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "abPlayerApp",
            dependencies: ["abPlayerUI"],
            path: "Sources/abPlayerAppMain"
        ),
        .testTarget(
            name: "abPlayerCoreTests",
            dependencies: ["abPlayerCore"],
            path: "Tests/abPlayerCoreTests"
        )
    ]
)
