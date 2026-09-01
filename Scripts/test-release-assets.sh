#!/bin/bash -p

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
reject_shell_startup_environment
load_release_configuration

require_command python3

SOURCE_KIT_NAME="swift-ffmpeg-${PACKAGE_VERSION}-source-kit.zip"
SBOM_NAME="swift-ffmpeg-${PACKAGE_VERSION}.spdx.json"

"$SCRIPT_DIR/prepare-release-assets.sh"

first_snapshot="$(
    for asset_name in \
        "$ARTIFACT_NAME" \
        SHA256SUMS \
        release-manifest.json \
        release-metrics.json \
        "$SOURCE_KIT_NAME" \
        "$SBOM_NAME"
    do
        printf '%s  %s\n' \
            "$(sha256_file "$ARTIFACT_ROOT/$asset_name")" \
            "$asset_name"
    done
)"

"$SCRIPT_DIR/prepare-release-assets.sh"

second_snapshot="$(
    for asset_name in \
        "$ARTIFACT_NAME" \
        SHA256SUMS \
        release-manifest.json \
        release-metrics.json \
        "$SOURCE_KIT_NAME" \
        "$SBOM_NAME"
    do
        printf '%s  %s\n' \
            "$(sha256_file "$ARTIFACT_ROOT/$asset_name")" \
            "$asset_name"
    done
)"
assert_exact_value \
    "Repeated release-asset generation" \
    "$first_snapshot" \
    "$second_snapshot"

negative_root="$(mktemp -d "$ARTIFACT_ROOT/.release-assets-test.XXXXXX")"
cleanup() {
    case "$negative_root" in
        "$ARTIFACT_ROOT"/.release-assets-test.*)
            /bin/rm -rf "$negative_root"
            ;;
        *)
            echo "Refusing to remove unexpected test path: $negative_root" >&2
            ;;
    esac
}
trap cleanup EXIT

for asset_name in \
    "$ARTIFACT_NAME" \
    SHA256SUMS \
    release-manifest.json \
    release-metrics.json \
    "$SOURCE_KIT_NAME" \
    "$SBOM_NAME"
do
    COPYFILE_DISABLE=1 /bin/cp \
        "$ARTIFACT_ROOT/$asset_name" \
        "$negative_root/$asset_name"
done

python3 - "$negative_root/$SOURCE_KIT_NAME" <<'PYTHON'
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1], "w") as archive:
    archive.writestr("../escape", b"unsafe")
PYTHON

negative_log="$negative_root/negative.log"
if SWIFT_FFMPEG_ARTIFACT_ROOT="$negative_root" \
    "$SCRIPT_DIR/verify-release-assets.sh" >"$negative_log" 2>&1
then
    echo "Release verification accepted an unsafe source-kit archive" >&2
    exit 1
fi
/usr/bin/grep -E \
    'unsafe entry|escapes its expected root|path traversal' \
    "$negative_log" >/dev/null || {
        echo "Unsafe source-kit test failed for an unexpected reason" >&2
        /bin/cat "$negative_log" >&2
        exit 1
    }

echo "Release assets are deterministic and unsafe archives are rejected"
