"""Fail-closed generation and finalization of FFmpeg release candidates."""

from __future__ import annotations

import copy
import datetime as _datetime
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import tempfile
from typing import Any, Mapping
import zipfile


SCHEMA_VERSION = 1
PLACEHOLDER_SHA256 = "0" * 64
ARTIFACT_NAME = "FFmpeg.xcframework.zip"
RELEASE_BASE_URL = "https://github.com/vvisionnn/swift-ffmpeg/releases/download"
MAX_JSON_BYTES = 8 * 1024 * 1024
MAX_PACKAGE_BYTES = 1024 * 1024
MAX_ARCHIVE_ENTRIES = 50_000

SLICE_ARCHIVES = {
    "ios-arm64": "ios-arm64/libFFmpeg.a",
    "ios-arm64_x86_64-simulator": (
        "ios-arm64_x86_64-simulator/libFFmpeg.a"
    ),
    "macos-arm64_x86_64": "macos-arm64_x86_64/libFFmpeg.a",
}
RUNTIME_CAPABILITIES = (
    "decoders",
    "demuxers",
    "muxers",
    "inputProtocols",
    "hardwareDeviceTypes",
)
REGISTRATION_CAPABILITIES = (
    "decoders",
    "demuxers",
    "muxers",
    "protocols",
    "hardwareDeviceTypes",
)

_SHA256_PATTERN = re.compile(r"[0-9a-f]{64}\Z")
_FINGERPRINT_PATTERN = re.compile(r"[0-9A-F]{40}\Z")
_SEMVER_PATTERN = re.compile(
    r"(?P<major>0|[1-9][0-9]*)\."
    r"(?P<minor>0|[1-9][0-9]*)\."
    r"(?P<patch>0|[1-9][0-9]*)\Z"
)
_UPSTREAM_VERSION_PATTERN = re.compile(
    r"(?P<major>[1-9][0-9]*)\."
    r"(?P<minor>0|[1-9][0-9]*)"
    r"(?:\.(?P<patch>[1-9][0-9]*))?\Z"
)
_DEPLOYMENT_VERSION_PATTERN = re.compile(r"[0-9]+\.[0-9]+\Z")
_REMOTE_TARGET_PATTERN = re.compile(
    r"(?P<prefix>\.binaryTarget\(\s*"
    r"name\s*:\s*\"FFmpeg\"\s*,\s*"
    r"url\s*:\s*\")"
    r"(?P<url>[^\"\r\n]+)"
    r"(?P<middle>\"\s*,\s*checksum\s*:\s*\")"
    r"(?P<checksum>[0-9a-f]{64})"
    r"(?P<suffix>\"\s*\))",
    re.MULTILINE,
)
_EMBEDDED_FFMPEG_VERSION_PATTERN = re.compile(
    rb"FFmpeg version "
    rb"(?P<version>[1-9][0-9]*\.(?:0|[1-9][0-9]*)"
    rb"(?:\.[1-9][0-9]*)?)\x00"
)


class CandidateError(RuntimeError):
    """Raised when release automation cannot prove an input is safe."""


def _exact_keys(value: Mapping[str, Any], expected: set[str], path: str) -> None:
    actual = set(value)
    if actual != expected:
        missing = sorted(expected - actual)
        unexpected = sorted(actual - expected)
        details: list[str] = []
        if missing:
            details.append(f"missing {', '.join(missing)}")
        if unexpected:
            details.append(f"unexpected {', '.join(unexpected)}")
        raise CandidateError(f"{path} has invalid fields ({'; '.join(details)})")


