"""Validation and comparison primitives for the reviewed FFmpeg capability oracle."""

from __future__ import annotations

from dataclasses import dataclass
import re
from typing import Any, Mapping, Sequence


SCHEMA_VERSION = 1
RUNTIME_CATEGORIES = (
    "decoders",
    "demuxers",
    "muxers",
    "inputProtocols",
    "hardwareDeviceTypes",
)
REGISTRATION_CATEGORIES = (
    "decoders",
    "demuxers",
    "muxers",
    "protocols",
    "hardwareDeviceTypes",
)

_REGISTRATION_PATTERNS = {
    "decoders": re.compile(r"^_ff_.+_decoder$"),
    "demuxers": re.compile(r"^_ff_.+_demuxer$"),
    "muxers": re.compile(r"^_ff_.+_muxer$"),
    "protocols": re.compile(r"^_ff_.+_protocol$"),
    "hardwareDeviceTypes": re.compile(r"^_ff_hwcontext_type_.+$"),
}


class ManifestError(ValueError):
    """Raised when a capability document is malformed or differs from the oracle."""


@dataclass(frozen=True)
class CapabilityManifest:
    ffmpeg_version: str
    runtime: Mapping[str, tuple[str, ...]]
    registrations: Mapping[str, tuple[str, ...]]


def _require_mapping(value: Any, path: str) -> Mapping[str, Any]:
    if not isinstance(value, dict):
        raise ManifestError(f"{path} must be a JSON object")
    return value


def _require_exact_keys(
    value: Mapping[str, Any], expected: Sequence[str], path: str
) -> None:
    expected_set = set(expected)
    actual_set = set(value)
    missing = sorted(expected_set - actual_set)
    unexpected = sorted(actual_set - expected_set)
    if missing or unexpected:
        details: list[str] = []
        if missing:
            details.append(f"missing keys: {', '.join(missing)}")
        if unexpected:
            details.append(f"unexpected keys: {', '.join(unexpected)}")
        raise ManifestError(f"{path} has invalid fields ({'; '.join(details)})")


def _require_sorted_unique_strings(value: Any, path: str) -> tuple[str, ...]:
    if not isinstance(value, list) or not all(
        isinstance(item, str) and item for item in value
    ):
        raise ManifestError(f"{path} must be an array of non-empty strings")
    if value != sorted(value):
        raise ManifestError(f"{path} must be sorted with bytewise JSON string order")
    if len(value) != len(set(value)):
        raise ManifestError(f"{path} must not contain duplicate values")
    return tuple(value)


def parse_runtime_report(document: Any) -> Mapping[str, tuple[str, ...]]:
    report = _require_mapping(document, "runtime report")
    _require_exact_keys(
        report, ("schemaVersion", *RUNTIME_CATEGORIES), "runtime report"
    )
    if report["schemaVersion"] != SCHEMA_VERSION:
        raise ManifestError(
            f"unsupported runtime report schema: {report['schemaVersion']!r}"
        )
    return {
        category: _require_sorted_unique_strings(
            report[category], f"runtime report.{category}"
        )
        for category in RUNTIME_CATEGORIES
    }


def _parse_reviewed_group(
    document: Any, categories: Sequence[str], path: str
) -> Mapping[str, tuple[str, ...]]:
    group = _require_mapping(document, path)
    _require_exact_keys(group, categories, path)
    parsed: dict[str, tuple[str, ...]] = {}
    for category in categories:
        entry_path = f"{path}.{category}"
        entry = _require_mapping(group[category], entry_path)
        _require_exact_keys(entry, ("count", "names"), entry_path)
        names = _require_sorted_unique_strings(entry["names"], f"{entry_path}.names")
        count = entry["count"]
        if not isinstance(count, int) or isinstance(count, bool) or count < 0:
            raise ManifestError(f"{entry_path}.count must be a non-negative integer")
        if count != len(names):
            raise ManifestError(
                f"{entry_path}.count is {count}, but names contains {len(names)} values"
            )
        parsed[category] = names
    return parsed


