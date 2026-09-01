#!/bin/bash -p

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
reject_shell_startup_environment
load_release_configuration

verify_archive_root() {
    local archive="$1"
    local expected_root="$2"
    local compression_flag="$3"
    local entry
    local listing

    listing="$(mktemp "${TMPDIR:-/tmp}/swift-ffmpeg-archive.XXXXXX")"
    trap '/bin/rm -f "$listing"' RETURN
    /usr/bin/tar "$compression_flag"tf "$archive" >"$listing"
    [[ -s "$listing" ]] || {
        echo "Archive is empty: $archive" >&2
        return 1
    }

    while IFS= read -r entry; do
        case "$entry" in
            "$expected_root"|"$expected_root/"|"$expected_root/"*) ;;
            *)
                echo "Archive entry escapes expected root $expected_root: $entry" >&2
                return 1
                ;;
        esac
        case "/$entry/" in
            */../*|*/./*)
                echo "Archive contains an unsafe path: $entry" >&2
                return 1
                ;;
        esac
    done <"$listing"
    trap - RETURN
    /bin/rm -f "$listing"
}

for source_path in \
    "$FFMPEG_TARBALL" \
    "$FFMPEG_SIGNATURE" \
    "$DAV1D_TARBALL" \
    "$FFMPEG_RELEASE_KEY"
do
    [[ -f "$source_path" ]] || {
        echo "Missing source-verification input: $source_path" >&2
        exit 1
    }
done

require_command gpg
verify_sha256 \
    "$FFMPEG_RELEASE_KEY" \
    "$FFMPEG_RELEASE_KEY_SHA256" \
    "Pinned FFmpeg release key"
verify_sha256 "$FFMPEG_TARBALL" "$FFMPEG_SHA256" "FFmpeg source"
verify_sha256 "$DAV1D_TARBALL" "$DAV1D_SHA256" "dav1d source"

verification_home="$(mktemp -d "${TMPDIR:-/tmp}/swift-ffmpeg-gpg.XXXXXX")"
status_file="$verification_home/signature.status"
trap '/bin/rm -rf "$verification_home"' EXIT
/bin/chmod 0700 "$verification_home"
gpg --batch --quiet --homedir "$verification_home" --import "$FFMPEG_RELEASE_KEY"

key_identity="$(
    gpg --batch --homedir "$verification_home" --with-colons \
        --fingerprint "$FFMPEG_RELEASE_KEY_FINGERPRINT" |
        /usr/bin/awk -F: '
            $1 == "pub" { public_keys++ }
            $1 == "fpr" && fingerprint == "" { fingerprint = $10 }
            END { printf "%d:%s", public_keys + 0, fingerprint }
        '
)"
assert_exact_value \
    "Pinned FFmpeg release key" \
    "1:$FFMPEG_RELEASE_KEY_FINGERPRINT" \
    "$key_identity"

gpg --batch --homedir "$verification_home" --status-fd 1 \
    --verify "$FFMPEG_SIGNATURE" "$FFMPEG_TARBALL" \
    >"$status_file" 2>"$verification_home/signature.stderr"
/usr/bin/grep -F \
    "[GNUPG:] VALIDSIG $FFMPEG_RELEASE_KEY_FINGERPRINT " \
    "$status_file" >/dev/null || {
        echo "FFmpeg signature did not validate with the pinned release key" >&2
        exit 1
    }

verify_archive_root "$FFMPEG_TARBALL" "ffmpeg-$FFMPEG_VERSION" -J
verify_archive_root "$DAV1D_TARBALL" "dav1d-$DAV1D_VERSION" -j
archive_version="$(
    /usr/bin/tar -xJOf "$FFMPEG_TARBALL" \
        "ffmpeg-$FFMPEG_VERSION/VERSION" |
        /usr/bin/tr -d '\r\n'
)"
assert_exact_value "FFmpeg archive VERSION" "$FFMPEG_VERSION" "$archive_version"

echo "Verified FFmpeg $FFMPEG_VERSION and dav1d $DAV1D_VERSION sources"
