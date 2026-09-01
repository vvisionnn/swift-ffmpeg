#!/bin/bash -p

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
reject_shell_startup_environment
load_release_configuration

OUTPUT_ROOT="$BUILD_ROOT/output"
STAGING_ROOT="$BUILD_ROOT/staging"
FRAMEWORK_ROOT="$LOCAL_ARTIFACT_ROOT"
XCFRAMEWORK="$FRAMEWORK_ROOT/FFmpeg.xcframework"
STAGED_XCFRAMEWORK="$STAGING_ROOT/FFmpeg.xcframework"
BUILD_JOBS="${FFMPEG_BUILD_JOBS:-8}"
DETERMINISTIC_AR_ABSOLUTE="$SCRIPT_DIR/build-xcframework.sh"

sanitize_build_environment() {
    unset \
        AR AS CC CPP CXX LD NM RANLIB STRIP \
        CFLAGS CPPFLAGS CXXFLAGS LDFLAGS ARCHFLAGS \
        CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH OBJC_INCLUDE_PATH LIBRARY_PATH \
        PKG_CONFIG_PATH PKG_CONFIG_DIR PKG_CONFIG_SYSROOT_DIR PKG_CONFIG_LIBDIR \
        PKG_CONFIG_SYSTEM_INCLUDE_PATH PKG_CONFIG_SYSTEM_LIBRARY_PATH \
        PKG_CONFIG_ALLOW_SYSTEM_CFLAGS PKG_CONFIG_ALLOW_SYSTEM_LIBS \
        SDKROOT MACOSX_DEPLOYMENT_TARGET IPHONEOS_DEPLOYMENT_TARGET \
        MAKEFLAGS MFLAGS DYLD_LIBRARY_PATH DYLD_FRAMEWORK_PATH \
        BASH_ENV ENV CDPATH

    export LANG=C
    export LC_ALL=C
    export TZ=UTC
    export SOURCE_DATE_EPOCH
    export ZERO_AR_DATE=1
    export COPYFILE_DISABLE=1
    umask 022

    if [[ ! "$BUILD_JOBS" =~ ^[1-9][0-9]*$ ]]; then
        echo "FFMPEG_BUILD_JOBS must be a positive integer" >&2
        exit 1
    fi
}

