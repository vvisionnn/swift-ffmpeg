from __future__ import annotations

import copy
import sys
from pathlib import Path
import unittest


PROJECT_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PROJECT_ROOT / "Scripts" / "lib"))

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


class CapabilityManifestTests(unittest.TestCase):
    def setUp(self) -> None:
        self.runtime = {
            "decoders": ["aac", "h264"],
            "demuxers": ["mov", "wav"],
            "muxers": ["spdif"],
            "inputProtocols": ["file", "https"],
            "hardwareDeviceTypes": ["videotoolbox"],
        }
        self.registrations = {
            "decoders": ["_ff_aac_decoder", "_ff_h264_decoder"],
            "demuxers": ["_ff_mov_demuxer", "_ff_wav_demuxer"],
            "muxers": ["_ff_spdif_muxer"],
            "protocols": ["_ff_file_protocol", "_ff_https_protocol"],
            "hardwareDeviceTypes": ["_ff_hwcontext_type_videotoolbox"],
        }

    def test_reviewed_manifest_round_trip(self) -> None:
        document = reviewed_manifest_document(
            "9.0", self.runtime, self.registrations
        )
        parsed = parse_reviewed_manifest(document)

        self.assertEqual(parsed.ffmpeg_version, "9.0")
        self.assertEqual(parsed.runtime["decoders"], ("aac", "h264"))
        self.assertEqual(
            parsed.registrations["muxers"], ("_ff_spdif_muxer",)
        )

    def test_loss_is_reported(self) -> None:
        actual = copy.deepcopy(self.runtime)
        actual["decoders"] = ["aac"]

        with self.assertRaisesRegex(ManifestError, r"decoders lost 1: h264"):
            compare_capability_groups(
                self.runtime, actual, RUNTIME_CATEGORIES, "runtime"
            )

    def test_addition_requires_review(self) -> None:
        actual = copy.deepcopy(self.runtime)
        actual["inputProtocols"] = ["file", "http", "https"]

        with self.assertRaisesRegex(
            ManifestError, r"inputProtocols added 1: http"
        ):
            compare_capability_groups(
                self.runtime, actual, RUNTIME_CATEGORIES, "runtime"
            )

    def test_manifest_rejects_count_that_does_not_match_names(self) -> None:
        document = reviewed_manifest_document(
            "9.0", self.runtime, self.registrations
        )
        document["runtimeCapabilities"]["decoders"]["count"] = 99

        with self.assertRaisesRegex(ManifestError, r"count is 99"):
            parse_reviewed_manifest(document)

    def test_runtime_report_must_be_sorted(self) -> None:
        report = {"schemaVersion": 1, **copy.deepcopy(self.runtime)}
        report["decoders"] = ["h264", "aac"]

        with self.assertRaisesRegex(ManifestError, r"must be sorted"):
            parse_runtime_report(report)

    def test_nm_parser_collects_only_reviewed_registration_families(self) -> None:
        nm_output = """
        0000000000000000 S _ff_h264_decoder
                         U _ff_aac_decoder
        0000000000000010 S _ff_mov_demuxer
        0000000000000020 S _ff_spdif_muxer
        0000000000000030 D _ff_https_protocol
        0000000000000040 D _ff_hwcontext_type_videotoolbox
        0000000000000050 T _avcodec_find_decoder
        """

        parsed = extract_registration_symbols(nm_output)

        self.assertEqual(set(parsed), set(REGISTRATION_CATEGORIES))
        self.assertEqual(
            parsed["decoders"], ("_ff_aac_decoder", "_ff_h264_decoder")
        )
        self.assertEqual(parsed["demuxers"], ("_ff_mov_demuxer",))
        self.assertEqual(parsed["muxers"], ("_ff_spdif_muxer",))
        self.assertEqual(parsed["protocols"], ("_ff_https_protocol",))
        self.assertEqual(
            parsed["hardwareDeviceTypes"],
            ("_ff_hwcontext_type_videotoolbox",),
        )

    def test_repository_oracle_preserves_the_shipped_baseline(self) -> None:
        import json

        with (PROJECT_ROOT / "Configuration" / "capabilities.json").open(
            "r", encoding="utf-8"
        ) as stream:
            manifest = parse_reviewed_manifest(json.load(stream))

        self.assertEqual(len(manifest.runtime["decoders"]), 515)
        self.assertEqual(len(manifest.runtime["demuxers"]), 359)
        self.assertEqual(manifest.runtime["muxers"], ("spdif",))
        self.assertEqual(len(manifest.runtime["inputProtocols"]), 33)
        self.assertEqual(
            manifest.runtime["hardwareDeviceTypes"], ("videotoolbox",)
        )


if __name__ == "__main__":
    unittest.main()
