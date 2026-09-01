#!/bin/bash -p

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
reject_shell_startup_environment
load_release_configuration

require_command jq
require_command unzip
require_command zipinfo

SOURCE_KIT_NAME="swift-ffmpeg-${PACKAGE_VERSION}-source-kit.zip"
SBOM_NAME="swift-ffmpeg-${PACKAGE_VERSION}.spdx.json"
METRICS_NAME="release-metrics.json"
MANIFEST_NAME="release-manifest.json"
CHECKSUMS_NAME="SHA256SUMS"
SOURCE_KIT_PATH="$ARTIFACT_ROOT/$SOURCE_KIT_NAME"
SBOM_PATH="$ARTIFACT_ROOT/$SBOM_NAME"
METRICS_PATH="$ARTIFACT_ROOT/$METRICS_NAME"
MANIFEST_PATH="$ARTIFACT_ROOT/$MANIFEST_NAME"
CHECKSUMS_PATH="$ARTIFACT_ROOT/$CHECKSUMS_NAME"

for asset_path in \
    "$RELEASE_ZIP" \
    "$SOURCE_KIT_PATH" \
    "$SBOM_PATH" \
    "$METRICS_PATH" \
    "$MANIFEST_PATH" \
    "$CHECKSUMS_PATH"
do
    [[ -f "$asset_path" && ! -L "$asset_path" ]] || {
        echo "Release asset must be a regular, non-symlink file: $asset_path" >&2
        exit 1
    }
done

verify_sha256 "$RELEASE_ZIP" "$ARTIFACT_CHECKSUM" "Release binary"

temporary_root="$(mktemp -d "$ARTIFACT_ROOT/.verify-release-assets.XXXXXX")"
cleanup() {
    case "$temporary_root" in
        "$ARTIFACT_ROOT"/.verify-release-assets.*)
            /bin/rm -rf "$temporary_root"
            ;;
        *)
            echo "Refusing to remove unexpected temporary path: $temporary_root" >&2
            ;;
    esac
}
trap cleanup EXIT

kit_root_name="swift-ffmpeg-${PACKAGE_VERSION}-source-kit"
archive_listing="$temporary_root/archive-listing.txt"
sorted_listing="$temporary_root/archive-listing.sorted.txt"
duplicate_listing="$temporary_root/archive-listing.duplicates.txt"
TZ=UTC /usr/bin/unzip -Z1 "$SOURCE_KIT_PATH" >"$archive_listing"
[[ -s "$archive_listing" ]] || {
    echo "Source kit is empty" >&2
    exit 1
}
LC_ALL=C /usr/bin/sort "$archive_listing" >"$sorted_listing"
/usr/bin/cmp -s "$archive_listing" "$sorted_listing" || {
    echo "Source-kit entries are not in deterministic lexical order" >&2
    exit 1
}
LC_ALL=C /usr/bin/sort "$archive_listing" | /usr/bin/uniq -d \
    >"$duplicate_listing"
[[ ! -s "$duplicate_listing" ]] || {
    echo "Source kit contains duplicate entries" >&2
    exit 1
}

