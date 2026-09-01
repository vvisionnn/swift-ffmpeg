from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


PROJECT_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_ROOT = PROJECT_ROOT / "Scripts"
sys.path.insert(0, str(SCRIPT_ROOT))

from lib.ffmpeg_release_discovery import (  # noqa: E402
    DiscoveryError,
    MAX_DOCUMENT_BYTES,
    discover_document,
    load_configured_version,
    load_document,
    render_json,
    validate_remote_document_url,
)


FIXTURE_PATH = Path(__file__).parent / "Fixtures" / "stable-9.0.1.html"
CLI_PATH = SCRIPT_ROOT / "discover-ffmpeg-release.py"


class FFmpegReleaseDiscoveryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.fixture = FIXTURE_PATH.read_text(encoding="utf-8")

    def discover(self, document: str | None = None, current: str = "9.0") -> dict:
        return discover_document(document or self.fixture, current)

    def assert_discovery_error(self, document: str, message: str) -> None:
        with self.assertRaisesRegex(DiscoveryError, message):
            self.discover(document)

    def test_discovers_update_from_independent_page_structures(self) -> None:
        self.assertEqual(
            self.discover(),
            {
                "configuredVersion": "9.0",
                "release": {
                    "releaseDate": "2026-08-12",
                    "signatureURL": (
                        "https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz.asc"
                    ),
                    "sourceURL": (
                        "https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz"
                    ),
                    "version": "9.0.1",
                },
                "schemaVersion": 1,
                "updateAvailable": True,
            },
        )

    def test_equal_release_is_not_an_update(self) -> None:
        result = self.discover(current="9.0.1")
        self.assertFalse(result["updateAvailable"])

    def test_deterministic_json_has_sorted_keys_and_final_newline(self) -> None:
        rendered = render_json(self.discover())
        self.assertEqual(rendered, render_json(self.discover()))
        self.assertTrue(rendered.endswith("\n"))
        self.assertEqual(json.loads(rendered)["release"]["version"], "9.0.1")
        self.assertLess(rendered.index('"configuredVersion"'), rendered.index('"release"'))

    def test_rejects_rollback(self) -> None:
        with self.assertRaisesRegex(DiscoveryError, "roll back"):
            self.discover(current="10.0")

    def test_rejects_equivalent_noncanonical_version_spelling(self) -> None:
        document = self.fixture.replace("9.0.1", "9.0.0")
        with self.assertRaisesRegex(DiscoveryError, "different canonical spelling"):
            self.discover(document, current="9.0")

    def test_rejects_duplicate_download_source(self) -> None:
        anchor = (
            '<a href="https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz">'
            "ffmpeg-9.0.1.tar.xz</a>"
        )
        document = self.fixture.replace("</div>\n    </div>", f"{anchor}</div>\n    </div>", 1)
        self.assert_discovery_error(document, "exactly one stable source link")

    def test_rejects_ambiguous_download_sources(self) -> None:
        anchor = (
            '<a href="https://ffmpeg.org/releases/ffmpeg-10.0.tar.xz">'
            "ffmpeg-10.0.tar.xz</a>"
        )
        document = self.fixture.replace("</div>\n    </div>", f"{anchor}</div>\n    </div>", 1)
        self.assert_discovery_error(document, "exactly one stable source link")

    def test_rejects_prerelease_source(self) -> None:
        document = self.fixture.replace("9.0.1", "9.1-rc1")
        self.assert_discovery_error(document, "not a stable FFmpeg release")

    def test_rejects_off_origin_source(self) -> None:
        document = self.fixture.replace(
            "https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz",
            "https://example.com/releases/ffmpeg-9.0.1.tar.xz",
            1,
        )
        self.assert_discovery_error(document, "not a canonical HTTPS URL")

    def test_rejects_insecure_source(self) -> None:
        document = self.fixture.replace(
            "https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz",
            "http://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz",
            1,
        )
        self.assert_discovery_error(document, "not a canonical HTTPS URL")

    def test_rejects_source_query_string(self) -> None:
        document = self.fixture.replace(
            "https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz",
            "https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz?mirror=1",
            1,
        )
        self.assert_discovery_error(document, "not a canonical HTTPS URL")

    def test_rejects_missing_signature(self) -> None:
        document = self.fixture.replace(
            '<small><a href="releases/ffmpeg-9.0.1.tar.xz.asc">PGP signature</a></small>',
            "",
        )
        self.assert_discovery_error(document, "exactly one xz signature link")

    def test_rejects_duplicate_signature(self) -> None:
        signature = (
            '<small><a href="releases/ffmpeg-9.0.1.tar.xz.asc">'
            "PGP signature</a></small>"
        )
        document = self.fixture.replace(signature, signature + signature)
        self.assert_discovery_error(document, "exactly one xz signature link")

    def test_rejects_mismatched_signature_version(self) -> None:
        document = self.fixture.replace(
            "releases/ffmpeg-9.0.1.tar.xz.asc",
            "releases/ffmpeg-9.0.tar.xz.asc",
            1,
        )
        self.assert_discovery_error(document, "different releases")

    def test_rejects_off_origin_signature(self) -> None:
        document = self.fixture.replace(
            "releases/ffmpeg-9.0.1.tar.xz.asc",
            "https://example.com/releases/ffmpeg-9.0.1.tar.xz.asc",
            1,
        )
        self.assert_discovery_error(document, "not a canonical HTTPS URL")

    def test_rejects_off_origin_release_section_source(self) -> None:
        document = self.fixture.replace(
            'href="releases/ffmpeg-9.0.1.tar.xz">Download xz tarball',
            'href="https://example.com/releases/ffmpeg-9.0.1.tar.xz">Download xz tarball',
            1,
        )
        self.assert_discovery_error(document, "not a canonical HTTPS URL")

    def test_rejects_missing_release_section_source(self) -> None:
        document = self.fixture.replace(
            '<a href="releases/ffmpeg-9.0.1.tar.xz">Download xz tarball</a>',
            "",
            1,
        )
        self.assert_discovery_error(document, "exactly one xz source link")

    def test_rejects_mismatched_release_section(self) -> None:
        document = self.fixture.replace('id="release_9.0"', 'id="release_9.1"', 1)
        self.assert_discovery_error(document, "matching stable release section")

    def test_rejects_duplicate_matching_release_section(self) -> None:
        selected = self.fixture.split('<h3 id="release_9.0">', 1)[1].split(
            '<h3 id="release_8.1">', 1
        )[0]
        duplicate = '<h3 id="release_9.0">' + selected
        document = self.fixture.replace(
            '<h3 id="release_8.1">', duplicate + '<h3 id="release_8.1">'
        )
        self.assert_discovery_error(document, "exactly one matching stable release section")

    def test_rejects_missing_latest_stable_statement(self) -> None:
        document = self.fixture.replace(
            "latest stable FFmpeg release", "supported FFmpeg release", 1
        )
        self.assert_discovery_error(document, "latest-stable release statement")

    def test_rejects_malformed_release_date(self) -> None:
        document = self.fixture.replace("2026-08-12", "2026-02-31", 1)
        self.assert_discovery_error(document, "Invalid upstream release date")

    def test_rejects_download_label_without_filename(self) -> None:
        document = self.fixture.replace(
            "<small>ffmpeg-9.0.1.tar.xz</small>", "<small>download</small>", 1
        )
        self.assert_discovery_error(document, "label does not identify")

    def test_rejects_duplicate_download_container(self) -> None:
        document = self.fixture.replace(
            "<body>", '<body><div id="download"></div>', 1
        )
        self.assert_discovery_error(document, "exactly one download container")

    def test_rejects_duplicate_security_relevant_attribute(self) -> None:
        document = self.fixture.replace(
            'href="https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz"',
            'href="https://ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz" '
            'href="https://example.com/releases/ffmpeg-9.0.1.tar.xz"',
            1,
        )
        self.assert_discovery_error(document, "Duplicate 'href' attribute")

    def test_rejects_unclosed_critical_element(self) -> None:
        before, _, after = self.fixture.rpartition("</a>")
        document = before + after
        self.assert_discovery_error(document, "unclosed critical elements")

    def test_remote_input_must_be_exact_canonical_url(self) -> None:
        rejected = [
            "http://ffmpeg.org/download.html",
            "https://example.com/download.html",
            "https://www.ffmpeg.org/download.html",
            "https://user@ffmpeg.org/download.html",
            "https://ffmpeg.org:443/download.html",
            "https://ffmpeg.org:not-a-port/download.html",
            "https://ffmpeg.org/download.html?source=test",
            "https://ffmpeg.org/download.html#download",
            "https://ffmpeg.org/releases/",
        ]
        for url in rejected:
            with self.subTest(url=url):
                with self.assertRaisesRegex(
                    DiscoveryError, "must be exactly|Malformed remote discovery input"
                ):
                    validate_remote_document_url(url)
        validate_remote_document_url("https://ffmpeg.org/download.html")

    def test_local_fixture_must_be_utf8_and_size_bounded(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            invalid_utf8 = Path(directory) / "invalid.html"
            invalid_utf8.write_bytes(b"\xff")
            with self.assertRaisesRegex(DiscoveryError, "not valid UTF-8"):
                load_document(str(invalid_utf8))

            oversized = Path(directory) / "oversized.html"
            oversized.write_bytes(b"x" * (MAX_DOCUMENT_BYTES + 1))
            with self.assertRaisesRegex(DiscoveryError, "exceeds"):
                load_document(str(oversized))

    def test_configuration_rejects_duplicate_keys_and_unstable_version(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "release.json"
            config.write_text(
                '{"ffmpeg":{"version":"9.0","version":"9.0.1"}}',
                encoding="utf-8",
            )
            with self.assertRaisesRegex(DiscoveryError, "Duplicate configuration key"):
                load_configured_version(config)

            config.write_text(
                '{"ffmpeg":{"version":"9.1-rc1"}}', encoding="utf-8"
            )
            with self.assertRaisesRegex(DiscoveryError, "not a stable"):
                load_configured_version(config)

    def test_cli_uses_local_fixture_and_emits_only_json_to_stdout(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "release.json"
            config.write_text('{"ffmpeg":{"version":"9.0"}}', encoding="utf-8")
            process = subprocess.run(
                [
                    sys.executable,
                    str(CLI_PATH),
                    "--source",
                    str(FIXTURE_PATH),
                    "--config",
                    str(config),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(process.stderr, "")
        self.assertEqual(json.loads(process.stdout)["release"]["version"], "9.0.1")

    def test_cli_reports_fail_closed_error_without_traceback(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory) / "ambiguous.html"
            fixture.write_text(
                self.fixture.replace(
                    "</div>\n    </div>",
                    '<a href="releases/ffmpeg-10.0.tar.xz">ffmpeg-10.0.tar.xz</a>'
                    "</div>\n    </div>",
                    1,
                ),
                encoding="utf-8",
            )
            config = Path(directory) / "release.json"
            config.write_text('{"ffmpeg":{"version":"9.0"}}', encoding="utf-8")
            process = subprocess.run(
                [
                    sys.executable,
                    str(CLI_PATH),
                    "--source",
                    str(fixture),
                    "--config",
                    str(config),
                ],
                check=False,
                capture_output=True,
                text=True,
            )
        self.assertEqual(process.returncode, 2)
        self.assertEqual(process.stdout, "")
        self.assertIn("error:", process.stderr)
        self.assertNotIn("Traceback", process.stderr)


if __name__ == "__main__":
    unittest.main()
