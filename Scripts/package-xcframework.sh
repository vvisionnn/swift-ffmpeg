#!/bin/bash -p

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
reject_shell_startup_environment
load_release_configuration

reset_artifact_path() {
    local path="$1"
    case "$path" in
        "$ARTIFACT_ROOT"/*) /bin/rm -rf "$path" ;;
        *)
            echo "Refusing to reset a path outside the artifact root: $path" >&2
            exit 1
            ;;
    esac
}

[[ -d "$XCFRAMEWORK" ]] || {
    echo "Missing local XCFramework: $XCFRAMEWORK" >&2
    exit 1
}

mkdir -p "$ARTIFACT_ROOT"
staging_root="$ARTIFACT_ROOT/.package-$PACKAGE_VERSION"
staged_framework="$staging_root/FFmpeg.xcframework"
temporary_zip="$ARTIFACT_ROOT/.${ARTIFACT_NAME}.tmp.zip"
reset_artifact_path "$staging_root"
reset_artifact_path "$temporary_zip"
mkdir -p "$staging_root"
COPYFILE_DISABLE=1 /usr/bin/ditto "$XCFRAMEWORK" "$staged_framework"
/usr/bin/xattr -cr "$staged_framework"

archive_timestamp="$(
    TZ=UTC /bin/date -r "$SOURCE_DATE_EPOCH" '+%Y%m%d%H%M.%S'
)"
/usr/bin/find "$staged_framework" -type d -exec /bin/chmod 0755 {} +
/usr/bin/find "$staged_framework" -type f -exec /bin/chmod 0644 {} +
/usr/bin/find "$staged_framework" \
    -exec /usr/bin/touch -h -t "$archive_timestamp" {} +

(
    cd "$staging_root"
    /usr/bin/find FFmpeg.xcframework -print |
        LC_ALL=C /usr/bin/sort |
        COPYFILE_DISABLE=1 /usr/bin/zip -X -q "$temporary_zip" -@
)

actual_checksum="$(swift package compute-checksum "$temporary_zip")"
assert_exact_value \
    "SwiftPM release ZIP checksum" \
    "$ARTIFACT_CHECKSUM" \
    "$actual_checksum"
reset_artifact_path "$RELEASE_ZIP"
/bin/mv "$temporary_zip" "$RELEASE_ZIP"
printf '%s  %s\n' "$actual_checksum" "$ARTIFACT_NAME" \
    >"$ARTIFACT_ROOT/SHA256SUMS"
reset_artifact_path "$staging_root"

"$SCRIPT_DIR/validate-artifact.sh"
echo "Packaged $RELEASE_ZIP"
