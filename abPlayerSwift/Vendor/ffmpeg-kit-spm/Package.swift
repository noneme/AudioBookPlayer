// swift-tools-version: 5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let release = "v1.0.1"

// SHA-256 of each binary zip (not git SHAs). Recomputed by ./build.sh when you zip prebuilt/*.xcframework.
let frameworks = ["ffmpegkit": "8759378db9a67eccb03ae801e04d70cc0ab7a11193b71a5ed0ff404088b45eae", "libavcodec": "922594c24e9701433185c3c8179f765b774bb3e14673529f6bf4b4423aecfc71", "libavdevice": "b1462c8020e6791cfb1f78fadc4479f58cddeb603fe792d35d77683d828b614c", "libavfilter": "75f6331e9d7d08d11863995a8844ebd288ed1c71f808a2420f4fd1bc5ce93307", "libavformat": "0c95f6b1a2a9ab9de02ada16f12cd9ffd0a89a15c0ed55b062e728b87864c16b", "libavutil": "fcc8a667f4c3ec05c7c9f5896f3dbec8abadbd1c9c5b864a0dc7c4be023d34c1", "libswresample": "8e9e5be6b740620f81f20df15a879944d1cecab9c4c10b8b7fce801737c0fe59", "libswscale": "1628c9e78fed38f1a490361e117ed18eea56d4d4d4442830dca3387d2c149a67"]

func xcframework(_ package: Dictionary<String, String>.Element) -> Target {
    let url = "https://github.com/codewithtamim/ffmpeg-kit-spm/releases/download/\(release)/\(package.key).xcframework.zip"
    return .binaryTarget(name: package.key, url: url, checksum: package.value)
}

let linkerSettings: [LinkerSetting] = [
    .linkedFramework("AudioToolbox", .when(platforms: [.macOS, .iOS, .macCatalyst, .tvOS])),
    .linkedFramework("AVFoundation", .when(platforms: [.macOS, .iOS, .macCatalyst])),
    .linkedFramework("CoreMedia", .when(platforms: [.macOS])),
    .linkedFramework("OpenGL", .when(platforms: [.macOS])),
    .linkedFramework("VideoToolbox", .when(platforms: [.macOS, .iOS, .macCatalyst, .tvOS])),
    .linkedLibrary("z"),
    .linkedLibrary("lzma"),
    .linkedLibrary("bz2"),
    .linkedLibrary("iconv")
]

let libAVFrameworks = frameworks.filter({ $0.key != "ffmpegkit" })

let package = Package(
    name: "ffmpeg-kit-spm",
    platforms: [.iOS(.v12), .macOS(.v10_15), .tvOS(.v11), .watchOS(.v7)],
    products: [
        .library(
            name: "ffmpegkit",
            targets: ["ffmpegkit"]),
        .library(
            name: "FFmpeg-Kit",
            type: .dynamic,
            targets: ["FFmpeg-Kit", "ffmpegkit"]),
        .library(
            name: "FFmpeg",
            type: .dynamic,
            targets: ["FFmpeg"] + libAVFrameworks.map { $0.key }),
    ] + libAVFrameworks.map { .library(name: $0.key, targets: [$0.key]) },
    dependencies: [],
    targets: [
        .target(
            name: "FFmpeg-Kit",
            dependencies: frameworks.map { .byName(name: $0.key) },
            linkerSettings: linkerSettings),
        .target(
            name: "FFmpeg",
            dependencies: libAVFrameworks.map { .byName(name: $0.key) },
            linkerSettings: linkerSettings),
    ] + frameworks.map { xcframework($0) }
)
