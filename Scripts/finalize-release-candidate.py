#!/usr/bin/env python3
"""Finalize a release candidate from its exact binary and capability outputs."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys

from lib.release_candidate import (
    CandidateError,
    atomic_write_documents,
    checked_input_path,
    finalize_candidate_documents,
    preflight_paths,
    read_json_path,
    read_package_path,
    render_json,
)


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate-config", type=Path, required=True)
    parser.add_argument("--candidate-package", type=Path, required=True)
    parser.add_argument("--xcframework", type=Path, required=True)
    parser.add_argument("--release-zip", type=Path, required=True)
    parser.add_argument("--capability-oracle", type=Path, required=True)
    parser.add_argument("--built-capabilities", type=Path, required=True)
    parser.add_argument("--output-config", type=Path, required=True)
    parser.add_argument("--output-package", type=Path, required=True)
    parser.add_argument("--output-capability-oracle", type=Path, required=True)
    return parser.parse_args()


def main() -> int:
    options = arguments()
    inputs = [
        options.candidate_config,
        options.candidate_package,
        options.xcframework,
        options.release_zip,
        options.capability_oracle,
        options.built_capabilities,
    ]
    outputs = [
        options.output_config,
        options.output_package,
        options.output_capability_oracle,
    ]
    preflight_paths(inputs, outputs)
    checked_input_path(options.xcframework, "XCFramework", directory=True)
    checked_input_path(options.release_zip, "release ZIP")
    candidate = read_json_path(options.candidate_config, "candidate configuration")
    package = read_package_path(options.candidate_package)
    reviewed_capabilities = read_json_path(
        options.capability_oracle, "reviewed capability oracle"
    )
    built_capabilities = read_json_path(
        options.built_capabilities, "built capability manifest"
    )
    final_config, final_package, final_capabilities, digests = (
        finalize_candidate_documents(
            candidate,
            package,
            options.xcframework,
            options.release_zip,
            reviewed_capabilities,
            built_capabilities,
        )
    )
    atomic_write_documents(
        {
            options.output_config: render_json(final_config),
            options.output_package: final_package.encode("utf-8"),
            options.output_capability_oracle: render_json(final_capabilities),
        }
    )
    json.dump(digests, sys.stdout, sort_keys=True)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except CandidateError as error:
        print(f"candidate finalization failed: {error}", file=sys.stderr)
        raise SystemExit(2) from error
