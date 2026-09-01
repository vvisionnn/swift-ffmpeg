#!/bin/bash

reject_shell_startup_environment() {
    local variable
    set -f
    for variable in $(compgen -e); do
        case "$variable" in
            BASH_ENV|ENV|BASHOPTS|SHELLOPTS|CDPATH|GLOBIGNORE|POSIXLY_CORRECT|BASH_COMPAT|BASH_FUNC_*)
                echo "Shell startup override is not accepted: $variable" >&2
                return 1
                ;;
        esac
    done
    set +f
    unset BASH_ENV ENV CDPATH GLOBIGNORE POSIXLY_CORRECT BASH_COMPAT
    export -n BASHOPTS SHELLOPTS
}

assert_exact_value() {
    local label="$1"
    local expected="$2"
    local actual="$3"
    if [[ "$actual" != "$expected" ]]; then
        echo "$label mismatch" >&2
        echo "Expected: $expected" >&2
        echo "Actual:   $actual" >&2
        return 1
    fi
}

require_command() {
    local command_name="$1"
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "Missing required command: $command_name" >&2
        return 1
    fi
}

sha256_file() {
    /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

verify_sha256() {
    local path="$1"
    local expected="$2"
    local label="$3"
    local actual
    actual="$(sha256_file "$path")"
    assert_exact_value "$label SHA-256" "$expected" "$actual"
}

load_release_configuration() {
    local package_pattern='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
    local upstream_pattern='^[1-9][0-9]*\.[0-9]+(\.[0-9]+)?$'
    local sha_pattern='^[0-9a-f]{64}$'
    local fingerprint_pattern='^[0-9A-F]{40}$'

    SCRIPT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    PROJECT_ROOT="$(cd "$SCRIPT_LIB_DIR/../.." && pwd)"
    RELEASE_CONFIG="${SWIFT_FFMPEG_RELEASE_CONFIG:-$PROJECT_ROOT/Configuration/release.json}"

    [[ -f "$RELEASE_CONFIG" ]] || {
        echo "Missing release configuration: $RELEASE_CONFIG" >&2
        return 1
    }
    require_command jq

    SCHEMA_VERSION="$(jq -er '.schemaVersion' "$RELEASE_CONFIG")"
    PACKAGE_VERSION="$(jq -er '.packageVersion' "$RELEASE_CONFIG")"
    ARTIFACT_NAME="$(jq -er '.artifact.name' "$RELEASE_CONFIG")"
    ARTIFACT_CHECKSUM="$(jq -er '.artifact.swiftPackageChecksum' "$RELEASE_CONFIG")"
    EXPECTED_INFO_PLIST_SHA256="$(jq -er '.artifact.xcframework.infoPlistSHA256' "$RELEASE_CONFIG")"
    EXPECTED_IOS_ARCHIVE_SHA256="$(jq -er '.artifact.xcframework.slices["ios-arm64"]' "$RELEASE_CONFIG")"
    EXPECTED_SIMULATOR_ARCHIVE_SHA256="$(jq -er '.artifact.xcframework.slices["ios-arm64_x86_64-simulator"]' "$RELEASE_CONFIG")"
    EXPECTED_MACOS_ARCHIVE_SHA256="$(jq -er '.artifact.xcframework.slices["macos-arm64_x86_64"]' "$RELEASE_CONFIG")"
    SOURCE_DATE_EPOCH="$(jq -er '.build.sourceDateEpoch' "$RELEASE_CONFIG")"
    IOS_MINIMUM_VERSION="$(jq -er '.build.iOSMinimumVersion' "$RELEASE_CONFIG")"
    MACOS_MINIMUM_VERSION="$(jq -er '.build.macOSMinimumVersion' "$RELEASE_CONFIG")"
    FFMPEG_VERSION="$(jq -er '.ffmpeg.version' "$RELEASE_CONFIG")"
    FFMPEG_URL="$(jq -er '.ffmpeg.url' "$RELEASE_CONFIG")"
    FFMPEG_SIGNATURE_URL="$(jq -er '.ffmpeg.signatureURL' "$RELEASE_CONFIG")"
    FFMPEG_SHA256="$(jq -er '.ffmpeg.sha256' "$RELEASE_CONFIG")"
    FFMPEG_RELEASE_KEY_FINGERPRINT="$(jq -er '.ffmpeg.releaseKeyFingerprint' "$RELEASE_CONFIG")"
    FFMPEG_RELEASE_KEY_SHA256="$(jq -er '.ffmpeg.releaseKeySHA256' "$RELEASE_CONFIG")"
    DAV1D_VERSION="$(jq -er '.dav1d.version' "$RELEASE_CONFIG")"
    DAV1D_URL="$(jq -er '.dav1d.url' "$RELEASE_CONFIG")"
    DAV1D_SHA256="$(jq -er '.dav1d.sha256' "$RELEASE_CONFIG")"
    EXPECTED_XCODE_VERSION_VALUE="$(jq -er '.toolchain.xcodeVersion' "$RELEASE_CONFIG")"
    EXPECTED_XCODE_BUILD="$(jq -er '.toolchain.xcodeBuild' "$RELEASE_CONFIG")"
    EXPECTED_IPHONEOS_SDK_VERSION="$(jq -er '.toolchain.iPhoneOSSDKVersion' "$RELEASE_CONFIG")"
    EXPECTED_IPHONESIMULATOR_SDK_VERSION="$(jq -er '.toolchain.iPhoneSimulatorSDKVersion' "$RELEASE_CONFIG")"
    EXPECTED_MACOSX_SDK_VERSION="$(jq -er '.toolchain.macOSSDKVersion' "$RELEASE_CONFIG")"
    EXPECTED_CLANG_VERSION="$(jq -er '.toolchain.clangVersion' "$RELEASE_CONFIG")"
    EXPECTED_CCTOOLS_VERSION="$(jq -er '.toolchain.cctoolsVersion' "$RELEASE_CONFIG")"
    EXPECTED_MESON_VERSION="$(jq -er '.toolchain.mesonVersion' "$RELEASE_CONFIG")"
    EXPECTED_NINJA_VERSION="$(jq -er '.toolchain.ninjaVersion' "$RELEASE_CONFIG")"
    EXPECTED_PKG_CONFIG_VERSION="$(jq -er '.toolchain.pkgConfigVersion' "$RELEASE_CONFIG")"
    EXPECTED_MAKE_VERSION="$(jq -er '.toolchain.makeVersion' "$RELEASE_CONFIG")"

    [[ "$SCHEMA_VERSION" == "1" ]] || {
        echo "Unsupported release configuration schema: $SCHEMA_VERSION" >&2
        return 1
    }
    [[ "$PACKAGE_VERSION" =~ $package_pattern ]] || {
        echo "Invalid package SemVer: $PACKAGE_VERSION" >&2
        return 1
    }
    [[ "$FFMPEG_VERSION" =~ $upstream_pattern ]] || {
        echo "Invalid FFmpeg version: $FFMPEG_VERSION" >&2
        return 1
    }
    [[ "$DAV1D_VERSION" =~ $upstream_pattern ]] || {
        echo "Invalid dav1d version: $DAV1D_VERSION" >&2
        return 1
    }
    [[ "$FFMPEG_SHA256" =~ $sha_pattern && \
        "$DAV1D_SHA256" =~ $sha_pattern && \
        "$FFMPEG_RELEASE_KEY_SHA256" =~ $sha_pattern ]] || {
        echo "Source SHA-256 fields must be lowercase 64-character hex" >&2
        return 1
    }
    [[ "$ARTIFACT_CHECKSUM" =~ $sha_pattern && \
        "$EXPECTED_INFO_PLIST_SHA256" =~ $sha_pattern && \
        "$EXPECTED_IOS_ARCHIVE_SHA256" =~ $sha_pattern && \
        "$EXPECTED_SIMULATOR_ARCHIVE_SHA256" =~ $sha_pattern && \
        "$EXPECTED_MACOS_ARCHIVE_SHA256" =~ $sha_pattern ]] || {
        echo "Artifact checksums must be lowercase 64-character hex" >&2
        return 1
    }
    [[ "$FFMPEG_RELEASE_KEY_FINGERPRINT" =~ $fingerprint_pattern ]] || {
        echo "FFmpeg release-key fingerprint must be uppercase 40-character hex" >&2
        return 1
    }
    [[ "$SOURCE_DATE_EPOCH" =~ ^[1-9][0-9]*$ ]] || {
        echo "sourceDateEpoch must be a positive integer" >&2
        return 1
    }
    [[ "$IOS_MINIMUM_VERSION" =~ ^[0-9]+\.[0-9]+$ ]] || return 1
    [[ "$MACOS_MINIMUM_VERSION" =~ ^[0-9]+\.[0-9]+$ ]] || return 1
    assert_exact_value "Artifact name" "FFmpeg.xcframework.zip" "$ARTIFACT_NAME"
    assert_exact_value \
        "FFmpeg source URL" \
        "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz" \
        "$FFMPEG_URL"
    assert_exact_value \
        "FFmpeg signature URL" \
        "${FFMPEG_URL}.asc" \
        "$FFMPEG_SIGNATURE_URL"
    assert_exact_value \
        "dav1d source URL" \
        "https://code.videolan.org/videolan/dav1d/-/archive/${DAV1D_VERSION}/dav1d-${DAV1D_VERSION}.tar.bz2" \
        "$DAV1D_URL"

    SOURCE_CACHE_ROOT="${SWIFT_FFMPEG_SOURCE_CACHE_ROOT:-$PROJECT_ROOT/.cache/sources}"
    BUILD_ROOT="${SWIFT_FFMPEG_BUILD_ROOT:-$PROJECT_ROOT/.build/ffmpeg}"
    ARTIFACT_ROOT="${SWIFT_FFMPEG_ARTIFACT_ROOT:-$PROJECT_ROOT/.artifacts/release}"
    LOCAL_ARTIFACT_ROOT="$PROJECT_ROOT/Artifacts"
    FFMPEG_TARBALL="$SOURCE_CACHE_ROOT/ffmpeg-${FFMPEG_VERSION}.tar.xz"
    FFMPEG_SIGNATURE="$FFMPEG_TARBALL.asc"
    DAV1D_TARBALL="$SOURCE_CACHE_ROOT/dav1d-${DAV1D_VERSION}.tar.bz2"
    FFMPEG_RELEASE_KEY="$PROJECT_ROOT/Keys/ffmpeg-devel.asc"
    XCFRAMEWORK="$LOCAL_ARTIFACT_ROOT/FFmpeg.xcframework"
    RELEASE_ZIP="$ARTIFACT_ROOT/$ARTIFACT_NAME"
    EXPECTED_XCODE_VERSION="Xcode ${EXPECTED_XCODE_VERSION_VALUE}"$'\n'"Build version ${EXPECTED_XCODE_BUILD}"

    export \
        PROJECT_ROOT RELEASE_CONFIG PACKAGE_VERSION ARTIFACT_NAME \
        ARTIFACT_CHECKSUM EXPECTED_INFO_PLIST_SHA256 \
        EXPECTED_IOS_ARCHIVE_SHA256 EXPECTED_SIMULATOR_ARCHIVE_SHA256 \
        EXPECTED_MACOS_ARCHIVE_SHA256 SOURCE_DATE_EPOCH IOS_MINIMUM_VERSION \
        MACOS_MINIMUM_VERSION FFMPEG_VERSION FFMPEG_URL \
        FFMPEG_SIGNATURE_URL FFMPEG_SHA256 \
        FFMPEG_RELEASE_KEY_FINGERPRINT FFMPEG_RELEASE_KEY_SHA256 \
        DAV1D_VERSION DAV1D_URL DAV1D_SHA256 \
        SOURCE_CACHE_ROOT BUILD_ROOT ARTIFACT_ROOT LOCAL_ARTIFACT_ROOT \
        FFMPEG_TARBALL FFMPEG_SIGNATURE DAV1D_TARBALL FFMPEG_RELEASE_KEY \
        XCFRAMEWORK RELEASE_ZIP EXPECTED_XCODE_VERSION \
        EXPECTED_IPHONEOS_SDK_VERSION EXPECTED_IPHONESIMULATOR_SDK_VERSION \
        EXPECTED_MACOSX_SDK_VERSION EXPECTED_CLANG_VERSION \
        EXPECTED_CCTOOLS_VERSION EXPECTED_MESON_VERSION \
        EXPECTED_NINJA_VERSION EXPECTED_PKG_CONFIG_VERSION \
        EXPECTED_MAKE_VERSION
}
