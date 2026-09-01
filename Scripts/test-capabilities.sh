#!/bin/bash -p

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

python3 -I -B -m unittest discover \
    -s "$PROJECT_ROOT/Tests/CapabilityTests" \
    -p 'test_*.py' \
    -v
python3 -I -B "$SCRIPT_DIR/check-capabilities.py"
