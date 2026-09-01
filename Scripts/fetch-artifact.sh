#!/bin/bash -p

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
reject_shell_startup_environment
load_release_configuration

if [[ -d "$XCFRAMEWORK" ]]; then
    echo "Using local XCFramework: $XCFRAMEWORK"
    exit 0
fi

mkdir -p "$ARTIFACT_ROOT" "$LOCAL_ARTIFACT_ROOT"
downloaded_zip="$ARTIFACT_ROOT/downloaded-$ARTIFACT_NAME"
temporary_zip="$downloaded_zip.tmp.zip"
release_url="https://github.com/vvisionnn/swift-ffmpeg/releases/download/${PACKAGE_VERSION}/${ARTIFACT_NAME}"
/bin/rm -f "$temporary_zip"
curl \
    --fail \
    --show-error \
    --silent \
    --location \
    --proto '=https' \
    --proto-redir '=https' \
    --retry 3 \
    --retry-all-errors \
    --connect-timeout 20 \
    --max-time 900 \
    --output "$temporary_zip" \
    "$release_url"
verify_sha256 "$temporary_zip" "$ARTIFACT_CHECKSUM" "Downloaded release ZIP"
/bin/mv "$temporary_zip" "$downloaded_zip"

archive_entries="$(/usr/bin/unzip -Z1 "$downloaded_zip")"
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

staging_root="$ARTIFACT_ROOT/downloaded-$PACKAGE_VERSION"
/bin/rm -rf "$staging_root"
mkdir -p "$staging_root"
/usr/bin/unzip -q "$downloaded_zip" -d "$staging_root"
[[ -d "$staging_root/FFmpeg.xcframework" ]] || {
    echo "Downloaded archive did not contain FFmpeg.xcframework" >&2
    exit 1
}
/bin/mv "$staging_root/FFmpeg.xcframework" "$XCFRAMEWORK"
/bin/rmdir "$staging_root"

"$SCRIPT_DIR/validate-artifact.sh"
echo "Downloaded and validated $release_url"
