#!/usr/bin/env python3
"""Generate build-ready release candidate files from trusted discovery data."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

from lib.release_candidate import (
    CandidateError,
    atomic_write_documents,
    generate_candidate_documents,
    preflight_paths,
    read_json_path,
    read_package_path,
    render_json,
)


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-config", type=Path, required=True)
    parser.add_argument("--base-package", type=Path, required=True)
    parser.add_argument("--discovery", type=Path, required=True)
    parser.add_argument("--ffmpeg-source-sha256", required=True)
    parser.add_argument("--output-config", type=Path, required=True)
    parser.add_argument("--output-package", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    options = arguments()
    inputs = [options.base_config, options.base_package, options.discovery]
    outputs = [options.output_config, options.output_package]
    preflight_paths(inputs, outputs)
    base_config = read_json_path(options.base_config, "base release configuration")
    base_package = read_package_path(options.base_package)
    discovery = read_json_path(options.discovery, "FFmpeg discovery document")
    candidate, package = generate_candidate_documents(
        base_config,
        base_package,
        discovery,
        options.ffmpeg_source_sha256,
    )
    atomic_write_documents(
        {
            options.output_config: render_json(candidate),
            options.output_package: package.encode("utf-8"),
        }
    )
    json.dump(
        {
            "ffmpegVersion": candidate["ffmpeg"]["version"],
            "packageVersion": candidate["packageVersion"],
            "sourceSHA256": candidate["ffmpeg"]["sha256"],
        },
        sys.stdout,
        sort_keys=True,
    )
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except CandidateError as error:
        print(f"candidate generation failed: {error}", file=sys.stderr)
        raise SystemExit(2) from error
