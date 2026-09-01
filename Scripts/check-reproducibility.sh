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
case "$evidence_root" in
    "$PROJECT_ROOT/.artifacts/"*) ;;
    *)
        echo "Unsafe reproducibility evidence root: $evidence_root" >&2
        exit 1
        ;;
esac
/bin/rm -rf "$evidence_root"
mkdir -p "$evidence_root"
first_started="$(date +%s)"
selected_developer_dir="${DEVELOPER_DIR:-$(/usr/bin/xcode-select -p)}"

copy_checkout() {
    local destination="$1"
    local relative_path

    mkdir -p "$destination"
    while IFS= read -r -d '' relative_path; do
        case "/$relative_path/" in
            */../*|*/./*)
                echo "Unsafe tracked path: $relative_path" >&2
                exit 1
                ;;
        esac
        mkdir -p "$destination/$(/usr/bin/dirname "$relative_path")"
        /bin/cp -pP "$PROJECT_ROOT/$relative_path" "$destination/$relative_path"
    done < <(git -C "$PROJECT_ROOT" ls-files -z)

    mkdir -p "$destination/.cache/sources"
    /bin/cp -p \
        "$FFMPEG_TARBALL" \
        "$FFMPEG_SIGNATURE" \
        "$DAV1D_TARBALL" \
        "$destination/.cache/sources/"
}

for attempt in 1 2; do
    attempt_root="$evidence_root/attempt-$attempt"
    mkdir -p "$attempt_root"
    if [[ "$mode" == "--full" ]]; then
        checkout_root="$attempt_root/checkout-$attempt"
        developer_alias="$attempt_root/XcodeDeveloper-$attempt"
        copy_checkout "$checkout_root"
        /bin/ln -s "$selected_developer_dir" "$developer_alias"
        (
            cd "$checkout_root"
            DEVELOPER_DIR="$developer_alias" \
                ./Scripts/build-xcframework.sh
            ./Scripts/validate-artifact.sh
            ./Scripts/package-xcframework.sh
        )
        attempt_xcframework="$checkout_root/Artifacts/FFmpeg.xcframework"
        attempt_zip="$checkout_root/.artifacts/release/$ARTIFACT_NAME"
    else
        "$SCRIPT_DIR/validate-artifact.sh"
        "$SCRIPT_DIR/package-xcframework.sh"
        attempt_xcframework="$XCFRAMEWORK"
        attempt_zip="$RELEASE_ZIP"
    fi
    /bin/cp "$attempt_zip" "$attempt_root/$ARTIFACT_NAME"
    (
        cd "$(/usr/bin/dirname "$attempt_xcframework")"
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
