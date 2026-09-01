#!/usr/bin/env python3
"""Link every FFmpeg slice and compare its capabilities with a reviewed oracle."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
from typing import Any, Sequence


SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR.parent
sys.path.insert(0, str(SCRIPT_DIR / "lib"))

from capability_manifest import (  # noqa: E402
    ManifestError,
    REGISTRATION_CATEGORIES,
    RUNTIME_CATEGORIES,
    compare_capability_groups,
    extract_registration_symbols,
    parse_reviewed_manifest,
    parse_runtime_report,
    reviewed_manifest_document,
)


class CheckError(RuntimeError):
    pass


class Slice:
    def __init__(
        self,
        label: str,
        directory: str,
        architecture: str,
        sdk: str,
        deployment_flag: str,
        macos: bool = False,
    ) -> None:
        self.label = label
        self.directory = directory
        self.architecture = architecture
        self.sdk = sdk
        self.deployment_flag = deployment_flag
        self.macos = macos


SLICES = (
    Slice("ios-device/arm64", "ios-arm64", "arm64", "iphoneos", "-miphoneos-version-min"),
    Slice(
        "ios-simulator/arm64",
        "ios-arm64_x86_64-simulator",
        "arm64",
        "iphonesimulator",
        "-mios-simulator-version-min",
    ),
    Slice(
        "ios-simulator/x86_64",
        "ios-arm64_x86_64-simulator",
        "x86_64",
        "iphonesimulator",
        "-mios-simulator-version-min",
    ),
    Slice(
        "macos/arm64",
        "macos-arm64_x86_64",
        "arm64",
        "macosx",
        "-mmacosx-version-min",
        macos=True,
    ),
    Slice(
        "macos/x86_64",
        "macos-arm64_x86_64",
        "x86_64",
        "macosx",
        "-mmacosx-version-min",
        macos=True,
    ),
)


def run(command: Sequence[str], *, capture: bool = False) -> str:
    try:
        completed = subprocess.run(
            command,
            check=True,
            text=True,
            stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
    except FileNotFoundError as error:
        raise CheckError(f"Required tool is unavailable: {command[0]}") from error
    except subprocess.CalledProcessError as error:
        rendered = " ".join(command)
        stderr = error.stderr.strip() if error.stderr else "no diagnostic output"
        raise CheckError(f"Command failed: {rendered}\n{stderr}") from error
    return completed.stdout if capture and completed.stdout is not None else ""


def xcrun(sdk: str, *arguments: str) -> str:
    return run(("/usr/bin/xcrun", "--sdk", sdk, *arguments), capture=True).strip()


def load_json(path: Path) -> Any:
    try:
        with path.open("r", encoding="utf-8") as stream:
            return json.load(stream)
    except (OSError, json.JSONDecodeError) as error:
        raise CheckError(f"Cannot read JSON document {path}: {error}") from error


def release_values(path: Path) -> tuple[str, str, str]:
    document = load_json(path)
    try:
        ffmpeg_version = document["ffmpeg"]["version"]
        ios_minimum = document["build"]["iOSMinimumVersion"]
        macos_minimum = document["build"]["macOSMinimumVersion"]
    except (KeyError, TypeError) as error:
        raise CheckError(f"Release configuration is missing {error}") from error
    if not all(isinstance(value, str) for value in (ffmpeg_version, ios_minimum, macos_minimum)):
        raise CheckError("Release capability inputs must be strings")
    return ffmpeg_version, ios_minimum, macos_minimum


def compile_reporter(
    slice_spec: Slice,
    xcframework: Path,
    output: Path,
    ios_minimum: str,
    macos_minimum: str,
) -> None:
    slice_root = xcframework / slice_spec.directory
    archive = slice_root / "libFFmpeg.a"
    headers = slice_root / "Headers"
    if not archive.is_file() or not headers.is_dir():
        raise CheckError(f"Missing XCFramework slice inputs under {slice_root}")

    compiler = xcrun(slice_spec.sdk, "--find", "clang")
    sdk_root = xcrun(slice_spec.sdk, "--show-sdk-path")
    minimum = macos_minimum if slice_spec.macos else ios_minimum
    command = [
        compiler,
        "-std=c11",
        "-Wall",
        "-Wextra",
        "-Werror",
        "-O2",
        "-arch",
        slice_spec.architecture,
        "-isysroot",
        sdk_root,
        f"{slice_spec.deployment_flag}={minimum}",
        "-I",
        str(headers),
        str(SCRIPT_DIR / "support" / "report-capabilities.c"),
        str(archive),
    ]
    for framework in (
        "AudioToolbox",
        "CoreFoundation",
        "CoreMedia",
        "CoreVideo",
        "Security",
        "VideoToolbox",
    ):
        command.extend(("-framework", framework))
    if slice_spec.macos:
        command.extend(("-framework", "CoreServices"))
    command.extend(("-lbz2", "-liconv", "-lz", "-o", str(output)))
    run(command)


def registrations_for_slice(
    slice_spec: Slice, xcframework: Path
) -> dict[str, tuple[str, ...]]:
    archive = xcframework / slice_spec.directory / "libFFmpeg.a"
    nm_output = run(
        ("/usr/bin/nm", "-arch", slice_spec.architecture, str(archive)),
        capture=True,
    )
    return dict(extract_registration_symbols(nm_output))


def native_macos_slice() -> Slice:
    machine = platform.machine()
    for slice_spec in SLICES:
        if slice_spec.macos and slice_spec.architecture == machine:
            return slice_spec
    raise CheckError(f"Capability execution is unsupported on host architecture {machine}")


def collect(
    xcframework: Path,
    ios_minimum: str,
    macos_minimum: str,
    expected_registrations: dict[str, Sequence[str]] | None,
) -> tuple[dict[str, tuple[str, ...]], dict[str, tuple[str, ...]]]:
    native = native_macos_slice()
    native_report: dict[str, tuple[str, ...]] | None = None
    reference_registrations: dict[str, tuple[str, ...]] | None = None

    with tempfile.TemporaryDirectory(prefix="swift-ffmpeg-capabilities-") as temporary:
        output_root = Path(temporary)
        for index, slice_spec in enumerate(SLICES):
            output = output_root / f"reporter-{index}"
            compile_reporter(
                slice_spec,
                xcframework,
                output,
                ios_minimum,
                macos_minimum,
            )
            print(f"Linked capability reporter for {slice_spec.label}", file=sys.stderr)

            registrations = registrations_for_slice(slice_spec, xcframework)
            if expected_registrations is not None:
                compare_capability_groups(
                    expected_registrations,
                    registrations,
                    REGISTRATION_CATEGORIES,
                    f"registrationSymbols[{slice_spec.label}]",
                )
            elif reference_registrations is None:
                reference_registrations = registrations
            else:
                compare_capability_groups(
                    reference_registrations,
                    registrations,
                    REGISTRATION_CATEGORIES,
                    f"registrationSymbols[{slice_spec.label}]",
                )

            if slice_spec is native:
                report_document = json.loads(run((str(output),), capture=True))
                native_report = dict(parse_runtime_report(report_document))
                print(
                    f"Executed capability reporter for {slice_spec.label}",
                    file=sys.stderr,
                )

    if native_report is None or reference_registrations is None and expected_registrations is None:
        raise CheckError("Capability collection did not produce complete results")
    return native_report, reference_registrations or dict(expected_registrations or {})


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--manifest",
        type=Path,
        default=PROJECT_ROOT / "Configuration" / "capabilities.json",
        help="reviewed capability oracle",
    )
    parser.add_argument(
        "--release-config",
        type=Path,
        default=PROJECT_ROOT / "Configuration" / "release.json",
    )
    parser.add_argument(
        "--xcframework",
        type=Path,
        default=PROJECT_ROOT / "Artifacts" / "FFmpeg.xcframework",
    )
    parser.add_argument(
        "--emit-manifest",
        action="store_true",
        help="emit a candidate oracle to stdout for explicit code review",
    )
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    ffmpeg_version, ios_minimum, macos_minimum = release_values(
        arguments.release_config
    )

    if arguments.emit_manifest:
        runtime, registrations = collect(
            arguments.xcframework, ios_minimum, macos_minimum, None
        )
        candidate = reviewed_manifest_document(
            ffmpeg_version, runtime, registrations
        )
        json.dump(candidate, sys.stdout, indent=2, ensure_ascii=False)
        sys.stdout.write("\n")
        return 0

    reviewed = parse_reviewed_manifest(load_json(arguments.manifest))
    if reviewed.ffmpeg_version != ffmpeg_version:
        raise ManifestError(
            "Capability oracle was reviewed for FFmpeg "
            f"{reviewed.ffmpeg_version}, but release.json selects {ffmpeg_version}; "
            "generate and explicitly review an updated manifest"
        )
    runtime, _ = collect(
        arguments.xcframework,
        ios_minimum,
        macos_minimum,
        dict(reviewed.registrations),
    )
    compare_capability_groups(
        reviewed.runtime,
        runtime,
        RUNTIME_CATEGORIES,
        "runtimeCapabilities",
    )
    counts = ", ".join(
        f"{category}={len(runtime[category])}" for category in RUNTIME_CATEGORIES
    )
    print(f"Capability parity passed: {counts}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (CheckError, ManifestError, json.JSONDecodeError) as error:
        print(f"Capability parity failed: {error}", file=sys.stderr)
        raise SystemExit(1) from error
