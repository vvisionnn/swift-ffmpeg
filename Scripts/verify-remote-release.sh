#!/bin/bash -p

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
reject_shell_startup_environment

clear_git_override_environment() {
    local variable
    set -f
    for variable in $(compgen -e); do
        case "$variable" in
            GIT_CONFIG_COUNT|GIT_CONFIG_KEY_*|GIT_CONFIG_VALUE_*|GIT_CONFIG_PARAMETERS|\
            GIT_DIR|GIT_WORK_TREE|GIT_INDEX_FILE|GIT_OBJECT_DIRECTORY|\
            GIT_ALTERNATE_OBJECT_DIRECTORIES|GIT_COMMON_DIR|GIT_CEILING_DIRECTORIES|\
            GIT_DISCOVERY_ACROSS_FILESYSTEM|GIT_SSH|GIT_SSH_COMMAND|GIT_PROXY_COMMAND|\
            GIT_ASKPASS|SSH_ASKPASS|GIT_PROTOCOL_FROM_USER|GIT_ALLOW_PROTOCOL|GIT_PROTOCOL)
                unset "$variable"
                ;;
        esac
    done
    set +f
}
clear_git_override_environment

readonly REPOSITORY_URL="https://github.com/vvisionnn/swift-ffmpeg.git"
readonly ARTIFACT_NAME="FFmpeg.xcframework.zip"
readonly HELPER="$SCRIPT_DIR/lib/remote_release_verifier.py"

usage() {
    /bin/cat <<'EOF'
Usage:
  Scripts/verify-remote-release.sh --tag X.Y.Z [options]

Options:
  --expected-ffmpeg-version VERSION  Require av_version_info() to equal VERSION.
  --expected-checksum SHA256         Require the tagged manifest and asset checksum.
  --fixture-root ABSOLUTE_PATH       Use repository/ and FFmpeg.xcframework.zip
                                     beneath a local fixture root instead of GitHub.
  --validation-only                  Stop after tag, manifest, URL, and asset checks.
  --help                             Show this help.

Production mode has no repository override: it always verifies
https://github.com/vvisionnn/swift-ffmpeg.git.
EOF
}

