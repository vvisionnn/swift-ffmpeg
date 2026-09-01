#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import stat
import tempfile
import unittest
import warnings
import zipfile


PROJECT_ROOT = Path(__file__).resolve().parents[2]
HELPER_PATH = PROJECT_ROOT / "Scripts/lib/remote_release_verifier.py"
SPEC = importlib.util.spec_from_file_location("remote_release_verifier", HELPER_PATH)
assert SPEC is not None and SPEC.loader is not None
verifier = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(verifier)


TAG = "1.2.3"
CHECKSUM = "a" * 64
REVISION = "b" * 40


def manifest(
    *,
    tag: str = TAG,
    checksum: str = CHECKSUM,
    extra_remote_target: bool = False,
) -> str:
    extra = ""
    if extra_remote_target:
        extra = f'''
        .binaryTarget(
            name: "Other",
            url: "https://example.invalid/Other.xcframework.zip",
            checksum: "{'c' * 64}"
        ),
'''
    return f'''// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "swift-ffmpeg",
    targets: [
        .binaryTarget(
            name: "FFmpeg",
            url: "https://github.com/vvisionnn/swift-ffmpeg/releases/download/{tag}/FFmpeg.xcframework.zip",
            checksum: "{checksum}"
        ),
        {extra}
    ]
)
'''


def add_regular_file(archive: zipfile.ZipFile, name: str, data: bytes = b"ok") -> None:
    info = zipfile.ZipInfo(name)
    info.create_system = 3
    info.external_attr = (stat.S_IFREG | 0o644) << 16
    archive.writestr(info, data)


class InputValidationTests(unittest.TestCase):
    def test_accepts_canonical_stable_semver(self) -> None:
        self.assertEqual(verifier.validate_tag("0.1.0"), "0.1.0")
        self.assertEqual(verifier.validate_tag("10.20.30"), "10.20.30")

    def test_rejects_noncanonical_or_nonstable_tags(self) -> None:
        for value in ("v1.2.3", "01.2.3", "1.02.3", "1.2", "1.2.3-rc.1", "1.2.3+1"):
            with self.subTest(value=value), self.assertRaises(verifier.VerificationError):
                verifier.validate_tag(value)

    def test_validates_optional_ffmpeg_version(self) -> None:
        self.assertEqual(verifier.validate_ffmpeg_version("9.0"), "9.0")
        self.assertEqual(verifier.validate_ffmpeg_version("9.0.1"), "9.0.1")
        for value in ("09.0", "n9.0", "9", "9.0-rc1"):
            with self.subTest(value=value), self.assertRaises(verifier.VerificationError):
                verifier.validate_ffmpeg_version(value)


class ManifestTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.path = Path(self.temporary_directory.name) / "Package.swift"

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def test_extracts_canonical_url_and_checksum(self) -> None:
        self.path.write_text(manifest(), encoding="utf-8")
        result = verifier.inspect_manifest(self.path, TAG, CHECKSUM)
        self.assertEqual(result["checksum"], CHECKSUM)
        self.assertEqual(result["url"], verifier.expected_artifact_url(TAG))

    def test_rejects_a_url_for_another_tag(self) -> None:
        self.path.write_text(manifest(tag="1.2.4"), encoding="utf-8")
        with self.assertRaisesRegex(verifier.VerificationError, "URL mismatch"):
            verifier.inspect_manifest(self.path, TAG)

    def test_rejects_a_mismatched_caller_checksum(self) -> None:
        self.path.write_text(manifest(), encoding="utf-8")
        with self.assertRaisesRegex(verifier.VerificationError, "checksum mismatch"):
            verifier.inspect_manifest(self.path, TAG, "d" * 64)

    def test_rejects_additional_remote_binary_target(self) -> None:
        self.path.write_text(manifest(extra_remote_target=True), encoding="utf-8")
        with self.assertRaisesRegex(verifier.VerificationError, "additional"):
            verifier.inspect_manifest(self.path, TAG)

    def test_rejects_a_non_hex_manifest_checksum(self) -> None:
        self.path.write_text(manifest(checksum="z" * 64), encoding="utf-8")
        with self.assertRaisesRegex(verifier.VerificationError, "Checksum"):
            verifier.inspect_manifest(self.path, TAG)


class SafeExtractionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary_directory.name)
        self.archive_path = self.root / "artifact.zip"

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def _assert_rejected(self, member_name: str) -> None:
        with zipfile.ZipFile(self.archive_path, "w") as archive:
            add_regular_file(archive, member_name)
        with self.assertRaises(verifier.VerificationError):
            verifier.safe_extract(self.archive_path, self.root / "output")

    def test_extracts_only_the_xcframework_tree(self) -> None:
        with zipfile.ZipFile(self.archive_path, "w") as archive:
            add_regular_file(archive, "FFmpeg.xcframework/Info.plist", b"plist")
        destination = self.root / "output"
        verifier.safe_extract(self.archive_path, destination)
        self.assertEqual(
            (destination / "FFmpeg.xcframework/Info.plist").read_bytes(), b"plist"
        )

    def test_rejects_traversal_absolute_backslash_and_wrong_root(self) -> None:
        for member_name in (
            "FFmpeg.xcframework/../escape",
            "/FFmpeg.xcframework/Info.plist",
            "FFmpeg.xcframework\\Info.plist",
            "Other.xcframework/Info.plist",
        ):
            with self.subTest(member_name=member_name):
                self._assert_rejected(member_name)
                output = self.root / "output"
                if output.exists():
                    output.rmdir()

    def test_rejects_symlinks(self) -> None:
        info = zipfile.ZipInfo("FFmpeg.xcframework/link")
        info.create_system = 3
        info.external_attr = (stat.S_IFLNK | 0o777) << 16
        with zipfile.ZipFile(self.archive_path, "w") as archive:
            archive.writestr(info, "../../escape")
        with self.assertRaisesRegex(verifier.VerificationError, "regular file"):
            verifier.safe_extract(self.archive_path, self.root / "output")

    def test_rejects_duplicate_entries(self) -> None:
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(self.archive_path, "w") as archive:
                add_regular_file(archive, "FFmpeg.xcframework/Info.plist")
                add_regular_file(archive, "FFmpeg.xcframework/Info.plist")
        with self.assertRaisesRegex(verifier.VerificationError, "Duplicate"):
            verifier.safe_extract(self.archive_path, self.root / "output")


class ResolvedPinTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.path = Path(self.temporary_directory.name) / "Package.resolved"

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def _write(self, *, tag: str = TAG, revision: str = REVISION, location: str = verifier.REPOSITORY_URL) -> None:
        self.path.write_text(
            json.dumps(
                {
                    "version": 3,
                    "pins": [
                        {
                            "identity": "swift-ffmpeg",
                            "kind": "remoteSourceControl",
                            "location": location,
                            "state": {"revision": revision, "version": tag},
                        }
                    ],
                }
            ),
            encoding="utf-8",
        )

    def test_accepts_the_exact_inspected_pin(self) -> None:
        self._write()
        verifier.verify_resolved(
            self.path, TAG, verifier.REPOSITORY_URL, REVISION
        )

    def test_accepts_swiftpm_file_url_normalization_for_a_fixture(self) -> None:
        with tempfile.TemporaryDirectory(
            prefix="swift-ffmpeg-verifier-unit-", dir="/tmp"
        ) as directory:
            fixture = Path(directory)
            self._write(location=str(fixture.resolve()))
            verifier.verify_resolved(
                self.path, TAG, fixture.as_uri(), REVISION
            )

    def test_rejects_tag_movement(self) -> None:
        self._write(revision="c" * 40)
        with self.assertRaisesRegex(verifier.VerificationError, "moved"):
            verifier.verify_resolved(
                self.path, TAG, verifier.REPOSITORY_URL, REVISION
            )

    def test_rejects_another_repository(self) -> None:
        self._write(location="https://github.com/example/swift-ffmpeg.git")
        with self.assertRaisesRegex(verifier.VerificationError, "unexpected repository"):
            verifier.verify_resolved(
                self.path, TAG, verifier.REPOSITORY_URL, REVISION
            )


if __name__ == "__main__":
    unittest.main()
