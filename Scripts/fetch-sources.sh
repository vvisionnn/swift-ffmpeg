#!/bin/bash -p

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
reject_shell_startup_environment
load_release_configuration

download_once() {
    local url="$1"
    local destination="$2"
    local label="$3"
    local temporary

    if [[ -f "$destination" ]]; then
        echo "Using cached $label: $destination"
        return 0
    fi

    temporary="$(mktemp "$SOURCE_CACHE_ROOT/.download.XXXXXX")"
    trap '/bin/rm -f "$temporary"' RETURN
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
        --output "$temporary" \
        "$url"
    [[ -s "$temporary" ]] || {
        echo "Downloaded an empty $label" >&2
        return 1
    }
    /bin/chmod 0644 "$temporary"
    /bin/mv "$temporary" "$destination"
    trap - RETURN
    echo "Downloaded $label: $destination"
}

mkdir -p "$SOURCE_CACHE_ROOT"
download_once "$FFMPEG_URL" "$FFMPEG_TARBALL" "FFmpeg source"
download_once "$FFMPEG_SIGNATURE_URL" "$FFMPEG_SIGNATURE" "FFmpeg signature"
download_once "$DAV1D_URL" "$DAV1D_TARBALL" "dav1d source"

"$SCRIPT_DIR/verify-sources.sh"
