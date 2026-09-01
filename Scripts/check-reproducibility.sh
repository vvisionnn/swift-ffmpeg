#!/bin/bash -p

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
reject_shell_startup_environment
load_release_configuration

mode="${1:---full}"
case "$mode" in
    --full|--package-only) ;;
    *)
        echo "usage: $0 [--full|--package-only]" >&2
        exit 2
        ;;
esac

evidence_root="$PROJECT_ROOT/.artifacts/reproducibility"
/bin/rm -rf "$evidence_root"
mkdir -p "$evidence_root"
first_started="$(date +%s)"

for attempt in 1 2; do
    attempt_root="$evidence_root/attempt-$attempt"
    mkdir -p "$attempt_root"
    if [[ "$mode" == "--full" ]]; then
        SWIFT_FFMPEG_BUILD_ROOT="$PROJECT_ROOT/.build/ffmpeg-repro-$attempt" \
            "$SCRIPT_DIR/build-xcframework.sh"
    fi
    "$SCRIPT_DIR/validate-artifact.sh"
    "$SCRIPT_DIR/package-xcframework.sh"
    /bin/cp "$RELEASE_ZIP" "$attempt_root/$ARTIFACT_NAME"
    (
        cd "$LOCAL_ARTIFACT_ROOT"
        /usr/bin/find FFmpeg.xcframework -type f -print |
            LC_ALL=C /usr/bin/sort |
            while IFS= read -r path; do
                /usr/bin/shasum -a 256 "$path"
            done
    ) >"$attempt_root/xcframework-files.sha256"
    swift package compute-checksum "$attempt_root/$ARTIFACT_NAME" \
        >"$attempt_root/swiftpm-checksum.txt"
done

/usr/bin/cmp -s \
    "$evidence_root/attempt-1/$ARTIFACT_NAME" \
    "$evidence_root/attempt-2/$ARTIFACT_NAME" || {
    echo "Independent release ZIPs are not reproducible" >&2
    exit 1
}
/usr/bin/cmp -s \
    "$evidence_root/attempt-1/xcframework-files.sha256" \
    "$evidence_root/attempt-2/xcframework-files.sha256" || {
    echo "Independent XCFramework file manifests differ" >&2
    exit 1
}
/usr/bin/cmp -s \
    "$evidence_root/attempt-1/swiftpm-checksum.txt" \
    "$evidence_root/attempt-2/swiftpm-checksum.txt" || {
    echo "Independent SwiftPM checksums differ" >&2
    exit 1
}

duration_seconds="$(( $(date +%s) - first_started ))"
jq -n -S \
    --arg checksum "$ARTIFACT_CHECKSUM" \
    --arg durationSeconds "$duration_seconds" \
    --arg mode "${mode#--}" \
    '{
      schemaVersion: 1,
      checksum: $checksum,
      durationSeconds: ($durationSeconds | tonumber),
      mode: $mode,
      attempts: 2,
      result: "pass"
    }' >"$evidence_root/summary.json"

echo "Reproducibility passed: $ARTIFACT_CHECKSUM"
