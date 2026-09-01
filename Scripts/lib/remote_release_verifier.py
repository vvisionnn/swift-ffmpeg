#!/usr/bin/env python3
"""Strict helpers for clean-room swift-ffmpeg release verification."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import sys
from urllib.parse import unquote, urlparse
import zipfile


REPOSITORY_URL = "https://github.com/vvisionnn/swift-ffmpeg.git"
ARTIFACT_NAME = "FFmpeg.xcframework.zip"
SEMVER_PATTERN = re.compile(
    r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"
)
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
FFMPEG_VERSION_PATTERN = re.compile(
    r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:\.(0|[1-9][0-9]*))?$"
)
REMOTE_BINARY_TARGET_PATTERN = re.compile(
    r"\.binaryTarget\s*\(\s*"
    r'name\s*:\s*"FFmpeg"\s*,\s*'
    r'url\s*:\s*"([^"]+)"\s*,\s*'
    r'checksum\s*:\s*"([^"]+)"\s*'
    r"\)",
    re.DOTALL,
)


class VerificationError(ValueError):
    """A release input violates a verifier invariant."""


def validate_tag(tag: str) -> str:
    if not SEMVER_PATTERN.fullmatch(tag):
        raise VerificationError(
            "Tag must be a canonical stable SemVer value such as 1.2.3"
        )
    return tag


def validate_checksum(checksum: str) -> str:
    if not SHA256_PATTERN.fullmatch(checksum):
        raise VerificationError("Checksum must be 64 lowercase hexadecimal characters")
    return checksum


def validate_ffmpeg_version(version: str) -> str:
    if not FFMPEG_VERSION_PATTERN.fullmatch(version):
        raise VerificationError("FFmpeg version must be a canonical numeric version")
    return version


def expected_artifact_url(tag: str) -> str:
    validate_tag(tag)
    return (
        "https://github.com/vvisionnn/swift-ffmpeg/releases/download/"
        f"{tag}/{ARTIFACT_NAME}"
    )


def inspect_manifest(
    manifest_path: Path,
    tag: str,
    expected_checksum: str | None = None,
) -> dict[str, str]:
    validate_tag(tag)
    if expected_checksum is not None:
        validate_checksum(expected_checksum)
    try:
        manifest_bytes = manifest_path.read_bytes()
    except OSError as error:
        raise VerificationError(f"Cannot read tagged Package.swift: {error}") from error
    if len(manifest_bytes) > 1024 * 1024:
        raise VerificationError("Tagged Package.swift exceeds the 1 MiB safety limit")
    if b"\0" in manifest_bytes:
        raise VerificationError("Tagged Package.swift contains a NUL byte")
    try:
        manifest = manifest_bytes.decode("utf-8")
    except UnicodeDecodeError as error:
        raise VerificationError("Tagged Package.swift is not valid UTF-8") from error

    matches = REMOTE_BINARY_TARGET_PATTERN.findall(manifest)
    if len(matches) != 1:
        raise VerificationError(
            "Tagged Package.swift must declare exactly one remote FFmpeg binary target"
        )
    url, checksum = matches[0]
    wanted_url = expected_artifact_url(tag)
    if url != wanted_url:
        raise VerificationError(
            f"Tagged binary URL mismatch: expected {wanted_url}, found {url}"
        )
    validate_checksum(checksum)
    if expected_checksum is not None and checksum != expected_checksum:
        raise VerificationError(
            f"Tagged checksum mismatch: expected {expected_checksum}, found {checksum}"
        )

    remote_binary_declarations = re.findall(
        r"\.binaryTarget\s*\([^)]*\burl\s*:", manifest, re.DOTALL
    )
    if len(remote_binary_declarations) != 1:
        raise VerificationError("Unexpected additional remote binary target")

    return {"url": url, "checksum": checksum}


def _validated_members(archive: zipfile.ZipFile) -> list[zipfile.ZipInfo]:
    members = archive.infolist()
    if not members:
        raise VerificationError("XCFramework ZIP is empty")
    if len(members) > 10_000:
        raise VerificationError("XCFramework ZIP contains too many entries")

    seen: set[str] = set()
    total_size = 0
    for member in members:
        name = member.filename
        if "\0" in name or "\\" in name:
            raise VerificationError(f"Unsafe ZIP entry name: {name!r}")
        path = PurePosixPath(name)
        if path.is_absolute() or not path.parts:
            raise VerificationError(f"Unsafe ZIP entry path: {name!r}")
        if any(part in ("", ".", "..") for part in path.parts):
            raise VerificationError(f"Unsafe ZIP entry component: {name!r}")
        if path.parts[0] != "FFmpeg.xcframework":
            raise VerificationError(f"ZIP entry is outside FFmpeg.xcframework: {name!r}")
        normalized = path.as_posix().rstrip("/")
        if normalized in seen:
            raise VerificationError(f"Duplicate ZIP entry: {normalized!r}")
        seen.add(normalized)

        unix_mode = member.external_attr >> 16
        file_type = stat.S_IFMT(unix_mode)
        if file_type not in (0, stat.S_IFREG, stat.S_IFDIR):
            raise VerificationError(f"ZIP entry is not a regular file or directory: {name!r}")
        if member.is_dir() and file_type == stat.S_IFREG:
            raise VerificationError(f"ZIP directory has a regular-file mode: {name!r}")
        if not member.is_dir() and file_type == stat.S_IFDIR:
            raise VerificationError(f"ZIP file has a directory mode: {name!r}")

        total_size += member.file_size
        if member.file_size > 512 * 1024 * 1024:
            raise VerificationError(f"ZIP entry exceeds the 512 MiB limit: {name!r}")
        if total_size > 1024 * 1024 * 1024:
            raise VerificationError("XCFramework ZIP exceeds the 1 GiB expanded-size limit")
    return members


def safe_extract(archive_path: Path, destination: Path) -> None:
    try:
        destination.mkdir(parents=True, exist_ok=False)
    except OSError as error:
        raise VerificationError(f"Cannot create extraction directory: {error}") from error
    destination = destination.resolve(strict=True)

    try:
        with zipfile.ZipFile(archive_path, "r") as archive:
            members = _validated_members(archive)
            for member in members:
                relative = PurePosixPath(member.filename)
                output = destination.joinpath(*relative.parts)
                try:
                    output.relative_to(destination)
                except ValueError as error:
                    raise VerificationError(
                        f"ZIP entry escaped extraction root: {member.filename!r}"
                    ) from error

                if member.is_dir():
                    output.mkdir(mode=0o755, parents=True, exist_ok=True)
                    continue

                output.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
                unix_mode = member.external_attr >> 16
                permissions = stat.S_IMODE(unix_mode) or 0o644
                flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
                if hasattr(os, "O_NOFOLLOW"):
                    flags |= os.O_NOFOLLOW
                descriptor = os.open(output, flags, permissions)
                try:
                    with os.fdopen(descriptor, "wb") as target, archive.open(member) as source:
                        shutil.copyfileobj(source, target, length=1024 * 1024)
                except Exception:
                    try:
                        os.close(descriptor)
                    except OSError:
                        pass
                    raise
    except (OSError, zipfile.BadZipFile) as error:
        raise VerificationError(f"Cannot safely extract XCFramework ZIP: {error}") from error


def verify_resolved(
    resolved_path: Path,
    tag: str,
    repository: str,
    revision: str,
) -> None:
    validate_tag(tag)
    if repository != REPOSITORY_URL and not repository.startswith("file:///tmp/"):
        raise VerificationError("Resolved repository is outside the allowed verification scope")
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise VerificationError("Expected Git revision must be a lowercase 40-character SHA-1")
    try:
        document = json.loads(resolved_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise VerificationError(f"Cannot read Package.resolved: {error}") from error
    pins = document.get("pins")
    if not isinstance(pins, list):
        raise VerificationError("Package.resolved has no pins array")
    matches = [pin for pin in pins if pin.get("identity") == "swift-ffmpeg"]
    if len(matches) != 1:
        raise VerificationError("Package.resolved must contain exactly one swift-ffmpeg pin")
    pin = matches[0]
    state = pin.get("state")
    if not isinstance(state, dict):
        raise VerificationError("swift-ffmpeg pin has no state")
    expected_locations = {repository}
    if repository.startswith("file:///tmp/"):
        fixture_path = Path(unquote(urlparse(repository).path))
        expected_locations.add(str(fixture_path))
        expected_locations.add(str(fixture_path.resolve(strict=True)))
    if pin.get("location") not in expected_locations:
        raise VerificationError(
            "swift-ffmpeg resolved from an unexpected repository: "
            f"{pin.get('location')!r}"
        )
    if state.get("version") != tag:
        raise VerificationError("swift-ffmpeg did not resolve the requested exact version")
    if state.get("revision") != revision:
        raise VerificationError("swift-ffmpeg tag moved between inspection and resolution")


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    inspect_parser = subparsers.add_parser("inspect-manifest")
    inspect_parser.add_argument("--manifest", type=Path, required=True)
    inspect_parser.add_argument("--tag", required=True)
    inspect_parser.add_argument("--expected-checksum")

    extract_parser = subparsers.add_parser("safe-extract")
    extract_parser.add_argument("--archive", type=Path, required=True)
    extract_parser.add_argument("--destination", type=Path, required=True)

    resolved_parser = subparsers.add_parser("verify-resolved")
    resolved_parser.add_argument("--resolved", type=Path, required=True)
    resolved_parser.add_argument("--tag", required=True)
    resolved_parser.add_argument("--repository", required=True)
    resolved_parser.add_argument("--revision", required=True)

    tag_parser = subparsers.add_parser("validate-tag")
    tag_parser.add_argument("tag")

    version_parser = subparsers.add_parser("validate-ffmpeg-version")
    version_parser.add_argument("version")
    return parser


def main(argv: list[str] | None = None) -> int:
    arguments = _parser().parse_args(argv)
    try:
        if arguments.command == "inspect-manifest":
            result = inspect_manifest(
                arguments.manifest, arguments.tag, arguments.expected_checksum
            )
            print(json.dumps(result, sort_keys=True, separators=(",", ":")))
        elif arguments.command == "safe-extract":
            safe_extract(arguments.archive, arguments.destination)
        elif arguments.command == "verify-resolved":
            verify_resolved(
                arguments.resolved,
                arguments.tag,
                arguments.repository,
                arguments.revision,
            )
        elif arguments.command == "validate-tag":
            print(validate_tag(arguments.tag))
        elif arguments.command == "validate-ffmpeg-version":
            print(validate_ffmpeg_version(arguments.version))
        else:  # pragma: no cover - argparse owns command validation.
            raise AssertionError(f"Unhandled command: {arguments.command}")
    except VerificationError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
