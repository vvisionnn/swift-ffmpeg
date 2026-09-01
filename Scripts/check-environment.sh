#!/bin/bash -p

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
reject_shell_startup_environment
load_release_configuration

[[ "$(uname -s)" == "Darwin" ]] || {
    echo "XCFramework builds require macOS" >&2
    exit 1
}

for command_name in \
    clang curl gpg jq meson ninja pkg-config python3 swift xcodebuild xcrun
do
    require_command "$command_name"
done

for tool_path in \
    /usr/bin/ar \
    /usr/bin/awk \
    /usr/bin/find \
    /usr/bin/grep \
    /usr/bin/libtool \
    /usr/bin/lipo \
    /usr/bin/make \
    /usr/bin/nm \
    /usr/bin/otool \
    /usr/bin/patch \
    /usr/bin/plutil \
    /usr/bin/shasum \
    /usr/bin/sort \
    /usr/bin/strings \
    /usr/bin/tar \
    /usr/bin/true \
    /usr/bin/zip
do
    [[ -x "$tool_path" ]] || {
        echo "Missing required system tool: $tool_path" >&2
        exit 1
    }
done

assert_exact_value "Xcode" "$EXPECTED_XCODE_VERSION" "$(xcodebuild -version)"
assert_exact_value \
    "iPhoneOS SDK" \
    "$EXPECTED_IPHONEOS_SDK_VERSION" \
    "$(xcrun --sdk iphoneos --show-sdk-version)"
assert_exact_value \
    "iPhoneSimulator SDK" \
    "$EXPECTED_IPHONESIMULATOR_SDK_VERSION" \
    "$(xcrun --sdk iphonesimulator --show-sdk-version)"
assert_exact_value \
    "macOS SDK" \
    "$EXPECTED_MACOSX_SDK_VERSION" \
    "$(xcrun --sdk macosx --show-sdk-version)"

for sdk_name in iphoneos iphonesimulator macosx; do
    clang_path="$(xcrun --sdk "$sdk_name" --find clang)"
    clang_version="$("$clang_path" --version)"
    clang_version="${clang_version%%$'\n'*}"
    assert_exact_value \
        "Apple clang for $sdk_name" \
        "$EXPECTED_CLANG_VERSION" \
        "$clang_version"
done

cctools_version="$(/usr/bin/libtool -V 2>&1)"
cctools_version="${cctools_version%%$'\n'*}"
assert_exact_value "Apple cctools" "$EXPECTED_CCTOOLS_VERSION" "$cctools_version"
assert_exact_value "Meson" "$EXPECTED_MESON_VERSION" "$(meson --version)"
assert_exact_value "Ninja" "$EXPECTED_NINJA_VERSION" "$(ninja --version)"
assert_exact_value \
    "pkg-config" \
    "$EXPECTED_PKG_CONFIG_VERSION" \
    "$(pkg-config --version)"

make_version="$(/usr/bin/make --version)"
make_version="${make_version%%$'\n'*}"
assert_exact_value "Make" "$EXPECTED_MAKE_VERSION" "$make_version"

echo "Toolchain validated: Xcode $EXPECTED_XCODE_VERSION_VALUE ($EXPECTED_XCODE_BUILD)"