reset_build_path() {
    local path="$1"
    case "$path" in
        "$BUILD_ROOT"/*) /bin/rm -rf "$path" ;;
        *)
            echo "Refusing to reset a path outside the FFmpeg build root: $path" >&2
            exit 1
            ;;
    esac
}

reset_local_xcframework() {
    assert_exact_value \
        "Local XCFramework path" \
        "$PROJECT_ROOT/Artifacts/FFmpeg.xcframework" \
        "$XCFRAMEWORK"
    /bin/rm -rf "$XCFRAMEWORK"
}

create_deterministic_archive() {
    local flags="$1"
    local output="$2"
    shift 2
    local input
    local line=""
    local object
    local response_file
    local object_count=0
    local -a objects

    if [[ "$flags" != *r* ]]; then
        echo "Unsupported deterministic archive flags: $flags" >&2
        exit 1
    fi

    for input in "$@"; do
        if [[ "$input" == @* ]]; then
            response_file="${input#@}"
            while IFS= read -r line || [[ -n "$line" ]]; do
                for object in $line; do
                    objects[$object_count]="$object"
                    object_count=$((object_count + 1))
                done
            done <"$response_file"
        else
            objects[$object_count]="$input"
            object_count=$((object_count + 1))
        fi
    done

    if [[ "$object_count" -eq 0 ]]; then
        echo "Cannot create an empty deterministic archive: $output" >&2
        exit 1
    fi

    # Unlike ar, libtool's deterministic mode normalizes date, uid, gid, and
    # mode when it receives direct object paths. Component archives must be
    # created this way because libtool preserves metadata from nested archives.
    /usr/bin/libtool -static -D -o "$output" "${objects[@]}"
}

prepare_tarballs() {
    "$SCRIPT_DIR/verify-sources.sh"
}

build_dav1d_slice() {
    local name="$1"
    local sdk="$2"
    local triple="$3"
    local cpu_family="$4"
    local cpu="$5"
    local source_root="$BUILD_ROOT/source-dav1d-$name"
    local dav1d_build_root="$BUILD_ROOT/build-dav1d-$name"
    local install_root="$BUILD_ROOT/install/$name"
    local cross_file="$BUILD_ROOT/dav1d-$name.cross"
    local log_root="$BUILD_ROOT/logs"
    local sdk_path
    local compiler
    local stripper
    local enable_asm=true

    sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"
    compiler="$(xcrun --sdk "$sdk" --find clang)"
    stripper="$(xcrun --sdk "$sdk" --find strip)"

    # dav1d's x86 assembly is also emitted by NASM without LC_BUILD_VERSION.
    # Keep it enabled on ARM, where clang produces correctly tagged objects.
    if [[ "$cpu_family" == "x86_64" ]]; then
        enable_asm=false
    fi

    reset_build_path "$source_root"
    reset_build_path "$dav1d_build_root"
    reset_build_path "$install_root/dav1d"
    mkdir -p "$source_root" "$install_root" "$log_root"
    /usr/bin/tar -xjf "$DAV1D_TARBALL" -C "$source_root" --strip-components=1

    {
        echo "[binaries]"
        echo "c = '$compiler'"
        echo "ar = ['$DETERMINISTIC_AR_ABSOLUTE', '--deterministic-ar']"
        echo "ranlib = '/usr/bin/true'"
        echo "strip = '$stripper'"
        echo ""
        echo "[host_machine]"
        echo "system = 'darwin'"
        echo "cpu_family = '$cpu_family'"
        echo "cpu = '$cpu'"
        echo "endian = 'little'"
        echo ""
        echo "[properties]"
        echo "needs_exe_wrapper = true"
        echo ""
        echo "[built-in options]"
        echo "c_args = ['-target', '$triple', '-isysroot', '$sdk_path']"
        echo "c_link_args = ['-target', '$triple', '-isysroot', '$sdk_path']"
    } >"$cross_file"

    echo "Building dav1d for $name"
    meson setup "$dav1d_build_root" "$source_root" \
        --cross-file "$cross_file" \
        --wrap-mode=nodownload \
        --prefix=/dav1d \
        --libdir=lib \
        --buildtype=release \
        --default-library=static \
        -Db_staticpic=true \
        -Dbitdepths=8,16 \
        -Denable_asm="$enable_asm" \
        -Denable_tools=false \
        -Denable_tests=false \
        -Denable_examples=false \
        -Denable_docs=false \
        -Denable_seek_stress=false \
        -Dtestdata_tests=false \
        >"$log_root/meson-$name.log" 2>&1
    meson compile -C "$dav1d_build_root" --jobs "$BUILD_JOBS" \
        >"$log_root/dav1d-make-$name.log" 2>&1
    DESTDIR="$install_root" meson install -C "$dav1d_build_root" \
        >"$log_root/dav1d-install-$name.log" 2>&1
}

apply_ffmpeg_hardening_patch() {
    local source_root="$1"
    local patch_path

    for patch_path in "$PROJECT_ROOT"/Patches/*.patch; do
        [[ -f "$patch_path" ]] || {
            echo "No FFmpeg patches found under $PROJECT_ROOT/Patches" >&2
            exit 1
        }
        (
            cd "$source_root"
            /usr/bin/patch --batch --fuzz=0 -p1 <"$patch_path"
        )
    done

    if ! /usr/bin/grep -Fq '{.i64 = 8847360 }' "$source_root/libavcodec/options_table.h"; then
        echo "FFmpeg max_pixels hardening patch did not apply" >&2
        exit 1
    fi
    if ! /usr/bin/grep -Fq '{.i64 = 262144 }' "$source_root/libavcodec/options_table.h"; then
        echo "FFmpeg max_samples hardening patch did not apply" >&2
        exit 1
    fi
    if /usr/bin/grep -Fq 'SecIdentityCreate(' "$source_root/libavformat/tls_securetransport.c"; then
        echo "FFmpeg private SecIdentityCreate code is still present" >&2
        exit 1
    fi
    if ! /usr/bin/grep -Fq 'Modified by swift-ffmpeg on 2026-09-01' \
        "$source_root/libavcodec/options_table.h"; then
        echo "FFmpeg decoder-limit change notice is missing" >&2
        exit 1
    fi
    if ! /usr/bin/grep -Fq 'Modified by swift-ffmpeg on 2026-09-01' \
        "$source_root/libavformat/tls_securetransport.c"; then
        echo "FFmpeg SecureTransport change notice is missing" >&2
        exit 1
    fi
}

build_slice() {
    local name="$1"
    local sdk="$2"
    local triple="$3"
    local architecture="$4"
    local source_root="$BUILD_ROOT/source-$name"
    local install_root="$BUILD_ROOT/install/$name"
    local log_root="$BUILD_ROOT/logs"
    local sdk_path
    local architecture_flag="--enable-asm"

    sdk_path="$(xcrun --sdk "$sdk" --show-sdk-path)"

    # NASM emits x86_64 Mach-O objects without LC_BUILD_VERSION. Disabling
    # FFmpeg's x86 assembly keeps every archive member platform/minOS tagged.
    if [[ "$architecture" == "x86_64" ]]; then
        architecture_flag="--disable-x86asm"
    fi

    # Keep the dav1d sysroot installed by build_dav1d_slice. Only FFmpeg's
    # own source and destination are replaced during a slice rebuild.
    reset_build_path "$source_root"
    reset_build_path "$install_root/ffmpeg"
    mkdir -p "$source_root" "$install_root" "$log_root"
    /usr/bin/tar -xJf "$FFMPEG_TARBALL" -C "$source_root" --strip-components=1
    apply_ffmpeg_hardening_patch "$source_root"

    echo "Configuring FFmpeg for $name"
    (
        cd "$source_root"
        PKG_CONFIG_LIBDIR="$install_root/dav1d/lib/pkgconfig" \
        PKG_CONFIG_SYSROOT_DIR="$install_root" \
        ./configure \
            --prefix=/ffmpeg \
            --target-os=darwin \
            --arch="$architecture" \
            --enable-cross-compile \
            --cc=clang \
            --ar="$DETERMINISTIC_AR_ABSOLUTE --deterministic-ar" \
            --ranlib=true \
            --sysroot="$sdk_path" \
            --extra-cflags="-target $triple" \
            --extra-ldflags="-target $triple" \
            --disable-shared \
            --enable-static \
            --enable-pic \
            --disable-programs \
            --disable-doc \
            --disable-debug \
            --disable-avdevice \
            --disable-avfilter \
            --disable-encoders \
            --disable-muxers \
            --enable-muxer=spdif \
            --disable-autodetect \
            "$architecture_flag" \
            --pkg-config=pkg-config \
            --enable-libdav1d \
            --enable-network \
            --enable-securetransport \
            --enable-videotoolbox \
            --enable-audiotoolbox \
            --enable-zlib \
            --enable-bzlib \
            --enable-iconv \
            >"$log_root/configure-$name.log" 2>&1

        echo "Building FFmpeg for $name"
        /usr/bin/make -j"$BUILD_JOBS" >"$log_root/make-$name.log" 2>&1
        /usr/bin/make DESTDIR="$install_root" install >"$log_root/install-$name.log" 2>&1
    )
}

prepare_headers() {
    local name="$1"
    local include_root="$BUILD_ROOT/install/$name/ffmpeg/include"

    cp "$SCRIPT_DIR/support/FFmpeg.h" "$include_root/FFmpeg.h"
    cp "$SCRIPT_DIR/support/module.modulemap" "$include_root/module.modulemap"
}

merge_slice() {
    local name="$1"
    local library_root="$BUILD_ROOT/install/$name/ffmpeg/lib"
    local destination="$OUTPUT_ROOT/$name"
    local log_root="$BUILD_ROOT/logs"

    mkdir -p "$destination" "$log_root"
    /usr/bin/libtool -static -D -o "$destination/libFFmpeg.a" \
        "$library_root/libavformat.a" \
        "$library_root/libavcodec.a" \
        "$library_root/libswresample.a" \
        "$library_root/libswscale.a" \
        "$library_root/libavutil.a" \
        "$BUILD_ROOT/install/$name/dav1d/lib/libdav1d.a" \
        >"$log_root/libtool-$name.log" 2>&1
}

assert_archive_deterministic_metadata() {
    local archive="$1"
    local invalid_member

    invalid_member="$(/usr/bin/otool -a "$archive" | /usr/bin/awk '
        NR > 1 && ($1 != "0100644" || $2 != "0/0" ||
                   $4 !~ /^[0-9]+$/ || $4 > 65535) { print; exit }
    ')"
    if [[ -n "$invalid_member" ]]; then
        echo "Archive contains nondeterministic member metadata: $archive" >&2
        echo "$invalid_member" >&2
        exit 1
    fi
}

assert_thin_slice() {
    local name="$1"
    local architecture="$2"
    local expected_platform="$3"
    local expected_minos="$4"
    local archive="$OUTPUT_ROOT/$name/libFFmpeg.a"
    local metadata_log="$BUILD_ROOT/logs/otool-$name.log"
    local metadata_counts
    local actual_architectures

    actual_architectures="$(/usr/bin/lipo -archs "$archive")"
    if [[ "$actual_architectures" != "$architecture" ]]; then
        echo "$name architecture mismatch: expected $architecture, got $actual_architectures" >&2
        exit 1
    fi

    /usr/bin/otool -l "$archive" >"$metadata_log"
    metadata_counts="$(/usr/bin/awk \
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
    ' "$metadata_log")"
    set -- $metadata_counts
    if [[ "$1" -eq 0 || "$1" -ne "$2" || "$1" -ne "$3" ]]; then
        echo "$name has incomplete or incorrect LC_BUILD_VERSION metadata" >&2
        echo "Mach-O members=$1 build_versions=$2 matching=$3" >&2
        exit 1
    fi

    assert_archive_deterministic_metadata "$archive"
}

assert_archive_symbols() {
    local label="$1"
    local archive="$2"
    shift 2
    local architecture
    local nm_log
    local config_log="$BUILD_ROOT/logs/strings-$label.log"
    local registered_muxers
    local required_flag

    for architecture in "$@"; do
        nm_log="$BUILD_ROOT/logs/nm-$label-$architecture.log"
        /usr/bin/nm -arch "$architecture" "$archive" >"$nm_log"
        if /usr/bin/grep -Eq '(^|[[:space:]])_SecIdentityCreate$' "$nm_log"; then
            echo "$label/$architecture references forbidden private symbol _SecIdentityCreate" >&2
            exit 1
        fi
        if ! /usr/bin/grep -Eq '(^|[[:space:]])_dav1d_open$' "$nm_log"; then
            echo "$label/$architecture is missing required symbol _dav1d_open" >&2
            exit 1
        fi
        if ! /usr/bin/grep -Eq '(^|[[:space:]])_ff_libdav1d_decoder$' "$nm_log"; then
            echo "$label/$architecture did not register FFmpeg's libdav1d decoder" >&2
            exit 1
        fi
        if ! /usr/bin/grep -Eq '(^|[[:space:]])_avcodec_alloc_context3$' "$nm_log"; then
            echo "$label/$architecture is missing required FFmpeg symbols" >&2
            exit 1
        fi
        registered_muxers="$(
            /usr/bin/awk '$NF ~ /^_ff_.*_muxer$/ { print $NF }' "$nm_log" |
                LC_ALL=C /usr/bin/sort -u
        )"
        if [[ "$registered_muxers" != "_ff_spdif_muxer" ]]; then
            echo "$label/$architecture muxer registration mismatch" >&2
            echo "Expected: _ff_spdif_muxer" >&2
            echo "Actual:   ${registered_muxers:-<none>}" >&2
            exit 1
        fi
    done

    /usr/bin/strings "$archive" >"$config_log"
    for required_flag in \
        --enable-libdav1d --disable-shared --enable-static \
        --disable-encoders --disable-muxers --enable-muxer=spdif
    do
        if ! /usr/bin/grep -Fq -- "$required_flag" "$config_log"; then
            echo "$label configuration is missing required flag $required_flag" >&2
            exit 1
        fi
    done
    if /usr/bin/grep -Eq -- '--enable-(gpl|nonfree|version3)([[:space:]]|$)' "$config_log"; then
        echo "$label contains a forbidden GPL, nonfree, or version3 configuration flag" >&2
        exit 1
    fi
}

assert_matching_headers() {
    local first="$BUILD_ROOT/install/ios-arm64/ffmpeg/include"
    local candidate
    local first_hashes
    local candidate_hashes

    first_hashes="$(
        cd "$first"
        /usr/bin/find . -type f -print | LC_ALL=C /usr/bin/sort | while IFS= read -r header; do
            /usr/bin/shasum -a 256 "$header"
        done
    )"

    for candidate in \
        "$BUILD_ROOT/install/ios-simulator-arm64/ffmpeg/include" \
        "$BUILD_ROOT/install/ios-simulator-x86_64/ffmpeg/include" \
        "$BUILD_ROOT/install/macos-arm64/ffmpeg/include" \
        "$BUILD_ROOT/install/macos-x86_64/ffmpeg/include"
    do
        candidate_hashes="$(
            cd "$candidate"
            /usr/bin/find . -type f -print | LC_ALL=C /usr/bin/sort | while IFS= read -r header; do
                /usr/bin/shasum -a 256 "$header"
            done
        )"
        if [[ "$candidate_hashes" != "$first_hashes" ]]; then
            echo "Installed FFmpeg headers differ between slices: $first and $candidate" >&2
            exit 1
        fi
    done
}

write_toolchain_manifest() {
    mkdir -p "$BUILD_ROOT/logs"
    {
        echo "DEVELOPER_DIR=${DEVELOPER_DIR:-$(/usr/bin/xcode-select -p)}"
        xcodebuild -version
        echo "iphoneos SDK $(xcrun --sdk iphoneos --show-sdk-version)"
        echo "iphonesimulator SDK $(xcrun --sdk iphonesimulator --show-sdk-version)"
        echo "macosx SDK $(xcrun --sdk macosx --show-sdk-version)"
        xcrun clang --version | /usr/bin/awk 'NR == 1'
        /usr/bin/libtool -V 2>&1
        echo "Meson $(meson --version)"
        echo "Ninja $(ninja --version)"
        echo "pkg-config $(pkg-config --version)"
        /usr/bin/make --version | /usr/bin/awk 'NR == 1'
        echo "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH"
    } >"$BUILD_ROOT/logs/toolchain.txt"
}

canonicalize_xcframework_info() {
    local info_plist="$1"

    # xcodebuild may emit AvailableLibraries in a different order for identical
    # inputs. Replace only that array with the fixed package order so repeated
    # XCFramework creation produces a byte-identical Info.plist.
    /usr/bin/plutil -replace AvailableLibraries -json '[
      {
        "BinaryPath": "libFFmpeg.a",
        "HeadersPath": "Headers",
        "LibraryIdentifier": "ios-arm64",
        "LibraryPath": "libFFmpeg.a",
        "SupportedArchitectures": ["arm64"],
        "SupportedPlatform": "ios"
      },
      {
        "BinaryPath": "libFFmpeg.a",
        "HeadersPath": "Headers",
        "LibraryIdentifier": "ios-arm64_x86_64-simulator",
        "LibraryPath": "libFFmpeg.a",
        "SupportedArchitectures": ["arm64", "x86_64"],
        "SupportedPlatform": "ios",
        "SupportedPlatformVariant": "simulator"
      },
      {
        "BinaryPath": "libFFmpeg.a",
        "HeadersPath": "Headers",
        "LibraryIdentifier": "macos-arm64_x86_64",
        "LibraryPath": "libFFmpeg.a",
        "SupportedArchitectures": ["arm64", "x86_64"],
        "SupportedPlatform": "macos"
      }
    ]' "$info_plist"
}

package_xcframework() {
    reset_build_path "$OUTPUT_ROOT"
    reset_build_path "$STAGING_ROOT"
    mkdir -p "$OUTPUT_ROOT" "$STAGING_ROOT" "$FRAMEWORK_ROOT"

    prepare_headers ios-arm64
    merge_slice ios-arm64
    assert_thin_slice ios-arm64 arm64 2 "$IOS_MINIMUM_VERSION"

    prepare_headers ios-simulator-arm64
    merge_slice ios-simulator-arm64
    assert_thin_slice ios-simulator-arm64 arm64 7 "$IOS_MINIMUM_VERSION"

    prepare_headers ios-simulator-x86_64
    merge_slice ios-simulator-x86_64
    assert_thin_slice ios-simulator-x86_64 x86_64 7 "$IOS_MINIMUM_VERSION"

    prepare_headers macos-arm64
    merge_slice macos-arm64
    assert_thin_slice macos-arm64 arm64 1 "$MACOS_MINIMUM_VERSION"

    prepare_headers macos-x86_64
    merge_slice macos-x86_64
    assert_thin_slice macos-x86_64 x86_64 1 "$MACOS_MINIMUM_VERSION"

    assert_matching_headers

    mkdir -p "$OUTPUT_ROOT/ios-simulator-universal" "$OUTPUT_ROOT/macos-universal"
    /usr/bin/lipo -create \
        "$OUTPUT_ROOT/ios-simulator-arm64/libFFmpeg.a" \
        "$OUTPUT_ROOT/ios-simulator-x86_64/libFFmpeg.a" \
        -output "$OUTPUT_ROOT/ios-simulator-universal/libFFmpeg.a"
    /usr/bin/lipo -create \
        "$OUTPUT_ROOT/macos-arm64/libFFmpeg.a" \
        "$OUTPUT_ROOT/macos-x86_64/libFFmpeg.a" \
        -output "$OUTPUT_ROOT/macos-universal/libFFmpeg.a"

    assert_archive_symbols ios-device "$OUTPUT_ROOT/ios-arm64/libFFmpeg.a" arm64
    assert_archive_symbols ios-simulator-arm64 "$OUTPUT_ROOT/ios-simulator-arm64/libFFmpeg.a" arm64
    assert_archive_symbols ios-simulator-x86_64 "$OUTPUT_ROOT/ios-simulator-x86_64/libFFmpeg.a" x86_64
    assert_archive_symbols macos-arm64 "$OUTPUT_ROOT/macos-arm64/libFFmpeg.a" arm64
    assert_archive_symbols macos-x86_64 "$OUTPUT_ROOT/macos-x86_64/libFFmpeg.a" x86_64

    xcodebuild -create-xcframework \
        -library "$OUTPUT_ROOT/ios-arm64/libFFmpeg.a" \
        -headers "$BUILD_ROOT/install/ios-arm64/ffmpeg/include" \
        -library "$OUTPUT_ROOT/ios-simulator-universal/libFFmpeg.a" \
        -headers "$BUILD_ROOT/install/ios-simulator-arm64/ffmpeg/include" \
        -library "$OUTPUT_ROOT/macos-universal/libFFmpeg.a" \
        -headers "$BUILD_ROOT/install/macos-arm64/ffmpeg/include" \
        -output "$STAGED_XCFRAMEWORK"

    canonicalize_xcframework_info "$STAGED_XCFRAMEWORK/Info.plist"
    /usr/bin/plutil -lint "$STAGED_XCFRAMEWORK/Info.plist" >/dev/null
    assert_exact_value "iOS device XCFramework architectures" "arm64" \
        "$(/usr/bin/lipo -archs "$STAGED_XCFRAMEWORK/ios-arm64/libFFmpeg.a")"
    assert_exact_value "iOS Simulator XCFramework architectures" "x86_64 arm64" \
        "$(/usr/bin/lipo -archs "$STAGED_XCFRAMEWORK/ios-arm64_x86_64-simulator/libFFmpeg.a")"
    assert_exact_value "macOS XCFramework architectures" "x86_64 arm64" \
        "$(/usr/bin/lipo -archs "$STAGED_XCFRAMEWORK/macos-arm64_x86_64/libFFmpeg.a")"

    reset_local_xcframework
    mv "$STAGED_XCFRAMEWORK" "$XCFRAMEWORK"
}

if [[ "${1:-}" == "--deterministic-ar" ]]; then
    shift
    case "${1:-}" in
        --version)
            echo "swift-ffmpeg deterministic ar 1.0"
            exit 0
            ;;
        -h)
            echo "usage: deterministic-ar [csr] archive object ..."
            exit 0
            ;;
    esac
    create_deterministic_archive "$@"
    exit 0
fi

if [[ "${1:-}" == "--package-only" ]]; then
    sanitize_build_environment
    "$SCRIPT_DIR/check-environment.sh"
    prepare_tarballs
    write_toolchain_manifest
    package_xcframework
    echo "Created $XCFRAMEWORK"
    exit 0
fi

sanitize_build_environment
"$SCRIPT_DIR/check-environment.sh"
prepare_tarballs
write_toolchain_manifest
build_dav1d_slice ios-arm64 iphoneos "arm64-apple-ios$IOS_MINIMUM_VERSION" aarch64 arm64
build_slice ios-arm64 iphoneos "arm64-apple-ios$IOS_MINIMUM_VERSION" arm64
build_dav1d_slice ios-simulator-arm64 iphonesimulator "arm64-apple-ios$IOS_MINIMUM_VERSION-simulator" aarch64 arm64
build_slice ios-simulator-arm64 iphonesimulator "arm64-apple-ios$IOS_MINIMUM_VERSION-simulator" arm64
build_dav1d_slice ios-simulator-x86_64 iphonesimulator "x86_64-apple-ios$IOS_MINIMUM_VERSION-simulator" x86_64 x86_64
build_slice ios-simulator-x86_64 iphonesimulator "x86_64-apple-ios$IOS_MINIMUM_VERSION-simulator" x86_64
build_dav1d_slice macos-arm64 macosx "arm64-apple-macos$MACOS_MINIMUM_VERSION" aarch64 arm64
build_slice macos-arm64 macosx "arm64-apple-macos$MACOS_MINIMUM_VERSION" arm64
build_dav1d_slice macos-x86_64 macosx "x86_64-apple-macos$MACOS_MINIMUM_VERSION" x86_64 x86_64
build_slice macos-x86_64 macosx "x86_64-apple-macos$MACOS_MINIMUM_VERSION" x86_64
package_xcframework

echo "Created $XCFRAMEWORK"