while IFS= read -r archive_entry; do
    archive_entry_for_safety="${archive_entry%/}"
    [[ -n "$archive_entry" ]] || {
        echo "Source kit contains an empty entry name" >&2
        exit 1
    }
    [[ "$archive_entry" != /* && "$archive_entry" != *\\* ]] || {
        echo "Source kit contains an unsafe entry: $archive_entry" >&2
        exit 1
    }
    case "$archive_entry" in
        "$kit_root_name"|"$kit_root_name/"|"$kit_root_name/"*) ;;
        *)
            echo "Source-kit entry escapes its expected root: $archive_entry" >&2
            exit 1
            ;;
    esac
    case "/$archive_entry_for_safety/" in
        *"/../"*|*"/./"*|*"//"*)
            echo "Source kit contains path traversal: $archive_entry" >&2
            exit 1
            ;;
    esac
done <"$archive_listing"

if TZ=UTC /usr/bin/zipinfo -l "$SOURCE_KIT_PATH" | /usr/bin/grep -E '^l' >/dev/null; then
    echo "Source kit must not contain symbolic links" >&2
    exit 1
fi

expected_archive_timestamp="$(
    TZ=UTC /bin/date -r "$SOURCE_DATE_EPOCH" '+%y-%b-%d %H:%M'
)"
archive_metadata_error="$(
    TZ=UTC LC_ALL=C /usr/bin/zipinfo -l "$SOURCE_KIT_PATH" |
        /usr/bin/awk -v expected_timestamp="$expected_archive_timestamp" '
            $1 ~ /^d/ && ($1 != "drwxr-xr-x" || $8 " " $9 != expected_timestamp) {
                print $0
                exit
            }
            $1 ~ /^-/ {
                expected_mode = "-rw-r--r--"
                if ($10 ~ /\/Scripts\/.*\.sh$/) {
                    expected_mode = "-rwxr-xr-x"
                }
                if ($1 != expected_mode || $8 " " $9 != expected_timestamp) {
                    print $0
                    exit
                }
            }
        '
)"
[[ -z "$archive_metadata_error" ]] || {
    echo "Source kit contains non-deterministic mode or timestamp metadata" >&2
    echo "$archive_metadata_error" >&2
    exit 1
}

for required_entry in \
    "$kit_root_name/SOURCE-KIT-MANIFEST.json" \
    "$kit_root_name/SOURCE-KIT-README.md" \
    "$kit_root_name/Configuration/release.json" \
    "$kit_root_name/Keys/ffmpeg-devel.asc" \
    "$kit_root_name/Licenses/FFmpeg-Static-Relinking.md" \
    "$kit_root_name/Package.swift" \
    "$kit_root_name/Upstream/ffmpeg-${FFMPEG_VERSION}.tar.xz" \
    "$kit_root_name/Upstream/ffmpeg-${FFMPEG_VERSION}.tar.xz.asc" \
    "$kit_root_name/Upstream/dav1d-${DAV1D_VERSION}.tar.bz2" \
    "$kit_root_name/mise.lock" \
    "$kit_root_name/mise.toml"
do
    /usr/bin/grep -Fx "$required_entry" "$archive_listing" >/dev/null || {
        echo "Source kit is missing required entry: $required_entry" >&2
        exit 1
    }
done

kit_manifest="$temporary_root/source-kit-manifest.json"
/usr/bin/unzip -p \
    "$SOURCE_KIT_PATH" \
    "$kit_root_name/SOURCE-KIT-MANIFEST.json" \
    >"$kit_manifest"
jq -e \
    --arg packageVersion "$PACKAGE_VERSION" \
    --arg ffmpegVersion "$FFMPEG_VERSION" \
    --arg ffmpegSHA256 "$FFMPEG_SHA256" \
    --arg dav1dVersion "$DAV1D_VERSION" \
    --arg dav1dSHA256 "$DAV1D_SHA256" \
    --arg releaseKeyFingerprint "$FFMPEG_RELEASE_KEY_FINGERPRINT" \
    '.schemaVersion == 1 and
     .packageVersion == $packageVersion and
     .upstream.ffmpeg.version == $ffmpegVersion and
     .upstream.ffmpeg.sha256 == $ffmpegSHA256 and
     .upstream.ffmpeg.releaseKeyFingerprint == $releaseKeyFingerprint and
     .upstream.dav1d.version == $dav1dVersion and
     .upstream.dav1d.sha256 == $dav1dSHA256 and
     (.files | type == "array" and length > 0) and
     ([.files[].path] == ([.files[].path] | sort | unique))' \
    "$kit_manifest" >/dev/null

inventory_paths="$temporary_root/inventory-paths.txt"
archive_files="$temporary_root/archive-files.txt"
jq -r '.files[].path' "$kit_manifest" >"$inventory_paths"
/usr/bin/awk -v root="$kit_root_name/" '
    /\/$/ { next }
    $0 == root "SOURCE-KIT-MANIFEST.json" { next }
    index($0, root) == 1 { print substr($0, length(root) + 1) }
' "$archive_listing" >"$archive_files"
/usr/bin/cmp -s "$inventory_paths" "$archive_files" || {
    echo "Source-kit inventory does not exactly cover archived files" >&2
    exit 1
}

while IFS=$'\t' read -r inventory_path expected_sha256 expected_size; do
    [[ -n "$inventory_path" && "$inventory_path" != /* && "$inventory_path" != *\\* ]] || {
        echo "Unsafe source-kit inventory path: $inventory_path" >&2
        exit 1
    }
    case "/$inventory_path/" in
        *"/../"*|*"/./"*|*"//"*)
            echo "Unsafe source-kit inventory path: $inventory_path" >&2
            exit 1
            ;;
    esac
    extracted_file="$temporary_root/inventory-file"
    /usr/bin/unzip -p \
        "$SOURCE_KIT_PATH" \
        "$kit_root_name/$inventory_path" \
        >"$extracted_file"
    verify_sha256 "$extracted_file" "$expected_sha256" "Source-kit $inventory_path"
    assert_exact_value \
        "Source-kit $inventory_path size" \
        "$expected_size" \
        "$(/usr/bin/stat -f '%z' "$extracted_file")"
done < <(
    jq -r '.files[] | [.path, .sha256, (.size | tostring)] | @tsv' \
        "$kit_manifest"
)

expected_checksums="$temporary_root/SHA256SUMS.expected"
for checksummed_asset in \
    "$RELEASE_ZIP" \
    "$MANIFEST_PATH" \
    "$METRICS_PATH" \
    "$SOURCE_KIT_PATH" \
    "$SBOM_PATH"
do
    printf '%s  %s\n' \
        "$(sha256_file "$checksummed_asset")" \
        "$(basename "$checksummed_asset")"
done | LC_ALL=C /usr/bin/sort -k2,2 >"$expected_checksums"
/usr/bin/cmp -s "$expected_checksums" "$CHECKSUMS_PATH" || {
    echo "SHA256SUMS does not exactly match the release assets" >&2
    exit 1
}

source_kit_sha256="$(sha256_file "$SOURCE_KIT_PATH")"
source_kit_size="$(/usr/bin/stat -f '%z' "$SOURCE_KIT_PATH")"
release_zip_size="$(/usr/bin/stat -f '%z' "$RELEASE_ZIP")"
metrics_sha256="$(sha256_file "$METRICS_PATH")"
metrics_size="$(/usr/bin/stat -f '%z' "$METRICS_PATH")"
sbom_sha256="$(sha256_file "$SBOM_PATH")"
sbom_size="$(/usr/bin/stat -f '%z' "$SBOM_PATH")"

jq -e \
    --arg packageVersion "$PACKAGE_VERSION" \
    --arg ffmpegVersion "$FFMPEG_VERSION" \
    --arg dav1dVersion "$DAV1D_VERSION" \
    --arg binaryName "$ARTIFACT_NAME" \
    --arg binarySHA256 "$ARTIFACT_CHECKSUM" \
    --argjson binarySize "$release_zip_size" \
    --arg sourceKitName "$SOURCE_KIT_NAME" \
    --arg sourceKitSHA256 "$source_kit_sha256" \
    --argjson sourceKitSize "$source_kit_size" \
    --arg metricsName "$METRICS_NAME" \
    --arg metricsSHA256 "$metrics_sha256" \
    --argjson metricsSize "$metrics_size" \
    --arg sbomName "$SBOM_NAME" \
    --arg sbomSHA256 "$sbom_sha256" \
    --argjson sbomSize "$sbom_size" \
    '
      .schemaVersion == 1 and
      .packageVersion == $packageVersion and
      .releaseTag == $packageVersion and
      .upstream == {ffmpeg: $ffmpegVersion, dav1d: $dav1dVersion} and
      (.supportedPlatforms | length == 3) and
      (.artifacts | length == 4) and
      ([.artifacts[].name] == ([.artifacts[].name] | sort | unique)) and
      ([.artifacts[] | select(
          .name == $binaryName and .role == "swiftpm-binary-target" and
          .sha256 == $binarySHA256 and .size == $binarySize
      )] | length == 1) and
      ([.artifacts[] | select(
          .name == $sourceKitName and
          .role == "corresponding-source-and-relinking-kit" and
          .sha256 == $sourceKitSHA256 and .size == $sourceKitSize
      )] | length == 1) and
      ([.artifacts[] | select(
          .name == $metricsName and .role == "release-metrics" and
          .sha256 == $metricsSHA256 and .size == $metricsSize
      )] | length == 1) and
      ([.artifacts[] | select(
          .name == $sbomName and .role == "spdx-sbom" and
          .sha256 == $sbomSHA256 and .size == $sbomSize
      )] | length == 1)
    ' "$MANIFEST_PATH" >/dev/null

jq -e \
    --arg packageVersion "$PACKAGE_VERSION" \
    --arg binaryName "$ARTIFACT_NAME" \
    --arg binarySHA256 "$ARTIFACT_CHECKSUM" \
    --argjson binarySize "$release_zip_size" \
    --arg sourceKitName "$SOURCE_KIT_NAME" \
    --arg sourceKitSHA256 "$source_kit_sha256" \
    --argjson sourceKitSize "$source_kit_size" \
    --arg ffmpegVersion "$FFMPEG_VERSION" \
    --arg ffmpegSHA256 "$FFMPEG_SHA256" \
    --arg dav1dVersion "$DAV1D_VERSION" \
    --arg dav1dSHA256 "$DAV1D_SHA256" \
    --arg iOSMinimumVersion "$IOS_MINIMUM_VERSION" \
    --arg macOSMinimumVersion "$MACOS_MINIMUM_VERSION" \
    '
      .schemaVersion == 1 and
      .packageVersion == $packageVersion and
      .artifacts.binary == {name: $binaryName, sha256: $binarySHA256, size: $binarySize} and
      .artifacts.sourceKit.name == $sourceKitName and
      .artifacts.sourceKit.sha256 == $sourceKitSHA256 and
      .artifacts.sourceKit.size == $sourceKitSize and
      .xcframework.platformCount == 2 and
      .xcframework.sliceCount == 3 and
      .xcframework.architectureCount == 5 and
      .xcframework.minimumVersions == {iOS: $iOSMinimumVersion, macOS: $macOSMinimumVersion} and
      .sources.ffmpeg.version == $ffmpegVersion and
      .sources.ffmpeg.sha256 == $ffmpegSHA256 and
      .sources.dav1d.version == $dav1dVersion and
      .sources.dav1d.sha256 == $dav1dSHA256 and
      (.sources.patchCount | type == "number" and . > 0) and
      (.toolchain | type == "object")
    ' "$METRICS_PATH" >/dev/null

jq -e \
    --arg packageVersion "$PACKAGE_VERSION" \
    --arg artifactSHA256 "$ARTIFACT_CHECKSUM" \
    --arg ffmpegVersion "$FFMPEG_VERSION" \
    --arg ffmpegSHA256 "$FFMPEG_SHA256" \
    --arg dav1dVersion "$DAV1D_VERSION" \
    --arg dav1dSHA256 "$DAV1D_SHA256" \
    '
      .spdxVersion == "SPDX-2.3" and
      .dataLicense == "CC0-1.0" and
      .SPDXID == "SPDXRef-DOCUMENT" and
      (.packages | length == 3) and
      ([.packages[].SPDXID] | unique | length == 3) and
      ([.packages[] | select(
          .SPDXID == "SPDXRef-Package-swift-ffmpeg" and
          .versionInfo == $packageVersion and .licenseDeclared == "MIT" and
          .checksums == [{algorithm: "SHA256", checksumValue: $artifactSHA256}]
      )] | length == 1) and
      ([.packages[] | select(
          .SPDXID == "SPDXRef-Package-FFmpeg" and
          .versionInfo == $ffmpegVersion and
          .checksums == [{algorithm: "SHA256", checksumValue: $ffmpegSHA256}]
      )] | length == 1) and
      ([.packages[] | select(
          .SPDXID == "SPDXRef-Package-dav1d" and
          .versionInfo == $dav1dVersion and
          .checksums == [{algorithm: "SHA256", checksumValue: $dav1dSHA256}]
      )] | length == 1) and
      ([.relationships[] | select(.relationshipType == "DESCRIBES")] | length == 1) and
      ([.relationships[] | select(.relationshipType == "DEPENDS_ON")] | length == 2) and
      ([.hasExtractedLicensingInfos[] | select(.licenseId == "LicenseRef-IJG")] | length == 1)
    ' "$SBOM_PATH" >/dev/null

echo "Verified release manifest, metrics, SPDX SBOM, checksums, and source kit"