def parse_reviewed_manifest(document: Any) -> CapabilityManifest:
    manifest = _require_mapping(document, "capability manifest")
    _require_exact_keys(
        manifest,
        (
            "schemaVersion",
            "generatedFrom",
            "runtimeCapabilities",
            "registrationSymbols",
        ),
        "capability manifest",
    )
    if manifest["schemaVersion"] != SCHEMA_VERSION:
        raise ManifestError(
            f"unsupported capability manifest schema: {manifest['schemaVersion']!r}"
        )

    generated_from = _require_mapping(
        manifest["generatedFrom"], "capability manifest.generatedFrom"
    )
    _require_exact_keys(
        generated_from, ("ffmpegVersion",), "capability manifest.generatedFrom"
    )
    ffmpeg_version = generated_from["ffmpegVersion"]
    if not isinstance(ffmpeg_version, str) or not re.fullmatch(
        r"[1-9][0-9]*\.[0-9]+(?:\.[0-9]+)?", ffmpeg_version
    ):
        raise ManifestError("generatedFrom.ffmpegVersion is not a stable FFmpeg version")

    return CapabilityManifest(
        ffmpeg_version=ffmpeg_version,
        runtime=_parse_reviewed_group(
            manifest["runtimeCapabilities"],
            RUNTIME_CATEGORIES,
            "capability manifest.runtimeCapabilities",
        ),
        registrations=_parse_reviewed_group(
            manifest["registrationSymbols"],
            REGISTRATION_CATEGORIES,
            "capability manifest.registrationSymbols",
        ),
    )


def extract_registration_symbols(nm_output: str) -> Mapping[str, tuple[str, ...]]:
    symbols: dict[str, set[str]] = {
        category: set() for category in REGISTRATION_CATEGORIES
    }
    for line in nm_output.splitlines():
        fields = line.split()
        if not fields:
            continue
        candidate = fields[-1]
        for category, pattern in _REGISTRATION_PATTERNS.items():
            if pattern.fullmatch(candidate):
                symbols[category].add(candidate)
    return {
        category: tuple(sorted(symbols[category]))
        for category in REGISTRATION_CATEGORIES
    }


def reviewed_manifest_document(
    ffmpeg_version: str,
    runtime: Mapping[str, Sequence[str]],
    registrations: Mapping[str, Sequence[str]],
) -> dict[str, Any]:
    """Build a canonical document for review; this function never writes the oracle."""

    runtime_report = {
        "schemaVersion": SCHEMA_VERSION,
        **{category: list(runtime[category]) for category in RUNTIME_CATEGORIES},
    }
    parsed_runtime = parse_runtime_report(runtime_report)
    _require_exact_keys(
        registrations, REGISTRATION_CATEGORIES, "registration symbols"
    )
    parsed_registrations = {
        category: _require_sorted_unique_strings(
            list(registrations[category]), f"registration symbols.{category}"
        )
        for category in REGISTRATION_CATEGORIES
    }
    document = {
        "schemaVersion": SCHEMA_VERSION,
        "generatedFrom": {"ffmpegVersion": ffmpeg_version},
        "runtimeCapabilities": {
            category: {
                "count": len(parsed_runtime[category]),
                "names": list(parsed_runtime[category]),
            }
            for category in RUNTIME_CATEGORIES
        },
        "registrationSymbols": {
            category: {
                "count": len(parsed_registrations[category]),
                "names": list(parsed_registrations[category]),
            }
            for category in REGISTRATION_CATEGORIES
        },
    }
    parse_reviewed_manifest(document)
    return document


def compare_capability_groups(
    expected: Mapping[str, Sequence[str]],
    actual: Mapping[str, Sequence[str]],
    categories: Sequence[str],
    label: str,
) -> None:
    _require_exact_keys(expected, categories, f"expected {label}")
    _require_exact_keys(actual, categories, f"actual {label}")
    differences: list[str] = []
    for category in categories:
        expected_names = set(expected[category])
        actual_names = set(actual[category])
        missing = sorted(expected_names - actual_names)
        unexpected = sorted(actual_names - expected_names)
        if missing:
            differences.append(
                f"{label}.{category} lost {len(missing)}: {', '.join(missing)}"
            )
        if unexpected:
            differences.append(
                f"{label}.{category} added {len(unexpected)}: "
                f"{', '.join(unexpected)}"
            )
    if differences:
        raise ManifestError(
            "Capability oracle mismatch; inspect the FFmpeg change and explicitly "
            "review an updated Configuration/capabilities.json:\n- "
            + "\n- ".join(differences)
        )