tag=""
expected_ffmpeg_version=""
expected_checksum=""
fixture_root=""
validation_only=0
while (($# > 0)); do
    case "$1" in
        --tag)
            (($# >= 2)) || { echo "Missing value for --tag" >&2; exit 2; }
            tag="$2"
            shift 2
            ;;
        --expected-ffmpeg-version)
            (($# >= 2)) || { echo "Missing value for --expected-ffmpeg-version" >&2; exit 2; }
            expected_ffmpeg_version="$2"
            shift 2
            ;;
        --expected-checksum)
            (($# >= 2)) || { echo "Missing value for --expected-checksum" >&2; exit 2; }
            expected_checksum="$2"
            shift 2
            ;;
        --fixture-root)
            (($# >= 2)) || { echo "Missing value for --fixture-root" >&2; exit 2; }
            fixture_root="$2"
            shift 2
            ;;
        --validation-only)
            validation_only=1
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

[[ -n "$tag" ]] || {
    echo "--tag is required" >&2
    usage >&2
    exit 2
}

require_command git
require_command python3
require_command shasum
require_command swift
python_command="$(command -v python3)"
"$python_command" "$HELPER" validate-tag "$tag" >/dev/null
if [[ -n "$expected_ffmpeg_version" ]]; then
    "$python_command" "$HELPER" validate-ffmpeg-version \
        "$expected_ffmpeg_version" >/dev/null
fi
if [[ -n "$expected_checksum" && ! "$expected_checksum" =~ ^[0-9a-f]{64}$ ]]; then
    echo "Expected checksum must be 64 lowercase hexadecimal characters" >&2
    exit 2
fi

work_root="$(/usr/bin/mktemp -d /tmp/swift-ffmpeg-remote-release.XXXXXX)"
case "$work_root" in
    /tmp/swift-ffmpeg-remote-release.*|/private/tmp/swift-ffmpeg-remote-release.*) ;;
    *)
        echo "mktemp returned an unsafe verification root: $work_root" >&2
        exit 1
        ;;
esac
cleanup() {
    case "$work_root" in
        /tmp/swift-ffmpeg-remote-release.*|/private/tmp/swift-ffmpeg-remote-release.*)
            /bin/rm -rf "$work_root"
            ;;
        *)
            echo "Refusing to clean unsafe verification root: $work_root" >&2
            ;;
    esac
}
trap cleanup EXIT HUP INT TERM

git_clean() {
    GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null \
    GIT_TERMINAL_PROMPT=0 \
    GIT_ASKPASS=/usr/bin/false \
    git -c core.hooksPath=/dev/null "$@"
}

source_repository="$REPOSITORY_URL"
artifact_source=""
fetch_protocol_arguments=(-c protocol.file.allow=never)
if [[ -n "$fixture_root" ]]; then
    [[ "$fixture_root" == /* ]] || {
        echo "Fixture root must be an absolute path" >&2
        exit 2
    }
    [[ -d "$fixture_root" && ! -L "$fixture_root" ]] || {
        echo "Fixture root is not a non-symlink directory: $fixture_root" >&2
        exit 2
    }
    fixture_root="$(cd "$fixture_root" && pwd -P)"
    source_repository="$fixture_root/repository"
    artifact_source="$fixture_root/$ARTIFACT_NAME"
    [[ -d "$source_repository" && ! -L "$source_repository" ]] || {
        echo "Fixture repository is missing: $source_repository" >&2
        exit 2
    }
    [[ -f "$artifact_source" && ! -L "$artifact_source" ]] || {
        echo "Fixture artifact is missing or is a symlink: $artifact_source" >&2
        exit 2
    }
    fetch_protocol_arguments=(-c protocol.file.allow=always)
fi

inspection_repository="$work_root/inspection.git"
git_clean init --bare --quiet "$inspection_repository"
git_clean -C "$inspection_repository" remote add origin "$source_repository"
git_clean "${fetch_protocol_arguments[@]}" -C "$inspection_repository" fetch \
    --quiet --force --no-tags --depth=1 origin \
    "+refs/tags/$tag:refs/tags/$tag"
inspected_revision="$(git_clean -C "$inspection_repository" \
    rev-parse --verify "refs/tags/$tag^{commit}")"
[[ "$inspected_revision" =~ ^[0-9a-f]{40}$ ]] || {
    echo "The exact tag did not resolve to a SHA-1 Git commit" >&2
    exit 1
}

tagged_manifest="$work_root/Package.swift"
git_clean -C "$inspection_repository" show \
    "$inspected_revision:Package.swift" >"$tagged_manifest"

manifest_arguments=(
    inspect-manifest
    --manifest "$tagged_manifest"
    --tag "$tag"
)
if [[ -n "$expected_checksum" ]]; then
    manifest_arguments+=(--expected-checksum "$expected_checksum")
fi
manifest_json="$("$python_command" "$HELPER" "${manifest_arguments[@]}")"
manifest_checksum="$(/bin/echo "$manifest_json" | "$python_command" -c \
    'import json,sys; print(json.load(sys.stdin)["checksum"])')"

downloaded_artifact="$work_root/$ARTIFACT_NAME"
if [[ -n "$fixture_root" ]]; then
    /bin/cp "$artifact_source" "$downloaded_artifact"
else
    require_command curl
    asset_url="https://github.com/vvisionnn/swift-ffmpeg/releases/download/$tag/$ARTIFACT_NAME"
    chunk_size=1048576
    chunk_start=0
    chunk_index=0
    asset_size=""
    /usr/bin/touch "$downloaded_artifact"
    while [[ -z "$asset_size" || "$chunk_start" -lt "$asset_size" ]]; do
        chunk_end=$((chunk_start + chunk_size - 1))
        chunk_headers="$work_root/download-headers"
        chunk_path="$work_root/download-chunk"
        /usr/bin/curl --disable --fail --location \
            --proto '=https' --proto-redir '=https' --tlsv1.2 \
            --range "${chunk_start}-${chunk_end}" \
            --retry 3 --retry-all-errors --retry-delay 2 \
            --connect-timeout 30 --speed-limit 1024 --speed-time 120 \
            --max-filesize "$chunk_size" --show-error --silent \
            --dump-header "$chunk_headers" \
            --output "$chunk_path" \
            "$asset_url"
        read -r observed_start observed_end observed_size < <(
            "$python_command" - "$chunk_headers" <<'PY'
from pathlib import Path
import re
import sys

headers = Path(sys.argv[1]).read_text(encoding="iso-8859-1")
matches = re.findall(
    r"(?im)^content-range:\s*bytes\s+([0-9]+)-([0-9]+)/([0-9]+)\s*$",
    headers,
)
if len(matches) != 1:
    raise SystemExit("release asset response lacks one exact Content-Range")
print(*matches[0])
PY
        )
        [[ "$observed_start" == "$chunk_start" ]] || {
            echo "Release asset returned an unexpected range start" >&2
            exit 1
        }
        [[ "$observed_end" =~ ^[0-9]+$ && "$observed_size" =~ ^[1-9][0-9]*$ ]] || {
            echo "Release asset returned malformed range metadata" >&2
            exit 1
        }
        ((observed_end >= observed_start && observed_end < observed_size)) || {
            echo "Release asset returned an invalid byte range" >&2
            exit 1
        }
        [[ -z "$asset_size" || "$asset_size" == "$observed_size" ]] || {
            echo "Release asset size changed during download" >&2
            exit 1
        }
        asset_size="$observed_size"
        ((asset_size <= 1073741824)) || {
            echo "Release asset exceeds the 1 GiB limit" >&2
            exit 1
        }
        expected_end="$chunk_end"
        if ((expected_end >= asset_size)); then
            expected_end=$((asset_size - 1))
        fi
        [[ "$observed_end" == "$expected_end" ]] || {
            echo "Release asset returned an incomplete byte range" >&2
            exit 1
        }
        chunk_bytes="$((observed_end - observed_start + 1))"
        [[ "$(/usr/bin/stat -f '%z' "$chunk_path")" == "$chunk_bytes" ]] || {
            echo "Release asset chunk length does not match Content-Range" >&2
            exit 1
        }
        /bin/dd \
            if="$chunk_path" \
            of="$downloaded_artifact" \
            bs="$chunk_size" \
            seek="$chunk_index" \
            conv=notrunc 2>/dev/null
        chunk_start=$((observed_end + 1))
        chunk_index=$((chunk_index + 1))
    done
    [[ "$(/usr/bin/stat -f '%z' "$downloaded_artifact")" == "$asset_size" ]] || {
        echo "Release asset assembly has an unexpected size" >&2
        exit 1
    }
fi
artifact_size="$("$python_command" - "$downloaded_artifact" <<'PY'
from pathlib import Path
import sys

print(Path(sys.argv[1]).stat().st_size)
PY
)"
if [[ ! "$artifact_size" =~ ^[1-9][0-9]*$ ]] || ((artifact_size > 1073741824)); then
    echo "Release asset size is outside the accepted 1 byte to 1 GiB range" >&2
    exit 1
fi
actual_checksum="$(swift package compute-checksum "$downloaded_artifact")"
assert_exact_value "Release asset checksum" "$manifest_checksum" "$actual_checksum"
if [[ -n "$expected_checksum" ]]; then
    assert_exact_value "Caller-provided release checksum" \
        "$expected_checksum" "$actual_checksum"
fi

if ((validation_only == 1)); then
    echo "Remote release metadata and asset validated"
    echo "Tag: $tag"
    echo "Revision: $inspected_revision"
    echo "Checksum: $actual_checksum"
    if [[ -n "$fixture_root" ]]; then
        echo "Mode: local fixture"
    else
        echo "Repository: $REPOSITORY_URL"
    fi
    exit 0
fi

dependency_url="$REPOSITORY_URL"
dependency_revision="$inspected_revision"
local_binary_environment=()
if [[ -n "$fixture_root" ]]; then
    if ! /usr/bin/grep -Fq 'SWIFT_FFMPEG_USE_LOCAL_XCFRAMEWORK' "$tagged_manifest"; then
        echo "Fixture package does not expose the local-XCFramework test switch" >&2
        exit 1
    fi
    fixture_package="$work_root/swift-ffmpeg"
    git_clean -c protocol.file.allow=always clone --quiet --no-checkout \
        "$source_repository" "$fixture_package"
    git_clean -C "$fixture_package" checkout --quiet --detach "$inspected_revision"
    "$python_command" "$HELPER" safe-extract \
        --archive "$downloaded_artifact" \
        --destination "$fixture_package/Artifacts"
    [[ -f "$fixture_package/Artifacts/FFmpeg.xcframework/Info.plist" ]] || {
        echo "Fixture asset did not contain FFmpeg.xcframework/Info.plist" >&2
        exit 1
    }
    git_clean -C "$fixture_package" add -f Artifacts/FFmpeg.xcframework
    GIT_AUTHOR_NAME="swift-ffmpeg verifier" \
    GIT_AUTHOR_EMAIL="verifier@invalid.example" \
    GIT_COMMITTER_NAME="swift-ffmpeg verifier" \
    GIT_COMMITTER_EMAIL="verifier@invalid.example" \
        git_clean -C "$fixture_package" commit --quiet \
            -m "test: materialize local release fixture"
    git_clean -C "$fixture_package" tag --force "$tag"
    dependency_revision="$(git_clean -C "$fixture_package" rev-parse HEAD)"
    dependency_url="file://$fixture_package"
    local_binary_environment=(SWIFT_FFMPEG_USE_LOCAL_XCFRAMEWORK=1)
fi

consumer="$work_root/RemoteReleaseConsumer"
/bin/mkdir -p \
    "$consumer/Sources/RemoteReleaseProbe" \
    "$consumer/Sources/RemoteReleaseProbeCLI" \
    "$consumer/Tests/RemoteReleaseProbeTests" \
    "$work_root/home" \
    "$work_root/module-cache"

/bin/cat >"$consumer/Package.swift" <<EOF
// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "RemoteReleaseConsumer",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(name: "RemoteReleaseProbe", targets: ["RemoteReleaseProbe"]),
        .executable(name: "RemoteReleaseProbeCLI", targets: ["RemoteReleaseProbeCLI"]),
    ],
    dependencies: [
        .package(url: "$dependency_url", exact: "$tag"),
    ],
    targets: [
        .target(
            name: "RemoteReleaseProbe",
            dependencies: [.product(name: "FFmpeg", package: "swift-ffmpeg")]
        ),
        .executableTarget(
            name: "RemoteReleaseProbeCLI",
            dependencies: ["RemoteReleaseProbe"]
        ),
        .testTarget(
            name: "RemoteReleaseProbeTests",
            dependencies: ["RemoteReleaseProbe"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
EOF

if [[ -n "$expected_ffmpeg_version" ]]; then
    expected_swift_literal="\"$expected_ffmpeg_version\""
else
    expected_swift_literal="nil"
fi
/bin/cat >"$consumer/Sources/RemoteReleaseProbe/Probe.swift" <<EOF
import FFmpeg

public let expectedFFmpegVersion: String? = $expected_swift_literal

public func linkedFFmpegVersion() -> String {
    String(cString: av_version_info())
}

public func hasExpectedFFmpegVersion() -> Bool {
    let actual = linkedFFmpegVersion()
    if let expectedFFmpegVersion {
        return actual == expectedFFmpegVersion
    }
    return !actual.isEmpty && actual.first?.isNumber == true
}
EOF

/bin/cat >"$consumer/Sources/RemoteReleaseProbeCLI/main.swift" <<'EOF'
import RemoteReleaseProbe

let actual = linkedFFmpegVersion()
precondition(hasExpectedFFmpegVersion(), "Unexpected linked FFmpeg version: \(actual)")
print("FFmpeg \(actual)")
EOF

/bin/cat >"$consumer/Tests/RemoteReleaseProbeTests/RemoteReleaseProbeTests.swift" <<'EOF'
import XCTest
@testable import RemoteReleaseProbe

final class RemoteReleaseProbeTests: XCTestCase {
    func testImportsLinksAndCallsFFmpeg() {
        XCTAssertTrue(hasExpectedFFmpegVersion(), linkedFFmpegVersion())
    }
}
EOF

if /usr/bin/grep -Eq 'linkerSettings|unsafeFlags' "$consumer/Package.swift"; then
    echo "Generated consumer unexpectedly contains linker configuration" >&2
    exit 1
fi

consumer_env=(
    HOME="$work_root/home"
    CLANG_MODULE_CACHE_PATH="$work_root/module-cache"
    "${local_binary_environment[@]}"
)
swift_scratch="$work_root/swift-build"
/usr/bin/env -u SWIFTPM_MIRROR_CONFIG "${consumer_env[@]}" \
    swift package --package-path "$consumer" --scratch-path "$swift_scratch" resolve
"$python_command" "$HELPER" verify-resolved \
    --resolved "$consumer/Package.resolved" \
    --tag "$tag" \
    --repository "$dependency_url" \
    --revision "$dependency_revision"

macos_log="$work_root/macos-run.log"
if ! /usr/bin/env -u SWIFTPM_MIRROR_CONFIG "${consumer_env[@]}" \
    swift run --package-path "$consumer" --scratch-path "$swift_scratch" \
        RemoteReleaseProbeCLI >"$macos_log" 2>&1; then
    /usr/bin/tail -100 "$macos_log" >&2 || true
    exit 1
fi
runtime_line="$(/usr/bin/tail -1 "$macos_log")"
[[ "$runtime_line" == FFmpeg\ * ]] || {
    echo "macOS runtime probe did not report an FFmpeg version" >&2
    /usr/bin/tail -100 "$macos_log" >&2 || true
    exit 1
}

require_command xcodebuild
require_command xcrun
xcode_source_packages="$work_root/XcodeSourcePackages"
xcode_resolve_log="$work_root/xcode-resolve.log"
if ! (cd "$consumer" && /usr/bin/env -u SWIFTPM_MIRROR_CONFIG \
    "${consumer_env[@]}" xcodebuild -resolvePackageDependencies \
        -clonedSourcePackagesDirPath "$xcode_source_packages" \
        >"$xcode_resolve_log" 2>&1); then
    /usr/bin/tail -100 "$xcode_resolve_log" >&2 || true
    exit 1
fi

scheme_list="$work_root/xcode-schemes.json"
if ! (cd "$consumer" && /usr/bin/env -u SWIFTPM_MIRROR_CONFIG \
    "${consumer_env[@]}" xcodebuild -list -json \
        -clonedSourcePackagesDirPath "$xcode_source_packages" \
        >"$scheme_list" 2>&1); then
    /usr/bin/tail -100 "$scheme_list" >&2 || true
    exit 1
fi
consumer_scheme="$("$python_command" - "$scheme_list" <<'PY'
import json
from pathlib import Path
import sys

document = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
schemes = document.get("workspace", {}).get("schemes", [])
if not schemes:
    schemes = document.get("project", {}).get("schemes", [])
preferred = (
    "RemoteReleaseConsumer-Package",
    "RemoteReleaseConsumer",
    "RemoteReleaseProbe",
)
selected = next((name for name in preferred if name in schemes), None)
if selected is None:
    raise SystemExit(f"Cannot select the external consumer scheme from: {schemes!r}")
print(selected)
PY
)"

device_log="$work_root/ios-device-build.log"
if ! (cd "$consumer" && /usr/bin/env -u SWIFTPM_MIRROR_CONFIG \
    "${consumer_env[@]}" xcodebuild build-for-testing -quiet \
        -scheme "$consumer_scheme" \
        -configuration Debug \
        -destination 'generic/platform=iOS' \
        -derivedDataPath "$work_root/DeviceDerivedData" \
        -clonedSourcePackagesDirPath "$xcode_source_packages" \
        -disableAutomaticPackageResolution \
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
        >"$device_log" 2>&1); then
    /usr/bin/tail -100 "$device_log" >&2 || true
    exit 1
fi

simulator_status="skipped (no available iPhone Simulator)"
devices_json="$work_root/simulator-devices.json"
if xcrun simctl list devices available -j >"$devices_json" 2>/dev/null; then
    simulator_selection="$("$python_command" - "$devices_json" <<'PY' || true
import json
from pathlib import Path
import re
import sys

document = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
candidates = []
for runtime, devices in document.get("devices", {}).items():
    if ".SimRuntime.iOS-" not in runtime:
        continue
    version_match = re.search(r"iOS-([0-9-]+)$", runtime)
    version = tuple(int(part) for part in version_match.group(1).split("-")) if version_match else ()
    for device in devices:
        if not device.get("isAvailable", False):
            continue
        if ".iPhone-" not in device.get("deviceTypeIdentifier", ""):
            continue
        candidates.append((version, device.get("state") == "Booted", device["udid"], device["name"]))
if candidates:
    version, booted, udid, name = sorted(candidates, key=lambda item: (item[0], item[1], item[3], item[2]), reverse=True)[0]
    print(udid)
    print(name)
PY
)"
    simulator_udid="$(/bin/echo "$simulator_selection" | /usr/bin/sed -n '1p')"
    simulator_name="$(/bin/echo "$simulator_selection" | /usr/bin/sed -n '2p')"
    if [[ "$simulator_udid" =~ ^[0-9A-Fa-f-]{36}$ ]]; then
        xcrun simctl boot "$simulator_udid" >/dev/null 2>&1 || true
        xcrun simctl bootstatus "$simulator_udid" -b >/dev/null
        simulator_log="$work_root/ios-simulator-test.log"
        if ! (cd "$consumer" && /usr/bin/env -u SWIFTPM_MIRROR_CONFIG \
            "${consumer_env[@]}" xcodebuild test -quiet \
                -scheme "$consumer_scheme" \
                -configuration Debug \
                -destination "platform=iOS Simulator,id=$simulator_udid" \
                -derivedDataPath "$work_root/SimulatorDerivedData" \
                -clonedSourcePackagesDirPath "$xcode_source_packages" \
                -disableAutomaticPackageResolution \
                -resultBundlePath "$work_root/RemoteReleaseTests.xcresult" \
                CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
                >"$simulator_log" 2>&1); then
            /usr/bin/tail -100 "$simulator_log" >&2 || true
            exit 1
        fi
        simulator_status="passed on $simulator_name ($simulator_udid)"
    fi
fi

echo "Clean external release consumer passed"
echo "Tag: $tag"
echo "Revision: $dependency_revision"
echo "Checksum: $actual_checksum"
echo "macOS runtime: $runtime_line"
echo "Generic iOS device build-for-testing: passed"
echo "iOS Simulator execution: $simulator_status"
if [[ -n "$fixture_root" ]]; then
    echo "Mode: local exact-version fixture"
else
    echo "Repository: $REPOSITORY_URL"
fi
