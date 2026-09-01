#!/bin/bash -p

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
reject_shell_startup_environment
load_release_configuration

VALIDATION_TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/swift-ffmpeg-validation.XXXXXX")"
trap '/bin/rm -rf "$VALIDATION_TEMP_ROOT"' EXIT

assert_architectures() {
    local archive="$1"
    local expected="$2"
    local actual
    actual="$(
        /usr/bin/lipo -archs "$archive" |
            /usr/bin/tr ' ' '\n' |
            LC_ALL=C /usr/bin/sort |
            /usr/bin/xargs
    )"
    assert_exact_value "Architectures for $archive" "$expected" "$actual"
}

assert_platform_metadata() {
    local archive="$1"
    local expected_platform="$2"
    local expected_minos="$3"
    local metadata_counts

    metadata_counts="$(
        /usr/bin/otool -l "$archive" |
            /usr/bin/awk \
                -v expected_platform="$expected_platform" \
                -v expected_minos="$expected_minos" '
                    /^[^[:space:]].*\):$/ { members++ }
                    /cmd LC_BUILD_VERSION/ {
                        versions++
                        getline
                        getline
                        platform = $2
                        getline
                        minos = $2
                        getline
                        if (platform == expected_platform && minos == expected_minos)
                            matching++
                    }
                    END { print members + 0, versions + 0, matching + 0 }
                '
    )"
    set -- $metadata_counts
    if [[ "$1" -eq 0 || "$1" -ne "$2" || "$1" -ne "$3" ]]; then
        echo "Incorrect LC_BUILD_VERSION metadata in $archive" >&2
        echo "Mach-O members=$1 build_versions=$2 matching=$3" >&2
        exit 1
    fi
}

assert_deterministic_archive_metadata() {
    local archive="$1"
    shift
    local architecture
    local invalid_member
    local metadata_archive
    local temporary_archive

    for architecture in "$@"; do
        metadata_archive="$archive"
        temporary_archive=""
        if [[ "$#" -gt 1 ]]; then
            temporary_archive="$(mktemp "${TMPDIR:-/tmp}/swift-ffmpeg-archive.XXXXXX")"
            /usr/bin/lipo "$archive" -thin "$architecture" \
                -output "$temporary_archive"
            metadata_archive="$temporary_archive"
        fi
        invalid_member="$(
            /usr/bin/otool -a "$metadata_archive" |
                /usr/bin/awk '
                    NR > 1 && ($1 != "0100644" || $2 != "0/0" ||
                               $4 !~ /^[0-9]+$/ || $4 > 65535) { print; exit }
                '
        )"
        if [[ -n "$temporary_archive" ]]; then
            /bin/rm -f "$temporary_archive"
        fi
        [[ -z "$invalid_member" ]] || {
            echo "Nondeterministic archive metadata in $archive/$architecture" >&2
            echo "$invalid_member" >&2
            exit 1
        }
    done
}

assert_symbols_and_configuration() {
    local label="$1"
    local archive="$2"
    shift 2
    local architecture
    local nm_output
    local registered_muxers
    local strings_output
    local required_flag
    local thin_archive
    local architecture_count

    for architecture in "$@"; do
        nm_output="$VALIDATION_TEMP_ROOT/nm-$label-$architecture.txt"
        /usr/bin/nm -arch "$architecture" "$archive" >"$nm_output"
        if /usr/bin/grep -Eq '(^|[[:space:]])_SecIdentityCreate$' "$nm_output"; then
            echo "$label/$architecture references private _SecIdentityCreate" >&2
            exit 1
        fi
        for symbol in _dav1d_open _ff_libdav1d_decoder _avcodec_alloc_context3; do
            /usr/bin/grep -Eq "(^|[[:space:]])${symbol}$" "$nm_output" || {
                echo "$label/$architecture is missing $symbol" >&2
                exit 1
            }
        done
        registered_muxers="$(
            /usr/bin/awk '$NF ~ /^_ff_.*_muxer$/ { print $NF }' "$nm_output" |
                LC_ALL=C /usr/bin/sort -u
        )"
        assert_exact_value \
            "$label/$architecture registered muxers" \
            "_ff_spdif_muxer" \
            "$registered_muxers"

        architecture_count="$(/usr/bin/lipo -archs "$archive" | /usr/bin/wc -w | /usr/bin/xargs)"
        thin_archive="$archive"
        if [[ "$architecture_count" -gt 1 ]]; then
            thin_archive="$VALIDATION_TEMP_ROOT/$label-$architecture.a"
            /usr/bin/lipo "$archive" -thin "$architecture" -output "$thin_archive"
        fi
        strings_output="$VALIDATION_TEMP_ROOT/strings-$label-$architecture.txt"
        /usr/bin/strings "$thin_archive" >"$strings_output"
        for required_flag in \
            --enable-libdav1d \
            --disable-shared \
            --enable-static \
            --disable-encoders \
            --disable-muxers \
            --enable-muxer=spdif \
            --disable-autodetect \
            --cc=apple-clang \
            --cxx=apple-clang++ \
            --sysroot=apple-sdk \
            "--ar='swift-ffmpeg-deterministic-ar --deterministic-ar'"
        do
            /usr/bin/grep -Fq -- "$required_flag" "$strings_output" || {
                echo "$label/$architecture configuration is missing $required_flag" >&2
                exit 1
            }
        done
        if /usr/bin/grep -Eq \
            -- "--(cc|cxx|ar|sysroot)=('?/|\"?/)" \
            "$strings_output"; then
            echo "$label/$architecture configuration leaks a host-specific tool or SDK path" >&2
            exit 1
        fi
        if /usr/bin/grep -Eq \
            -- '--enable-(gpl|nonfree|version3)([[:space:]]|$)' \
            "$strings_output"; then
            echo "$label/$architecture contains a forbidden license configuration" >&2
            exit 1
        fi
    done
}

