#!/bin/bash -p

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
reject_shell_startup_environment
load_release_configuration

"$SCRIPT_DIR/validate-artifact.sh"

(
    cd "$PROJECT_ROOT"
    SWIFT_FFMPEG_USE_LOCAL_XCFRAMEWORK=1 \
        swift test --manifest-cache none --parallel
    SWIFT_FFMPEG_USE_LOCAL_XCFRAMEWORK=1 \
        swift build --manifest-cache none -c release
)

consumer_root="$(mktemp -d "${TMPDIR:-/tmp}/swift-ffmpeg-consumer.XXXXXX")"
cleanup_consumer() {
    case "$consumer_root" in
        "${TMPDIR:-/tmp}"/swift-ffmpeg-consumer.*)
            /bin/rm -rf "$consumer_root"
            ;;
        *)
            echo "Refusing to remove unexpected consumer path: $consumer_root" >&2
            return 1
            ;;
    esac
}
trap cleanup_consumer EXIT
mkdir -p "$consumer_root/Sources/Smoke"
/bin/ln -s "$PROJECT_ROOT" "$consumer_root/swift-ffmpeg"

cat >"$consumer_root/Package.swift" <<'SWIFT'
// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "FFmpegConsumerSmoke",
    platforms: [.macOS(.v12)],
    dependencies: [
        .package(path: "swift-ffmpeg"),
    ],
    targets: [
        .executableTarget(
            name: "Smoke",
            dependencies: [
                .product(name: "FFmpeg", package: "swift-ffmpeg"),
            ]
        ),
    ]
)
SWIFT

cat >"$consumer_root/Sources/Smoke/main.swift" <<SWIFT
import FFmpeg

precondition(String(cString: av_version_info()) == "$FFMPEG_VERSION")
precondition(avcodec_version() > 0)
precondition(avformat_version() > 0)
precondition(avutil_version() > 0)
precondition(swresample_version() > 0)
precondition(swscale_version() > 0)
print(String(cString: av_version_info()))
SWIFT

(
    cd "$consumer_root"
    SWIFT_FFMPEG_USE_LOCAL_XCFRAMEWORK=1 \
        swift run --manifest-cache none Smoke
)

echo "Local package and external consumer tests passed"
