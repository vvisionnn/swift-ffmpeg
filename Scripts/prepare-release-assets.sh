#!/bin/bash -p

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
reject_shell_startup_environment
load_release_configuration

require_command jq
require_command zip
require_command unzip

SOURCE_KIT_NAME="swift-ffmpeg-${PACKAGE_VERSION}-source-kit.zip"
SBOM_NAME="swift-ffmpeg-${PACKAGE_VERSION}.spdx.json"
METRICS_NAME="release-metrics.json"
MANIFEST_NAME="release-manifest.json"
CHECKSUMS_NAME="SHA256SUMS"

for input_path in \
    "$RELEASE_ZIP" \
    "$FFMPEG_TARBALL" \
    "$FFMPEG_SIGNATURE" \
    "$DAV1D_TARBALL" \
    "$FFMPEG_RELEASE_KEY"
do
    [[ -f "$input_path" && ! -L "$input_path" ]] || {
        echo "Release input must be a regular, non-symlink file: $input_path" >&2
        exit 1
    }
done

verify_sha256 "$RELEASE_ZIP" "$ARTIFACT_CHECKSUM" "Release binary"
"$SCRIPT_DIR/verify-sources.sh"

mkdir -p "$ARTIFACT_ROOT"
work_root="$(mktemp -d "$ARTIFACT_ROOT/.release-assets.XXXXXX")"

cleanup() {
    case "$work_root" in
        "$ARTIFACT_ROOT"/.release-assets.*)
            /bin/rm -rf "$work_root"
            ;;
        *)
            echo "Refusing to remove unexpected temporary path: $work_root" >&2
            ;;
    esac
}
trap cleanup EXIT

kit_root_name="swift-ffmpeg-${PACKAGE_VERSION}-source-kit"
kit_root="$work_root/$kit_root_name"
output_root="$work_root/output"
mkdir -p "$kit_root" "$output_root"