def _mapping(value: Any, path: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise CandidateError(f"{path} must be a JSON object")
    return value


def _string(value: Any, path: str) -> str:
    if not isinstance(value, str) or not value:
        raise CandidateError(f"{path} must be a non-empty string")
    return value


def _sha256(value: Any, path: str, *, allow_placeholder: bool = True) -> str:
    value = _string(value, path)
    if _SHA256_PATTERN.fullmatch(value) is None:
        raise CandidateError(f"{path} must be lowercase 64-character SHA-256 hex")
    if not allow_placeholder and value == PLACEHOLDER_SHA256:
        raise CandidateError(f"{path} must not be the pending-build placeholder")
    return value


def _semver(value: Any, path: str) -> tuple[int, int, int]:
    value = _string(value, path)
    match = _SEMVER_PATTERN.fullmatch(value)
    if match is None:
        raise CandidateError(f"{path} must be canonical three-part SemVer")
    return tuple(int(match.group(part)) for part in ("major", "minor", "patch"))


def _upstream_version(value: Any, path: str) -> tuple[int, int, int]:
    value = _string(value, path)
    match = _UPSTREAM_VERSION_PATTERN.fullmatch(value)
    if match is None:
        raise CandidateError(f"{path} must be a canonical stable FFmpeg version")
    return (
        int(match.group("major")),
        int(match.group("minor")),
        int(match.group("patch") or 0),
    )


def _newer_point_version(current: str, candidate: str, path: str) -> None:
    current_tuple = _upstream_version(current, f"{path}.current")
    candidate_tuple = _upstream_version(candidate, f"{path}.candidate")
    if candidate_tuple <= current_tuple:
        raise CandidateError(
            f"{path} would roll back or repeat {current} with {candidate}"
        )
    if candidate_tuple[:2] != current_tuple[:2]:
        raise CandidateError(
            f"{path} is not an update on the {current_tuple[0]}.{current_tuple[1]} "
            "point-release branch"
        )


def _release_url(package_version: str) -> str:
    _semver(package_version, "packageVersion")
    return f"{RELEASE_BASE_URL}/{package_version}/{ARTIFACT_NAME}"


def _reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise CandidateError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def parse_json_bytes(data: bytes, description: str) -> Any:
    if len(data) > MAX_JSON_BYTES:
        raise CandidateError(f"{description} exceeds {MAX_JSON_BYTES} bytes")
    try:
        text = data.decode("utf-8", errors="strict")
        return json.loads(
            text,
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=lambda value: (_ for _ in ()).throw(
                CandidateError(f"invalid JSON constant in {description}: {value}")
            ),
        )
    except CandidateError:
        raise
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise CandidateError(f"invalid {description}: {error}") from error


def render_json(document: Any) -> bytes:
    return (json.dumps(document, indent=2, sort_keys=True) + "\n").encode("utf-8")


def _validate_ffmpeg(document: dict[str, Any]) -> str:
    _exact_keys(
        document,
        {
            "releaseKeyFingerprint",
            "releaseKeySHA256",
            "sha256",
            "signatureURL",
            "url",
            "version",
        },
        "release.ffmpeg",
    )
    version = _string(document["version"], "release.ffmpeg.version")
    _upstream_version(version, "release.ffmpeg.version")
    expected_url = f"https://ffmpeg.org/releases/ffmpeg-{version}.tar.xz"
    if document["url"] != expected_url:
        raise CandidateError("release.ffmpeg.url is not canonical for its version")
    if document["signatureURL"] != f"{expected_url}.asc":
        raise CandidateError(
            "release.ffmpeg.signatureURL is not canonical for its version"
        )
    _sha256(document["sha256"], "release.ffmpeg.sha256", allow_placeholder=False)
    _sha256(
        document["releaseKeySHA256"],
        "release.ffmpeg.releaseKeySHA256",
        allow_placeholder=False,
    )
    fingerprint = _string(
        document["releaseKeyFingerprint"],
        "release.ffmpeg.releaseKeyFingerprint",
    )
    if _FINGERPRINT_PATTERN.fullmatch(fingerprint) is None:
        raise CandidateError(
            "release.ffmpeg.releaseKeyFingerprint must be uppercase 40-character hex"
        )
    return version


def validate_release_config(
    document: Any, *, expected_artifacts: str = "any"
) -> tuple[str, str]:
    """Validate the complete version-one release schema and return its versions."""

    release = _mapping(document, "release configuration")
    _exact_keys(
        release,
        {
            "artifact",
            "build",
            "dav1d",
            "ffmpeg",
            "packageVersion",
            "schemaVersion",
            "toolchain",
        },
        "release configuration",
    )
    if release["schemaVersion"] != SCHEMA_VERSION or isinstance(
        release["schemaVersion"], bool
    ):
        raise CandidateError("unsupported release configuration schema")
    package_version = _string(release["packageVersion"], "release.packageVersion")
    _semver(package_version, "release.packageVersion")

    artifact = _mapping(release["artifact"], "release.artifact")
    _exact_keys(artifact, {"name", "swiftPackageChecksum", "xcframework"}, "release.artifact")
    if artifact["name"] != ARTIFACT_NAME:
        raise CandidateError(f"release.artifact.name must be {ARTIFACT_NAME}")
    artifact_hashes = [
        _sha256(artifact["swiftPackageChecksum"], "release.artifact.swiftPackageChecksum")
    ]
    xcframework = _mapping(artifact["xcframework"], "release.artifact.xcframework")
    _exact_keys(
        xcframework,
        {"infoPlistSHA256", "slices"},
        "release.artifact.xcframework",
    )
    artifact_hashes.append(
        _sha256(
            xcframework["infoPlistSHA256"],
            "release.artifact.xcframework.infoPlistSHA256",
        )
    )
    slices = _mapping(xcframework["slices"], "release.artifact.xcframework.slices")
    _exact_keys(slices, set(SLICE_ARCHIVES), "release.artifact.xcframework.slices")
    artifact_hashes.extend(
        _sha256(slices[name], f"release.artifact.xcframework.slices.{name}")
        for name in SLICE_ARCHIVES
    )
    if expected_artifacts not in {"any", "placeholder", "final"}:
        raise ValueError(f"unsupported artifact validation mode: {expected_artifacts}")
    if expected_artifacts == "placeholder" and any(
        digest != PLACEHOLDER_SHA256 for digest in artifact_hashes
    ):
        raise CandidateError("candidate artifact digests must all be pending placeholders")
    if expected_artifacts == "final" and any(
        digest == PLACEHOLDER_SHA256 for digest in artifact_hashes
    ):
        raise CandidateError("final artifact digests must not contain placeholders")

    build = _mapping(release["build"], "release.build")
    _exact_keys(
        build,
        {"iOSMinimumVersion", "macOSMinimumVersion", "sourceDateEpoch"},
        "release.build",
    )
    for key in ("iOSMinimumVersion", "macOSMinimumVersion"):
        value = _string(build[key], f"release.build.{key}")
        if _DEPLOYMENT_VERSION_PATTERN.fullmatch(value) is None:
            raise CandidateError(f"release.build.{key} is not a deployment version")
    epoch = build["sourceDateEpoch"]
    if not isinstance(epoch, int) or isinstance(epoch, bool) or epoch <= 0:
        raise CandidateError("release.build.sourceDateEpoch must be a positive integer")

    ffmpeg_version = _validate_ffmpeg(
        _mapping(release["ffmpeg"], "release.ffmpeg")
    )
    dav1d = _mapping(release["dav1d"], "release.dav1d")
    _exact_keys(dav1d, {"sha256", "url", "version"}, "release.dav1d")
    dav1d_version = _string(dav1d["version"], "release.dav1d.version")
    _upstream_version(dav1d_version, "release.dav1d.version")
    if dav1d["url"] != (
        "https://code.videolan.org/videolan/dav1d/-/archive/"
        f"{dav1d_version}/dav1d-{dav1d_version}.tar.bz2"
    ):
        raise CandidateError("release.dav1d.url is not canonical for its version")
    _sha256(dav1d["sha256"], "release.dav1d.sha256", allow_placeholder=False)

    toolchain = _mapping(release["toolchain"], "release.toolchain")
    _exact_keys(
        toolchain,
        {
            "cctoolsVersion",
            "clangVersion",
            "iPhoneOSSDKVersion",
            "iPhoneSimulatorSDKVersion",
            "macOSSDKVersion",
            "makeVersion",
            "mesonVersion",
            "ninjaVersion",
            "pkgConfigVersion",
            "xcodeBuild",
            "xcodeVersion",
        },
        "release.toolchain",
    )
    for key, value in toolchain.items():
        _string(value, f"release.toolchain.{key}")
    return package_version, ffmpeg_version


def validate_discovery(
    document: Any, configured_version: str
) -> dict[str, str | int]:
    discovery = _mapping(document, "discovery")
    _exact_keys(
        discovery,
        {"configuredVersion", "release", "schemaVersion", "updateAvailable"},
        "discovery",
    )
    if discovery["schemaVersion"] != SCHEMA_VERSION or isinstance(
        discovery["schemaVersion"], bool
    ):
        raise CandidateError("unsupported discovery schema")
    if discovery["configuredVersion"] != configured_version:
        raise CandidateError(
            "discovery.configuredVersion does not match release.ffmpeg.version"
        )
    if discovery["updateAvailable"] is not True:
        raise CandidateError("discovery does not identify a new release")
    release = _mapping(discovery["release"], "discovery.release")
    _exact_keys(
        release,
        {"releaseDate", "signatureURL", "sourceURL", "version"},
        "discovery.release",
    )
    version = _string(release["version"], "discovery.release.version")
    _newer_point_version(configured_version, version, "FFmpeg discovery")
    expected_url = f"https://ffmpeg.org/releases/ffmpeg-{version}.tar.xz"
    if release["sourceURL"] != expected_url:
        raise CandidateError("discovery.release.sourceURL is not canonical")
    if release["signatureURL"] != f"{expected_url}.asc":
        raise CandidateError("discovery.release.signatureURL is not canonical")
    date = _string(release["releaseDate"], "discovery.release.releaseDate")
    if re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", date) is None:
        raise CandidateError("discovery.release.releaseDate is not ISO YYYY-MM-DD")
    try:
        release_date = _datetime.date.fromisoformat(date)
    except ValueError as error:
        raise CandidateError("discovery.release.releaseDate is invalid") from error
    release_epoch = int(
        _datetime.datetime.combine(
            release_date,
            _datetime.time.min,
            tzinfo=_datetime.timezone.utc,
        ).timestamp()
    )
    return {
        "version": version,
        "sourceURL": expected_url,
        "signatureURL": f"{expected_url}.asc",
        "sourceDateEpoch": release_epoch,
    }


def _updated_package_manifest(
    text: str,
    *,
    expected_version: str,
    expected_checksum: str,
    new_version: str,
    new_checksum: str,
) -> str:
    matches = list(_REMOTE_TARGET_PATTERN.finditer(text))
    if len(matches) != 1:
        raise CandidateError(
            "Package.swift must contain exactly one remote FFmpeg binary target"
        )
    match = matches[0]
    expected_url = _release_url(expected_version)
    if match.group("url") != expected_url:
        raise CandidateError(
            "Package.swift FFmpeg URL does not match the release configuration"
        )
    if match.group("checksum") != expected_checksum:
        raise CandidateError(
            "Package.swift FFmpeg checksum does not match the release configuration"
        )
    _sha256(new_checksum, "new Package.swift checksum")
    return (
        text[: match.start("url")]
        + _release_url(new_version)
        + text[match.end("url") : match.start("checksum")]
        + new_checksum
        + text[match.end("checksum") :]
    )


def generate_candidate_documents(
    base_config: Any,
    base_package: str,
    discovery: Any,
    ffmpeg_source_sha256: str,
) -> tuple[dict[str, Any], str]:
    """Create candidate documents without mutating any input object or file."""

    package_version, ffmpeg_version = validate_release_config(
        base_config, expected_artifacts="final"
    )
    release = validate_discovery(discovery, ffmpeg_version)
    source_sha = _sha256(
        ffmpeg_source_sha256,
        "downloaded FFmpeg source SHA-256",
        allow_placeholder=False,
    )
    old_package_tuple = _semver(package_version, "release.packageVersion")
    new_package_version = (
        f"{old_package_tuple[0]}.{old_package_tuple[1]}.{old_package_tuple[2] + 1}"
    )

    candidate = copy.deepcopy(base_config)
    candidate["packageVersion"] = new_package_version
    candidate["ffmpeg"]["version"] = release["version"]
    candidate["ffmpeg"]["url"] = release["sourceURL"]
    candidate["ffmpeg"]["signatureURL"] = release["signatureURL"]
    candidate["ffmpeg"]["sha256"] = source_sha
    candidate["build"]["sourceDateEpoch"] = release["sourceDateEpoch"]
    candidate["artifact"]["swiftPackageChecksum"] = PLACEHOLDER_SHA256
    candidate["artifact"]["xcframework"]["infoPlistSHA256"] = PLACEHOLDER_SHA256
    for name in SLICE_ARCHIVES:
        candidate["artifact"]["xcframework"]["slices"][name] = PLACEHOLDER_SHA256

    candidate_package = _updated_package_manifest(
        base_package,
        expected_version=package_version,
        expected_checksum=base_config["artifact"]["swiftPackageChecksum"],
        new_version=new_package_version,
        new_checksum=PLACEHOLDER_SHA256,
    )
    validate_release_config(candidate, expected_artifacts="placeholder")
    return candidate, candidate_package


def _capability_names(value: Any, path: str) -> list[str]:
    if not isinstance(value, list) or not all(
        isinstance(item, str) and item for item in value
    ):
        raise CandidateError(f"{path} must be an array of non-empty strings")
    if value != sorted(value):
        raise CandidateError(f"{path} must be sorted")
    if len(value) != len(set(value)):
        raise CandidateError(f"{path} must not contain duplicates")
    return value


def validate_capability_manifest(document: Any) -> str:
    manifest = _mapping(document, "capability manifest")
    _exact_keys(
        manifest,
        {
            "generatedFrom",
            "registrationSymbols",
            "runtimeCapabilities",
            "schemaVersion",
        },
        "capability manifest",
    )
    if manifest["schemaVersion"] != SCHEMA_VERSION or isinstance(
        manifest["schemaVersion"], bool
    ):
        raise CandidateError("unsupported capability manifest schema")
    generated = _mapping(manifest["generatedFrom"], "capability manifest.generatedFrom")
    _exact_keys(generated, {"ffmpegVersion"}, "capability manifest.generatedFrom")
    version = _string(
        generated["ffmpegVersion"],
        "capability manifest.generatedFrom.ffmpegVersion",
    )
    _upstream_version(version, "capability manifest.generatedFrom.ffmpegVersion")

    for group_name, categories in (
        ("runtimeCapabilities", RUNTIME_CAPABILITIES),
        ("registrationSymbols", REGISTRATION_CAPABILITIES),
    ):
        group = _mapping(manifest[group_name], f"capability manifest.{group_name}")
        _exact_keys(group, set(categories), f"capability manifest.{group_name}")
        for category in categories:
            path = f"capability manifest.{group_name}.{category}"
            entry = _mapping(group[category], path)
            _exact_keys(entry, {"count", "names"}, path)
            names = _capability_names(entry["names"], f"{path}.names")
            count = entry["count"]
            if not isinstance(count, int) or isinstance(count, bool) or count < 0:
                raise CandidateError(f"{path}.count must be a non-negative integer")
            if count != len(names):
                raise CandidateError(
                    f"{path}.count does not match its names array"
                )
    return version


def advance_capability_oracle(
    reviewed: Any, built: Any, target_ffmpeg_version: str
) -> dict[str, Any]:
    reviewed_version = validate_capability_manifest(reviewed)
    built_version = validate_capability_manifest(built)
    if built_version != target_ffmpeg_version:
        raise CandidateError(
            "built capability FFmpeg version does not match the candidate release"
        )
    _newer_point_version(
        reviewed_version,
        target_ffmpeg_version,
        "capability oracle",
    )
    for group_name in ("runtimeCapabilities", "registrationSymbols"):
        if reviewed[group_name] != built[group_name]:
            raise CandidateError(
                f"{group_name} changed; explicit capability review is required"
            )
    advanced = copy.deepcopy(reviewed)
    advanced["generatedFrom"]["ffmpegVersion"] = target_ffmpeg_version
    return advanced


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as stream:
            while chunk := stream.read(1024 * 1024):
                digest.update(chunk)
    except OSError as error:
        raise CandidateError(f"cannot hash {path}: {error}") from error
    return digest.hexdigest()


def _embedded_ffmpeg_versions(path: Path) -> set[str]:
    versions: set[str] = set()
    overlap = b""
    try:
        with path.open("rb") as stream:
            while chunk := stream.read(1024 * 1024):
                data = overlap + chunk
                versions.update(
                    match.group("version").decode("ascii")
                    for match in _EMBEDDED_FFMPEG_VERSION_PATTERN.finditer(data)
                )
                overlap = data[-128:]
    except OSError as error:
        raise CandidateError(
            f"cannot inspect embedded FFmpeg version in {path}: {error}"
        ) from error
    return versions


def _regular_tree_files(root: Path) -> dict[str, tuple[int, str]]:
    if not root.is_dir() or root.is_symlink():
        raise CandidateError(f"XCFramework must be a non-symlink directory: {root}")
    result: dict[str, tuple[int, str]] = {}
    for directory, directory_names, file_names in os.walk(root, followlinks=False):
        directory_path = Path(directory)
        for name in directory_names:
            path = directory_path / name
            if path.is_symlink():
                raise CandidateError(f"XCFramework contains a symlink: {path}")
        for name in file_names:
            path = directory_path / name
            try:
                metadata = path.lstat()
            except OSError as error:
                raise CandidateError(f"cannot inspect XCFramework file {path}: {error}") from error
            if not stat.S_ISREG(metadata.st_mode):
                raise CandidateError(f"XCFramework contains a non-regular file: {path}")
            relative = path.relative_to(root).as_posix()
            result[relative] = (metadata.st_size, sha256_file(path))
    if not result:
        raise CandidateError("XCFramework contains no files")
    return result


def _safe_zip_name(name: str) -> tuple[str, bool]:
    if not name or "\x00" in name or "\\" in name or name.startswith("/"):
        raise CandidateError(f"release ZIP contains an unsafe path: {name!r}")
    directory = name.endswith("/")
    components = name.rstrip("/").split("/")
    if any(component in {"", ".", ".."} for component in components):
        raise CandidateError(f"release ZIP contains an unsafe path: {name!r}")
    if components[0] != "FFmpeg.xcframework":
        raise CandidateError(f"release ZIP contains an unexpected root: {name!r}")
    return "/".join(components), directory


def verify_release_zip_matches_xcframework(
    release_zip: Path, xcframework: Path
) -> str:
    expected = _regular_tree_files(xcframework)
    observed: dict[str, tuple[int, str]] = {}
    seen_names: set[str] = set()
    try:
        with zipfile.ZipFile(release_zip, "r") as archive:
            infos = archive.infolist()
            if len(infos) > MAX_ARCHIVE_ENTRIES:
                raise CandidateError("release ZIP contains too many entries")
            for info in infos:
                normalized, directory = _safe_zip_name(info.filename)
                if normalized in seen_names:
                    raise CandidateError(
                        f"release ZIP contains a duplicate path: {info.filename}"
                    )
                seen_names.add(normalized)
                unix_mode = (info.external_attr >> 16) & 0xFFFF
                if stat.S_IFMT(unix_mode) == stat.S_IFLNK:
                    raise CandidateError(
                        f"release ZIP contains a symlink: {info.filename}"
                    )
                if info.flag_bits & 0x1:
                    raise CandidateError(
                        f"release ZIP contains an encrypted entry: {info.filename}"
                    )
                if directory:
                    continue
                relative = normalized.removeprefix("FFmpeg.xcframework/")
                if not relative or normalized == "FFmpeg.xcframework":
                    raise CandidateError(
                        f"release ZIP root is not a directory: {info.filename}"
                    )
                if relative not in expected:
                    raise CandidateError(
                        "release ZIP does not exactly match the assembled XCFramework "
                        f"(unexpected {relative})"
                    )
                if info.file_size != expected[relative][0]:
                    raise CandidateError(
                        "release ZIP does not exactly match the assembled XCFramework "
                        f"(changed {relative})"
                    )
                digest = hashlib.sha256()
                with archive.open(info, "r") as stream:
                    while chunk := stream.read(1024 * 1024):
                        digest.update(chunk)
                observed[relative] = (info.file_size, digest.hexdigest())
    except CandidateError:
        raise
    except (OSError, zipfile.BadZipFile, RuntimeError) as error:
        raise CandidateError(f"cannot verify release ZIP {release_zip}: {error}") from error
    if observed != expected:
        missing = sorted(set(expected) - set(observed))
        unexpected = sorted(set(observed) - set(expected))
        changed = sorted(
            name
            for name in set(expected) & set(observed)
            if expected[name] != observed[name]
        )
        details: list[str] = []
        if missing:
            details.append(f"missing {', '.join(missing)}")
        if unexpected:
            details.append(f"unexpected {', '.join(unexpected)}")
        if changed:
            details.append(f"changed {', '.join(changed)}")
        raise CandidateError(
            "release ZIP does not exactly match the assembled XCFramework"
            + (f" ({'; '.join(details)})" if details else "")
        )
    return sha256_file(release_zip)


def finalize_candidate_documents(
    candidate_config: Any,
    candidate_package: str,
    xcframework: Path,
    release_zip: Path,
    reviewed_capabilities: Any,
    built_capabilities: Any,
) -> tuple[dict[str, Any], str, dict[str, Any], dict[str, str]]:
    package_version, ffmpeg_version = validate_release_config(
        candidate_config, expected_artifacts="placeholder"
    )
    advanced_capabilities = advance_capability_oracle(
        reviewed_capabilities,
        built_capabilities,
        ffmpeg_version,
    )
    zip_checksum = verify_release_zip_matches_xcframework(release_zip, xcframework)
    if zip_checksum == PLACEHOLDER_SHA256:
        raise CandidateError("release ZIP checksum equals the pending placeholder")

    digest_paths = {
        "infoPlistSHA256": xcframework / "Info.plist",
        **{
            slice_name: xcframework / relative_path
            for slice_name, relative_path in SLICE_ARCHIVES.items()
        },
    }
    for label, path in digest_paths.items():
        if not path.is_file() or path.is_symlink():
            raise CandidateError(f"missing regular XCFramework input for {label}: {path}")
    for slice_name in SLICE_ARCHIVES:
        path = digest_paths[slice_name]
        embedded_versions = _embedded_ffmpeg_versions(path)
        if embedded_versions != {ffmpeg_version}:
            rendered = ", ".join(sorted(embedded_versions)) or "none"
            raise CandidateError(
                f"{slice_name} embedded FFmpeg version mismatch; "
                f"expected {ffmpeg_version}, found {rendered}"
            )
    digests = {label: sha256_file(path) for label, path in digest_paths.items()}
    if any(value == PLACEHOLDER_SHA256 for value in digests.values()):
        raise CandidateError("an XCFramework digest equals the pending placeholder")

    final_config = copy.deepcopy(candidate_config)
    final_config["artifact"]["swiftPackageChecksum"] = zip_checksum
    final_config["artifact"]["xcframework"]["infoPlistSHA256"] = digests[
        "infoPlistSHA256"
    ]
    for name in SLICE_ARCHIVES:
        final_config["artifact"]["xcframework"]["slices"][name] = digests[name]
    final_package = _updated_package_manifest(
        candidate_package,
        expected_version=package_version,
        expected_checksum=PLACEHOLDER_SHA256,
        new_version=package_version,
        new_checksum=zip_checksum,
    )
    validate_release_config(final_config, expected_artifacts="final")
    validate_capability_manifest(advanced_capabilities)
    return (
        final_config,
        final_package,
        advanced_capabilities,
        {
            "swiftPackageChecksum": zip_checksum,
            **digests,
        },
    )


def checked_input_path(path: Path, description: str, *, directory: bool = False) -> Path:
    if not path.is_absolute() or ".." in path.parts:
        raise CandidateError(f"{description} path must be absolute and normalized")
    try:
        metadata = path.lstat()
    except OSError as error:
        raise CandidateError(f"cannot inspect {description} path {path}: {error}") from error
    expected = stat.S_ISDIR(metadata.st_mode) if directory else stat.S_ISREG(metadata.st_mode)
    if not expected or stat.S_ISLNK(metadata.st_mode):
        kind = "directory" if directory else "file"
        raise CandidateError(f"{description} must be a regular non-symlink {kind}: {path}")
    return path


def read_json_path(path: Path, description: str) -> Any:
    checked_input_path(path, description)
    try:
        with path.open("rb") as stream:
            data = stream.read(MAX_JSON_BYTES + 1)
    except OSError as error:
        raise CandidateError(f"cannot read {description} {path}: {error}") from error
    return parse_json_bytes(data, description)


def read_package_path(path: Path) -> str:
    checked_input_path(path, "Package.swift input")
    try:
        with path.open("rb") as stream:
            data = stream.read(MAX_PACKAGE_BYTES + 1)
    except OSError as error:
        raise CandidateError(f"cannot read Package.swift input {path}: {error}") from error
    if len(data) > MAX_PACKAGE_BYTES:
        raise CandidateError(f"Package.swift exceeds {MAX_PACKAGE_BYTES} bytes")
    try:
        return data.decode("utf-8", errors="strict")
    except UnicodeDecodeError as error:
        raise CandidateError("Package.swift is not valid UTF-8") from error


def _canonical_path(path: Path) -> str:
    return os.path.realpath(os.fspath(path))


def preflight_paths(inputs: list[Path], outputs: list[Path]) -> None:
    if not outputs:
        raise CandidateError("at least one output path is required")
    output_identities: set[str] = set()
    input_identities = {_canonical_path(path) for path in inputs}
    for output in outputs:
        if not output.is_absolute() or ".." in output.parts:
            raise CandidateError("output paths must be absolute and normalized")
        parent = output.parent
        if not parent.is_dir() or parent.is_symlink():
            raise CandidateError(f"output parent must be a non-symlink directory: {parent}")
        try:
            metadata = output.lstat()
        except FileNotFoundError:
            metadata = None
        except OSError as error:
            raise CandidateError(f"cannot inspect output path {output}: {error}") from error
        if metadata is not None and (
            stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode)
        ):
            raise CandidateError(f"output path is not a regular file: {output}")
        identity = _canonical_path(output)
        if identity in input_identities:
            raise CandidateError(f"output path aliases an input: {output}")
        if identity in output_identities:
            raise CandidateError(f"output paths must be distinct: {output}")
        output_identities.add(identity)


