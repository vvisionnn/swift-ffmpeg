// swift-tools-version: 6.1

import PackageDescription

let ffmpegBinaryTarget: Target =
    Context.environment["SWIFT_FFMPEG_USE_LOCAL_XCFRAMEWORK"] == "1"
        ? .binaryTarget(
            name: "FFmpeg",
            path: "Artifacts/FFmpeg.xcframework"
        )
        : .binaryTarget(
            name: "FFmpeg",
            url: "https://github.com/vvisionnn/swift-ffmpeg/releases/download/1.0.0/FFmpeg.xcframework.zip",
            checksum: "2e8023345a02026f6372ed0d12c48b4f838bab3baf7541aabece337e2d00ccbd"
        )

let package = Package(
    name: "swift-ffmpeg",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(
            name: "FFmpeg",
            targets: ["FFmpeg", "FFmpegLinkerSupport"]
        ),
    ],
    targets: [
        ffmpegBinaryTarget,
        .target(
            name: "FFmpegLinkerSupport",
            dependencies: ["FFmpeg"],
            resources: [
                .process("PrivacyInfo.xcprivacy"),
            ],
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Security"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreServices", .when(platforms: [.macOS])),
                .linkedLibrary("bz2"),
                .linkedLibrary("iconv"),
                .linkedLibrary("z"),
            ]
        ),
        .testTarget(
            name: "FFmpegTests",
            dependencies: ["FFmpeg", "FFmpegLinkerSupport"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