validate_relative_path() {
    local relative_path="$1"
    [[ -n "$relative_path" ]] || return 1
    [[ "$relative_path" != /* ]] || return 1
    [[ "$relative_path" != *$'\n'* && "$relative_path" != *$'\r'* ]] || return 1
    [[ "$relative_path" != *\\* ]] || return 1
    case "/$relative_path/" in
        *"/../"*|*"/./"*|*"//"*) return 1 ;;
    esac
}

copy_regular_file() {
    local source_path="$1"
    local relative_path="$2"
    local destination_path

    validate_relative_path "$relative_path" || {
        echo "Unsafe source-kit path: $relative_path" >&2
        exit 1
    }
    [[ -f "$source_path" && ! -L "$source_path" ]] || {
        echo "Source-kit input must be a regular, non-symlink file: $source_path" >&2
        exit 1
    }
    destination_path="$kit_root/$relative_path"
    mkdir -p "$(dirname "$destination_path")"
    COPYFILE_DISABLE=1 /bin/cp "$source_path" "$destination_path"
}

source_kit_path_is_allowed() {
    local relative_path="$1"
    case "$relative_path" in
        Configuration/*.json|Configuration/*.md|\
        Keys/ffmpeg-devel.asc|Patches/*.patch|\
        Licenses/*.txt|Licenses/*.md|Scripts/*.sh|Scripts/*.py|\
        Scripts/support/*.c|Scripts/support/*.h|Scripts/support/*.modulemap|\
        Sources/*.swift|\
        Sources/*.xcprivacy|Tests/*.swift|Tests/*.py|Tests/*.html)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

copy_source_tree() {
    local relative_root="$1"
    local source_root="$PROJECT_ROOT/$relative_root"
    local unexpected_path
    local source_path
    local relative_path

    [[ -d "$source_root" && ! -L "$source_root" ]] || {
        echo "Source-kit tree must be a regular directory: $source_root" >&2
        exit 1
    }
    unexpected_path="$({
        /usr/bin/find "$source_root" ! -type d ! -type f -print -quit
    } 2>/dev/null)"
    [[ -z "$unexpected_path" ]] || {
        echo "Source-kit tree contains a non-regular entry: $unexpected_path" >&2
        exit 1
    }

    while IFS= read -r source_path; do
        relative_path="${source_path#"$PROJECT_ROOT/"}"
        source_kit_path_is_allowed "$relative_path" || {
            echo "Unexpected file in source-kit input tree: $relative_path" >&2
            exit 1
        }
        copy_regular_file "$source_path" "$relative_path"
    done < <(
        /usr/bin/find "$source_root" \
            -type d -name '__pycache__' -prune -o \
            -type f -print |
            LC_ALL=C /usr/bin/sort
    )
}

for root_file in \
    CHANGELOG.md \
    CONTRIBUTING.md \
    LICENSE \
    Package.swift \
    README.md \
    SECURITY.md \
    THIRD_PARTY_NOTICES.md \
    mise.lock \
    mise.toml
do
    copy_regular_file "$PROJECT_ROOT/$root_file" "$root_file"
done

for source_tree in Configuration Keys Licenses Patches Scripts Sources Tests; do
    copy_source_tree "$source_tree"
done

copy_regular_file \
    "$FFMPEG_TARBALL" \
    "Upstream/ffmpeg-${FFMPEG_VERSION}.tar.xz"
copy_regular_file \
    "$FFMPEG_SIGNATURE" \
    "Upstream/ffmpeg-${FFMPEG_VERSION}.tar.xz.asc"
copy_regular_file \
    "$DAV1D_TARBALL" \
    "Upstream/dav1d-${DAV1D_VERSION}.tar.bz2"

generated_at="$(TZ=UTC /bin/date -r "$SOURCE_DATE_EPOCH" '+%Y-%m-%dT%H:%M:%SZ')"
signature_sha256="$(sha256_file "$FFMPEG_SIGNATURE")"
release_config_sha256="$(sha256_file "$RELEASE_CONFIG")"

{
    printf '%s\n' \
        "# swift-ffmpeg ${PACKAGE_VERSION} source and relinking kit" \
        "" \
        "This archive contains the exact corresponding sources and deterministic" \
        "build inputs for the released FFmpeg XCFramework. It does not contain the" \
        "generated binary." \
        "" \
        "The bundled upstream archives are authenticated by the hashes in" \
        "Configuration/release.json. FFmpeg's detached signature is verified with" \
        "Keys/ffmpeg-devel.asc and its pinned fingerprint." \
        "" \
        "To reconstruct the release from this directory on the configured macOS" \
        "toolchain:" \
        "" \
        '```sh' \
        "mkdir -p .cache/sources" \
        "cp Upstream/ffmpeg-${FFMPEG_VERSION}.tar.xz .cache/sources/" \
        "cp Upstream/ffmpeg-${FFMPEG_VERSION}.tar.xz.asc .cache/sources/" \
        "cp Upstream/dav1d-${DAV1D_VERSION}.tar.bz2 .cache/sources/" \
        "mise install" \
        "mise run sources:verify" \
        "mise run build" \
        "mise run package" \
        '```' \
        "" \
        "See Licenses/FFmpeg-Static-Relinking.md for relinking guidance and" \
        "THIRD_PARTY_NOTICES.md for the complete license summary."
} >"$kit_root/SOURCE-KIT-README.md"

inventory_records="$work_root/source-kit-files.ndjson"
inventory_json="$work_root/source-kit-files.json"
: >"$inventory_records"
while IFS= read -r kit_file; do
    kit_relative_path="${kit_file#"$kit_root/"}"
    validate_relative_path "$kit_relative_path" || {
        echo "Unsafe staged source-kit path: $kit_relative_path" >&2
        exit 1
    }
    jq -cn \
        --arg path "$kit_relative_path" \
        --arg sha256 "$(sha256_file "$kit_file")" \
        --argjson size "$(/usr/bin/stat -f '%z' "$kit_file")" \
        '{path: $path, sha256: $sha256, size: $size}' \
        >>"$inventory_records"
done < <(
    /usr/bin/find "$kit_root" -type f -print | LC_ALL=C /usr/bin/sort
)
jq -s -S '.' "$inventory_records" >"$inventory_json"

jq -n -S \
    --arg packageVersion "$PACKAGE_VERSION" \
    --arg generatedAt "$generated_at" \
    --arg configurationSHA256 "$release_config_sha256" \
    --arg ffmpegVersion "$FFMPEG_VERSION" \
    --arg ffmpegURL "$FFMPEG_URL" \
    --arg ffmpegSHA256 "$FFMPEG_SHA256" \
    --arg ffmpegSignatureSHA256 "$signature_sha256" \
    --arg releaseKeyFingerprint "$FFMPEG_RELEASE_KEY_FINGERPRINT" \
    --arg dav1dVersion "$DAV1D_VERSION" \
    --arg dav1dURL "$DAV1D_URL" \
    --arg dav1dSHA256 "$DAV1D_SHA256" \
    --slurpfile files "$inventory_json" \
    '{
        schemaVersion: 1,
        packageVersion: $packageVersion,
        generatedAt: $generatedAt,
        configurationSHA256: $configurationSHA256,
        upstream: {
            ffmpeg: {
                version: $ffmpegVersion,
                url: $ffmpegURL,
                sha256: $ffmpegSHA256,
                signatureSHA256: $ffmpegSignatureSHA256,
                releaseKeyFingerprint: $releaseKeyFingerprint
            },
            dav1d: {
                version: $dav1dVersion,
                url: $dav1dURL,
                sha256: $dav1dSHA256
            }
        },
        files: $files[0]
    }' >"$kit_root/SOURCE-KIT-MANIFEST.json"

archive_timestamp="$(
    TZ=UTC /bin/date -r "$SOURCE_DATE_EPOCH" '+%Y%m%d%H%M.%S'
)"
/usr/bin/xattr -cr "$kit_root"
/usr/bin/find "$kit_root" -type d -exec /bin/chmod 0755 {} +
/usr/bin/find "$kit_root" -type f -exec /bin/chmod 0644 {} +
/usr/bin/find "$kit_root/Scripts" -type f -name '*.sh' \
    -exec /bin/chmod 0755 {} +
TZ=UTC /usr/bin/find "$kit_root" \
    -exec /usr/bin/touch -h -t "$archive_timestamp" {} +

source_kit_path="$output_root/$SOURCE_KIT_NAME"
(
    cd "$work_root"
    /usr/bin/find "$kit_root_name" -print |
        LC_ALL=C /usr/bin/sort |
        TZ=UTC COPYFILE_DISABLE=1 /usr/bin/zip -X -q "$source_kit_path" -@
)

source_kit_sha256="$(sha256_file "$source_kit_path")"
source_kit_size="$(/usr/bin/stat -f '%z' "$source_kit_path")"
source_kit_entries="$(/usr/bin/unzip -Z1 "$source_kit_path" | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
release_zip_size="$(/usr/bin/stat -f '%z' "$RELEASE_ZIP")"
ffmpeg_source_size="$(/usr/bin/stat -f '%z' "$FFMPEG_TARBALL")"
ffmpeg_signature_size="$(/usr/bin/stat -f '%z' "$FFMPEG_SIGNATURE")"
dav1d_source_size="$(/usr/bin/stat -f '%z' "$DAV1D_TARBALL")"
release_key_size="$(/usr/bin/stat -f '%z' "$FFMPEG_RELEASE_KEY")"
patch_count="$(/usr/bin/find "$PROJECT_ROOT/Patches" -type f -name '*.patch' | /usr/bin/wc -l | /usr/bin/tr -d ' ')"

metrics_path="$output_root/$METRICS_NAME"
jq -n -S \
    --arg packageVersion "$PACKAGE_VERSION" \
    --arg generatedAt "$generated_at" \
    --arg binaryName "$ARTIFACT_NAME" \
    --arg binarySHA256 "$ARTIFACT_CHECKSUM" \
    --argjson binarySize "$release_zip_size" \
    --arg sourceKitName "$SOURCE_KIT_NAME" \
    --arg sourceKitSHA256 "$source_kit_sha256" \
    --argjson sourceKitSize "$source_kit_size" \
    --argjson sourceKitEntries "$source_kit_entries" \
    --arg infoPlistSHA256 "$EXPECTED_INFO_PLIST_SHA256" \
    --arg iosSHA256 "$EXPECTED_IOS_ARCHIVE_SHA256" \
    --arg simulatorSHA256 "$EXPECTED_SIMULATOR_ARCHIVE_SHA256" \
    --arg macosSHA256 "$EXPECTED_MACOS_ARCHIVE_SHA256" \
    --arg iosMinimumVersion "$IOS_MINIMUM_VERSION" \
    --arg macosMinimumVersion "$MACOS_MINIMUM_VERSION" \
    --arg ffmpegVersion "$FFMPEG_VERSION" \
    --arg ffmpegSHA256 "$FFMPEG_SHA256" \
    --argjson ffmpegSize "$ffmpeg_source_size" \
    --arg ffmpegSignatureSHA256 "$signature_sha256" \
    --argjson ffmpegSignatureSize "$ffmpeg_signature_size" \
    --arg dav1dVersion "$DAV1D_VERSION" \
    --arg dav1dSHA256 "$DAV1D_SHA256" \
    --argjson dav1dSize "$dav1d_source_size" \
    --arg releaseKeySHA256 "$FFMPEG_RELEASE_KEY_SHA256" \
    --argjson releaseKeySize "$release_key_size" \
    --argjson patchCount "$patch_count" \
    --slurpfile configuration "$RELEASE_CONFIG" \
    '{
        schemaVersion: 1,
        packageVersion: $packageVersion,
        generatedAt: $generatedAt,
        artifacts: {
            binary: {name: $binaryName, sha256: $binarySHA256, size: $binarySize},
            sourceKit: {
                name: $sourceKitName,
                sha256: $sourceKitSHA256,
                size: $sourceKitSize,
                archiveEntryCount: $sourceKitEntries
            }
        },
        xcframework: {
            platformCount: 2,
            sliceCount: 3,
            architectureCount: 5,
            infoPlistSHA256: $infoPlistSHA256,
            minimumVersions: {iOS: $iosMinimumVersion, macOS: $macosMinimumVersion},
            slices: {
                "ios-arm64": $iosSHA256,
                "ios-arm64_x86_64-simulator": $simulatorSHA256,
                "macos-arm64_x86_64": $macosSHA256
            }
        },
        sources: {
            ffmpeg: {
                version: $ffmpegVersion,
                sha256: $ffmpegSHA256,
                size: $ffmpegSize,
                signatureSHA256: $ffmpegSignatureSHA256,
                signatureSize: $ffmpegSignatureSize
            },
            dav1d: {version: $dav1dVersion, sha256: $dav1dSHA256, size: $dav1dSize},
            releaseKey: {sha256: $releaseKeySHA256, size: $releaseKeySize},
            patchCount: $patchCount
        },
        toolchain: $configuration[0].toolchain
    }' >"$metrics_path"

ijg_license_text="$(<"$PROJECT_ROOT/Licenses/Independent-JPEG-Group.txt")"
sbom_path="$output_root/$SBOM_NAME"
jq -n -S \
    --arg packageVersion "$PACKAGE_VERSION" \
    --arg generatedAt "$generated_at" \
    --arg namespace "https://github.com/vvisionnn/swift-ffmpeg/spdx/${PACKAGE_VERSION}/${release_config_sha256}" \
    --arg artifactSHA256 "$ARTIFACT_CHECKSUM" \
    --arg artifactURL "https://github.com/vvisionnn/swift-ffmpeg/releases/download/${PACKAGE_VERSION}/${ARTIFACT_NAME}" \
    --arg ffmpegVersion "$FFMPEG_VERSION" \
    --arg ffmpegURL "$FFMPEG_URL" \
    --arg ffmpegSHA256 "$FFMPEG_SHA256" \
    --arg dav1dVersion "$DAV1D_VERSION" \
    --arg dav1dURL "$DAV1D_URL" \
    --arg dav1dSHA256 "$DAV1D_SHA256" \
    --arg ijgLicenseText "$ijg_license_text" \
    '{
        spdxVersion: "SPDX-2.3",
        dataLicense: "CC0-1.0",
        SPDXID: "SPDXRef-DOCUMENT",
        name: ("swift-ffmpeg-" + $packageVersion),
        documentNamespace: $namespace,
        creationInfo: {
            created: $generatedAt,
            creators: ["Tool: swift-ffmpeg-release-assets-1"]
        },
        packages: [
            {
                SPDXID: "SPDXRef-Package-swift-ffmpeg",
                name: "swift-ffmpeg",
                versionInfo: $packageVersion,
                downloadLocation: $artifactURL,
                filesAnalyzed: false,
                checksums: [{algorithm: "SHA256", checksumValue: $artifactSHA256}],
                licenseConcluded: "NOASSERTION",
                licenseDeclared: "MIT",
                copyrightText: "Copyright (c) 2026 swift-ffmpeg contributors",
                primaryPackagePurpose: "LIBRARY",
                externalRefs: [{
                    referenceCategory: "PACKAGE-MANAGER",
                    referenceType: "purl",
                    referenceLocator: ("pkg:github/vvisionnn/swift-ffmpeg@" + $packageVersion)
                }]
            },
            {
                SPDXID: "SPDXRef-Package-FFmpeg",
                name: "FFmpeg",
                versionInfo: $ffmpegVersion,
                downloadLocation: $ffmpegURL,
                filesAnalyzed: false,
                checksums: [{algorithm: "SHA256", checksumValue: $ffmpegSHA256}],
                licenseConcluded: "LGPL-2.1-or-later AND LicenseRef-IJG",
                licenseDeclared: "LGPL-2.1-or-later AND LicenseRef-IJG",
                copyrightText: "NOASSERTION",
                primaryPackagePurpose: "LIBRARY"
            },
            {
                SPDXID: "SPDXRef-Package-dav1d",
                name: "dav1d",
                versionInfo: $dav1dVersion,
                downloadLocation: $dav1dURL,
                filesAnalyzed: false,
                checksums: [{algorithm: "SHA256", checksumValue: $dav1dSHA256}],
                licenseConcluded: "BSD-2-Clause",
                licenseDeclared: "BSD-2-Clause",
                copyrightText: "Copyright VideoLAN and dav1d authors",
                primaryPackagePurpose: "LIBRARY"
            }
        ],
        relationships: [
            {
                spdxElementId: "SPDXRef-DOCUMENT",
                relationshipType: "DESCRIBES",
                relatedSpdxElement: "SPDXRef-Package-swift-ffmpeg"
            },
            {
                spdxElementId: "SPDXRef-Package-swift-ffmpeg",
                relationshipType: "DEPENDS_ON",
                relatedSpdxElement: "SPDXRef-Package-FFmpeg"
            },
            {
                spdxElementId: "SPDXRef-Package-FFmpeg",
                relationshipType: "DEPENDS_ON",
                relatedSpdxElement: "SPDXRef-Package-dav1d"
            }
        ],
        hasExtractedLicensingInfos: [{
            licenseId: "LicenseRef-IJG",
            name: "Independent JPEG Group License",
            extractedText: $ijgLicenseText
        }]
    }' >"$sbom_path"

manifest_path="$output_root/$MANIFEST_NAME"
metrics_sha256="$(sha256_file "$metrics_path")"
metrics_size="$(/usr/bin/stat -f '%z' "$metrics_path")"
sbom_sha256="$(sha256_file "$sbom_path")"
sbom_size="$(/usr/bin/stat -f '%z' "$sbom_path")"
jq -n -S \
    --arg packageVersion "$PACKAGE_VERSION" \
    --arg generatedAt "$generated_at" \
    --arg repository "https://github.com/vvisionnn/swift-ffmpeg" \
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
    --arg ffmpegVersion "$FFMPEG_VERSION" \
    --arg dav1dVersion "$DAV1D_VERSION" \
    --arg iOSMinimumVersion "$IOS_MINIMUM_VERSION" \
    --arg macOSMinimumVersion "$MACOS_MINIMUM_VERSION" \
    '{
        schemaVersion: 1,
        packageVersion: $packageVersion,
        releaseTag: $packageVersion,
        generatedAt: $generatedAt,
        repository: $repository,
        upstream: {ffmpeg: $ffmpegVersion, dav1d: $dav1dVersion},
        supportedPlatforms: [
            {name: "iOS", minimumVersion: $iOSMinimumVersion, architectures: ["arm64"]},
            {
                name: "iOS Simulator",
                minimumVersion: $iOSMinimumVersion,
                architectures: ["arm64", "x86_64"]
            },
            {
                name: "macOS",
                minimumVersion: $macOSMinimumVersion,
                architectures: ["arm64", "x86_64"]
            }
        ],
        artifacts: [
            {
                name: $binaryName,
                role: "swiftpm-binary-target",
                mediaType: "application/zip",
                sha256: $binarySHA256,
                size: $binarySize
            },
            {
                name: $metricsName,
                role: "release-metrics",
                mediaType: "application/json",
                sha256: $metricsSHA256,
                size: $metricsSize
            },
            {
                name: $sourceKitName,
                role: "corresponding-source-and-relinking-kit",
                mediaType: "application/zip",
                sha256: $sourceKitSHA256,
                size: $sourceKitSize
            },
            {
                name: $sbomName,
                role: "spdx-sbom",
                mediaType: "application/spdx+json",
                sha256: $sbomSHA256,
                size: $sbomSize
            }
        ] | sort_by(.name)
    }' >"$manifest_path"

checksums_path="$output_root/$CHECKSUMS_NAME"
for asset_path in \
    "$RELEASE_ZIP" \
    "$manifest_path" \
    "$metrics_path" \
    "$source_kit_path" \
    "$sbom_path"
do
    printf '%s  %s\n' \
        "$(sha256_file "$asset_path")" \
        "$(basename "$asset_path")"
done | LC_ALL=C /usr/bin/sort -k2,2 >"$checksums_path"

for generated_name in \
    "$SOURCE_KIT_NAME" \
    "$SBOM_NAME" \
    "$METRICS_NAME" \
    "$MANIFEST_NAME" \
    "$CHECKSUMS_NAME"
do
    /bin/mv "$output_root/$generated_name" "$ARTIFACT_ROOT/$generated_name"
done

"$SCRIPT_DIR/verify-release-assets.sh"
echo "Prepared deterministic release assets in $ARTIFACT_ROOT"