assert_matching_headers() {
    local first="$XCFRAMEWORK/ios-arm64/Headers"
    local candidate
    local first_hashes
    local candidate_hashes

    first_hashes="$(
        cd "$first"
        /usr/bin/find . -type f -print | LC_ALL=C /usr/bin/sort |
            while IFS= read -r header; do
                /usr/bin/shasum -a 256 "$header"
            done
    )"
    for candidate in \
        "$XCFRAMEWORK/ios-arm64_x86_64-simulator/Headers" \
        "$XCFRAMEWORK/macos-arm64_x86_64/Headers"
    do
        candidate_hashes="$(
            cd "$candidate"
            /usr/bin/find . -type f -print | LC_ALL=C /usr/bin/sort |
                while IFS= read -r header; do
                    /usr/bin/shasum -a 256 "$header"
                done
        )"
        assert_exact_value "XCFramework slice headers" "$first_hashes" "$candidate_hashes"
    done

    /usr/bin/cmp -s "$first/FFmpeg.h" "$SCRIPT_DIR/support/FFmpeg.h" || {
        echo "Packaged FFmpeg umbrella header differs from the reviewed source" >&2
        exit 1
    }
    /usr/bin/cmp -s "$first/module.modulemap" "$SCRIPT_DIR/support/module.modulemap" || {
        echo "Packaged FFmpeg module map differs from the reviewed source" >&2
        exit 1
    }
}

assert_release_manifest() {
    local release_url
    local remote_manifest
    local local_manifest
    release_url="https://github.com/vvisionnn/swift-ffmpeg/releases/download/${PACKAGE_VERSION}/${ARTIFACT_NAME}"
    remote_manifest="$VALIDATION_TEMP_ROOT/package-remote.json"
    local_manifest="$VALIDATION_TEMP_ROOT/package-local.json"
    (
        cd "$PROJECT_ROOT"
        env -u SWIFT_FFMPEG_USE_LOCAL_XCFRAMEWORK \
            swift package dump-package >"$remote_manifest"
        SWIFT_FFMPEG_USE_LOCAL_XCFRAMEWORK=1 \
            swift package dump-package >"$local_manifest"
    )
    jq -e \
        --arg url "$release_url" \
        --arg checksum "$ARTIFACT_CHECKSUM" '
            ([.targets[] | select(.name == "FFmpeg")] | length) == 1 and
            ([.targets[] | select(
                .name == "FFmpeg" and
                .type == "binary" and
                .url == $url and
                .checksum == $checksum and
                (has("path") | not)
            )] | length) == 1 and
            ([.products[] | select(
                .name == "FFmpeg" and
                .type.library != null and
                .targets == ["FFmpeg", "FFmpegLinkerSupport"]
            )] | length) == 1
        ' "$remote_manifest" >/dev/null || {
        echo "Remote Package.swift FFmpeg product/target does not match release.json" >&2
        exit 1
    }
    jq -e '
            ([.targets[] | select(.name == "FFmpeg")] | length) == 1 and
            ([.targets[] | select(
                .name == "FFmpeg" and
                .type == "binary" and
                .path == "Artifacts/FFmpeg.xcframework" and
                (has("url") | not) and
                (has("checksum") | not)
            )] | length) == 1
        ' "$local_manifest" >/dev/null || {
        echo "Local Package.swift mode does not select the reviewed XCFramework path" >&2
        exit 1
    }
}

[[ -d "$XCFRAMEWORK" ]] || {
    echo "Missing local XCFramework: $XCFRAMEWORK" >&2
    exit 1
}
/usr/bin/plutil -lint "$XCFRAMEWORK/Info.plist" >/dev/null

