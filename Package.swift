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
            checksum: "f6ca366a0bc4ccb4716e4fade1683c318249c3d53c5f324cb465442230a92f49"
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
