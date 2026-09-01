#!/bin/bash -p

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
reject_shell_startup_environment
load_release_configuration

"$SCRIPT_DIR/validate-artifact.sh"
require_command xcodebuild
require_command xcrun

evidence_root="${SWIFT_FFMPEG_SIMULATOR_OUTPUT_PATH:-$PROJECT_ROOT/.build/simulator-tests}"
case "$evidence_root" in
    "$PROJECT_ROOT/.build/"*|"${RUNNER_TEMP:-/tmp}/swift-ffmpeg-"*) ;;
    *)
        echo "Unsafe Simulator output path: $evidence_root" >&2
        exit 1
        ;;
esac
/bin/rm -rf "$evidence_root"
mkdir -p "$evidence_root"
runtimes_json="$evidence_root/runtimes.json"
devices_json="$evidence_root/devices.json"
xcrun simctl list runtimes available -j >"$runtimes_json"
xcrun simctl list devices available -j >"$devices_json"

runtime_identifier="$(jq -er '
    [.runtimes[]
        | select(.platform == "iOS" and .isAvailable == true)
        | select(.version | test("^[0-9]+([.][0-9]+)*$"))
    ]
    | sort_by(.version | split(".") | map(tonumber))
    | last.identifier // empty
' "$runtimes_json")"

if [[ -n "${SWIFT_FFMPEG_SIMULATOR_UDID:-}" ]]; then
    simulator_udid="$SWIFT_FFMPEG_SIMULATOR_UDID"
    jq -e --arg runtime "$runtime_identifier" --arg udid "$simulator_udid" '
        any(.devices[$runtime][]?; .udid == $udid and .isAvailable == true)
    ' "$devices_json" >/dev/null
else
    simulator_udid="$(jq -er --arg runtime "$runtime_identifier" '
        [.devices[$runtime][]?
            | select(.isAvailable == true)
            | select(.deviceTypeIdentifier | contains(".iPhone-"))
        ]
        | sort_by(
            (if .state == "Booted" then 0 else 1 end),
            .name,
            .udid
          )
        | first.udid // empty
    ' "$devices_json")"
fi
[[ "$simulator_udid" =~ ^[0-9A-Fa-f-]{36}$ ]] || {
    echo "Selected Simulator has an invalid UDID" >&2
    exit 1
}
simulator_name="$(jq -er --arg runtime "$runtime_identifier" --arg udid "$simulator_udid" '
    [.devices[$runtime][]? | select(.udid == $udid and .isAvailable == true)]
    | if length == 1 then .[0].name else error("Simulator is not unique") end
' "$devices_json")"

xcrun simctl boot "$simulator_udid" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$simulator_udid" -b >/dev/null

derived_data="$evidence_root/DerivedData"
build_log="$evidence_root/build-for-testing.log"
test_log="$evidence_root/test-without-building.log"
start_epoch="$(date +%s)"
if ! SWIFT_FFMPEG_USE_LOCAL_XCFRAMEWORK=1 xcodebuild build-for-testing \
    -quiet \
    -scheme swift-ffmpeg \
    -configuration Debug \
    -destination "platform=iOS Simulator,id=$simulator_udid" \
    -derivedDataPath "$derived_data" \
    -disableAutomaticPackageResolution \
    >"$build_log" 2>&1; then
    /usr/bin/tail -100 "$build_log" >&2 || true
    exit 1
fi

xctestrun_list="$evidence_root/xctestrun-files.txt"
/usr/bin/find "$derived_data/Build/Products" -maxdepth 1 -type f \
    -name '*.xctestrun' -print | LC_ALL=C /usr/bin/sort >"$xctestrun_list"
xctestrun_count="$(/usr/bin/wc -l <"$xctestrun_list" | /usr/bin/tr -d '[:space:]')"
assert_exact_value "Simulator xctestrun count" "1" "$xctestrun_count"
xctestrun="$(/usr/bin/sed -n '1p' "$xctestrun_list")"

if ! xcodebuild test-without-building \
    -quiet \
    -xctestrun "$xctestrun" \
    -destination "platform=iOS Simulator,id=$simulator_udid" \
    -resultBundlePath "$evidence_root/FFmpegTests.xcresult" \
    >"$test_log" 2>&1; then
    /usr/bin/tail -100 "$test_log" >&2 || true
    exit 1
fi
duration_seconds="$(( $(date +%s) - start_epoch ))"

jq -n -S \
    --arg durationSeconds "$duration_seconds" \
    --arg runtime "$runtime_identifier" \
    --arg simulatorName "$simulator_name" \
    --arg simulatorUDID "$simulator_udid" \
    '{
      schemaVersion: 1,
      durationSeconds: ($durationSeconds | tonumber),
      runtime: $runtime,
      simulatorName: $simulatorName,
      simulatorUDID: $simulatorUDID,
      result: "pass"
    }' >"$evidence_root/summary.json"

echo "iOS Simulator tests passed on $simulator_name ($simulator_udid)"