def atomic_write_documents(documents: Mapping[Path, bytes]) -> None:
    """Write each validated output with a same-directory atomic replacement."""

    temporary_paths: dict[Path, Path] = {}
    try:
        for output, data in documents.items():
            descriptor, temporary_name = tempfile.mkstemp(
                prefix=f".{output.name}.", suffix=".tmp", dir=output.parent
            )
            temporary = Path(temporary_name)
            temporary_paths[output] = temporary
            try:
                os.fchmod(descriptor, 0o644)
                with os.fdopen(descriptor, "wb", closefd=True) as stream:
                    stream.write(data)
                    stream.flush()
                    os.fsync(stream.fileno())
            except Exception:
                try:
                    os.close(descriptor)
                except OSError:
                    pass
                raise
        for output, temporary in temporary_paths.items():
            os.replace(temporary, output)
        for parent in {output.parent for output in documents}:
            try:
                descriptor = os.open(parent, os.O_RDONLY)
                try:
                    os.fsync(descriptor)
                finally:
                    os.close(descriptor)
            except OSError:
                # File replacement is already complete; directory fsync is not
                # uniformly available on every supported filesystem.
                pass
    except OSError as error:
        raise CandidateError(f"cannot atomically write release outputs: {error}") from error
    finally:
        for temporary in temporary_paths.values():
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass
