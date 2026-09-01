#!/usr/bin/env python3
"""Discover the canonical current stable FFmpeg source release."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from lib.ffmpeg_release_discovery import (
    CANONICAL_DOWNLOAD_URL,
    DiscoveryError,
    discover_document,
    load_configured_version,
    load_document,
    render_json,
)


def _arguments() -> argparse.Namespace:
    project_root = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(
        description=(
            "Discover the current stable FFmpeg release from its canonical "
            "download page and reject ambiguous or rollback results."
        )
    )
    parser.add_argument(
        "--source",
        default=CANONICAL_DOWNLOAD_URL,
        help=(
            "Canonical download-page URL or a local HTML fixture path "
            f"(default: {CANONICAL_DOWNLOAD_URL})"
        ),
    )
    parser.add_argument(
        "--config",
        type=Path,
        default=project_root / "Configuration" / "release.json",
        help="Release configuration containing the currently packaged FFmpeg version",
    )
    parser.add_argument(
        "--timeout",
        type=float,
        default=30.0,
        help="HTTPS fetch timeout in seconds (default: 30)",
    )
    arguments = parser.parse_args()
    if not 0 < arguments.timeout <= 120:
        parser.error("--timeout must be greater than 0 and at most 120 seconds")
    return arguments


def main() -> int:
    arguments = _arguments()
    try:
        configured_version = load_configured_version(arguments.config)
        document = load_document(arguments.source, arguments.timeout)
        result = discover_document(document, configured_version)
    except DiscoveryError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    sys.stdout.write(render_json(result))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
