#!/bin/bash -p

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=Scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
reject_shell_startup_environment
require_command git
require_command python3

run_full_fixture=0
if (($# > 1)); then
    echo "Usage: Scripts/test-remote-release.sh [--full]" >&2
    exit 2
fi
if (($# == 1)); then
    [[ "$1" == "--full" ]] || {
        echo "Unknown argument: $1" >&2
        exit 2
    }
    run_full_fixture=1
fi

python3 -m unittest discover \
    -s "$PROJECT_ROOT/Tests/RemoteReleaseTests" \
    -p 'test_*.py' \
    -v

fixture_root="$(/usr/bin/mktemp -d /tmp/swift-ffmpeg-remote-fixture.XXXXXX)"
case "$fixture_root" in
    /tmp/swift-ffmpeg-remote-fixture.*|/private/tmp/swift-ffmpeg-remote-fixture.*) ;;
    *)
        echo "mktemp returned an unsafe fixture root: $fixture_root" >&2
        exit 1
        ;;
esac
cleanup() {
    case "$fixture_root" in
        /tmp/swift-ffmpeg-remote-fixture.*|/private/tmp/swift-ffmpeg-remote-fixture.*)
            /bin/rm -rf "$fixture_root"
            ;;
        *)
            echo "Refusing to clean unsafe fixture root: $fixture_root" >&2
            ;;
    esac
}
trap cleanup EXIT HUP INT TERM

release_zip="$PROJECT_ROOT/.artifacts/release/FFmpeg.xcframework.zip"
[[ -f "$release_zip" && ! -L "$release_zip" ]] || {
    echo "Build the local release artifact before running the fixture test" >&2
    exit 1
}
checksum="$(swift package compute-checksum "$release_zip")"
package_version="$(python3 - "$PROJECT_ROOT/Configuration/release.json" <<'PY'
from pathlib import Path
import json
import sys

document = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print(document["packageVersion"])
PY
)"
ffmpeg_version="$(python3 - "$PROJECT_ROOT/Configuration/release.json" <<'PY'
from pathlib import Path
import json
import sys

document = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
print(document["ffmpeg"]["version"])
PY
)"
configured_checksum="$(python3 - "$PROJECT_ROOT/Package.swift" <<'PY'
from pathlib import Path
import re
import sys

manifest = Path(sys.argv[1]).read_text(encoding="utf-8")
matches = re.findall(r'checksum\s*:\s*"([0-9a-f]{64})"', manifest)
if len(matches) != 1:
    raise SystemExit("Package.swift does not contain exactly one binary checksum")
print(matches[0])
PY
)"
assert_exact_value "Local fixture checksum" "$configured_checksum" "$checksum"

git clone --quiet --no-hardlinks "$PROJECT_ROOT" "$fixture_root/repository"
git -C "$fixture_root/repository" tag --force "$package_version"
/bin/cp "$release_zip" "$fixture_root/FFmpeg.xcframework.zip"

verification_arguments=(
    --tag "$package_version"
    --expected-ffmpeg-version "$ffmpeg_version"
    --expected-checksum "$checksum"
    --fixture-root "$fixture_root"
)
if ((run_full_fixture == 0)); then
    verification_arguments+=(--validation-only)
fi
"$SCRIPT_DIR/verify-remote-release.sh" "${verification_arguments[@]}"

if ((run_full_fixture == 1)); then
    echo "Remote-release verifier unit and full local consumer tests passed"
else
    echo "Remote-release verifier unit and fixture-validation tests passed"
    echo "Run Scripts/test-remote-release.sh --full for macOS/iOS consumer proof"
fi