expected_libraries='[{"BinaryPath":"libFFmpeg.a","HeadersPath":"Headers","LibraryIdentifier":"ios-arm64","LibraryPath":"libFFmpeg.a","SupportedArchitectures":["arm64"],"SupportedPlatform":"ios"},{"BinaryPath":"libFFmpeg.a","HeadersPath":"Headers","LibraryIdentifier":"ios-arm64_x86_64-simulator","LibraryPath":"libFFmpeg.a","SupportedArchitectures":["arm64","x86_64"],"SupportedPlatform":"ios","SupportedPlatformVariant":"simulator"},{"BinaryPath":"libFFmpeg.a","HeadersPath":"Headers","LibraryIdentifier":"macos-arm64_x86_64","LibraryPath":"libFFmpeg.a","SupportedArchitectures":["arm64","x86_64"],"SupportedPlatform":"macos"}]'
actual_libraries="$(
    /usr/bin/plutil -extract AvailableLibraries json -o - "$XCFRAMEWORK/Info.plist" |
        jq -cS 'sort_by(.LibraryIdentifier)'
)"
expected_libraries="$(printf '%s' "$expected_libraries" | jq -cS 'sort_by(.LibraryIdentifier)')"
assert_exact_value "XCFramework variants" "$expected_libraries" "$actual_libraries"

ios_archive="$XCFRAMEWORK/ios-arm64/libFFmpeg.a"
simulator_archive="$XCFRAMEWORK/ios-arm64_x86_64-simulator/libFFmpeg.a"
macos_archive="$XCFRAMEWORK/macos-arm64_x86_64/libFFmpeg.a"
for archive in "$ios_archive" "$simulator_archive" "$macos_archive"; do
    [[ -f "$archive" ]] || {
        echo "Missing FFmpeg archive: $archive" >&2
        exit 1
    }
done

assert_deterministic_archive_metadata "$ios_archive" arm64
assert_deterministic_archive_metadata "$simulator_archive" arm64 x86_64
assert_deterministic_archive_metadata "$macos_archive" arm64 x86_64

verify_sha256 "$XCFRAMEWORK/Info.plist" "$EXPECTED_INFO_PLIST_SHA256" "XCFramework Info.plist"
verify_sha256 "$ios_archive" "$EXPECTED_IOS_ARCHIVE_SHA256" "iOS FFmpeg archive"
verify_sha256 "$simulator_archive" "$EXPECTED_SIMULATOR_ARCHIVE_SHA256" "Simulator FFmpeg archive"
verify_sha256 "$macos_archive" "$EXPECTED_MACOS_ARCHIVE_SHA256" "macOS FFmpeg archive"

assert_architectures "$ios_archive" "arm64"
assert_architectures "$simulator_archive" "arm64 x86_64"
assert_architectures "$macos_archive" "arm64 x86_64"
assert_platform_metadata "$ios_archive" 2 "$IOS_MINIMUM_VERSION"
assert_platform_metadata "$simulator_archive" 7 "$IOS_MINIMUM_VERSION"
assert_platform_metadata "$macos_archive" 1 "$MACOS_MINIMUM_VERSION"
assert_symbols_and_configuration ios "$ios_archive" arm64
assert_symbols_and_configuration simulator "$simulator_archive" arm64 x86_64
assert_symbols_and_configuration macos "$macos_archive" arm64 x86_64
assert_matching_headers
assert_release_manifest
/usr/bin/plutil -lint \
    "$PROJECT_ROOT/Sources/FFmpegLinkerSupport/PrivacyInfo.xcprivacy" >/dev/null

if [[ -f "$RELEASE_ZIP" ]]; then
    verify_sha256 "$RELEASE_ZIP" "$ARTIFACT_CHECKSUM" "Release ZIP"
    archive_entries="$(/usr/bin/unzip -Z1 "$RELEASE_ZIP")"
    [[ -n "$archive_entries" ]] || {
        echo "Release ZIP is empty" >&2
        exit 1
    }
    while IFS= read -r entry; do
        case "$entry" in
            FFmpeg.xcframework|FFmpeg.xcframework/*) ;;
            *)
                echo "Unexpected release ZIP entry: $entry" >&2
                exit 1
                ;;
        esac
        case "/$entry/" in
            */../*|*/./*)
                echo "Unsafe release ZIP entry: $entry" >&2
                exit 1
                ;;
        esac
    done <<<"$archive_entries"
fi

"$SCRIPT_DIR/test-capabilities.sh"
echo "Validated FFmpeg $FFMPEG_VERSION artifact for package $PACKAGE_VERSION"
