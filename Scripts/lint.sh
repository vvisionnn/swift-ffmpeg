#!/bin/bash -p

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=Scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
reject_shell_startup_environment
load_release_configuration

require_command actionlint
require_command shellcheck

shell_scripts="$(
    /usr/bin/find "$SCRIPT_DIR" -type f -name '*.sh' -print |
        LC_ALL=C /usr/bin/sort
)"
while IFS= read -r script_path; do
    if [[ "$script_path" != "$SCRIPT_DIR/lib/common.sh" ]]; then
        [[ -x "$script_path" ]] || {
            echo "Shell entry point is not executable: $script_path" >&2
            exit 1
        }
    fi
    /bin/bash -n "$script_path"
done <<<"$shell_scripts"
# Common is sourced rather than executed, so executable mode is not required.
shellcheck --severity=warning $shell_scripts

workflow_files="$(
    /usr/bin/find "$PROJECT_ROOT/.github/workflows" -type f \
        \( -name '*.yml' -o -name '*.yaml' \) -print 2>/dev/null |
        LC_ALL=C /usr/bin/sort || true
)"
if [[ -n "$workflow_files" ]]; then
    actionlint $workflow_files
fi

jq -e '.schemaVersion == 1' "$RELEASE_CONFIG" >/dev/null
/usr/bin/plutil -lint \
    "$PROJECT_ROOT/Sources/FFmpegLinkerSupport/PrivacyInfo.xcprivacy" >/dev/null
(
    cd "$PROJECT_ROOT"
    env -u SWIFT_FFMPEG_USE_LOCAL_XCFRAMEWORK \
        swift package dump-package >/dev/null
    SWIFT_FFMPEG_USE_LOCAL_XCFRAMEWORK=1 \
        swift package dump-package >/dev/null
    git diff --check
)

tracked_binary="$(
    git -C "$PROJECT_ROOT" ls-files |
        /usr/bin/grep -E '\.(a|bz2|tar|tar\.xz|xcframework|zip)$' |
        /usr/bin/head -1 || true
)"
[[ -z "$tracked_binary" ]] || {
    echo "Generated binary/source archive must not be tracked: $tracked_binary" >&2
    exit 1
}

echo "Repository lint passed"
