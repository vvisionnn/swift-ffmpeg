from __future__ import annotations

import copy
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
import warnings
import zipfile


PROJECT_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_ROOT = PROJECT_ROOT / "Scripts"
sys.path.insert(0, str(SCRIPT_ROOT))

from lib.release_candidate import (  # noqa: E402
    ARTIFACT_NAME,
    CandidateError,
    PLACEHOLDER_SHA256,
    SLICE_ARCHIVES,
    advance_capability_oracle,
    finalize_candidate_documents,
    generate_candidate_documents,
    parse_json_bytes,
    verify_release_zip_matches_xcframework,
)


REAL_SHA = "1" * 64
NEW_SOURCE_SHA = "2" * 64
BASE_ARTIFACT_SHA = "3" * 64


def base_config() -> dict:
    return {
        "artifact": {
            "name": ARTIFACT_NAME,
            "swiftPackageChecksum": BASE_ARTIFACT_SHA,
            "xcframework": {
                "infoPlistSHA256": "4" * 64,
                "slices": {
                    "ios-arm64": "5" * 64,
                    "ios-arm64_x86_64-simulator": "6" * 64,
                    "macos-arm64_x86_64": "7" * 64,
                },
            },
        },
        "build": {
            "iOSMinimumVersion": "15.0",
            "macOSMinimumVersion": "12.0",
            "sourceDateEpoch": 1785824040,
        },
        "dav1d": {
            "sha256": "8" * 64,
            "url": (
                "https://code.videolan.org/videolan/dav1d/-/archive/"
                "1.5.4/dav1d-1.5.4.tar.bz2"
            ),
            "version": "1.5.4",
        },
        "ffmpeg": {
            "releaseKeyFingerprint": "A" * 40,
            "releaseKeySHA256": "9" * 64,
            "sha256": REAL_SHA,
            "signatureURL": (
                "https://ffmpeg.org/releases/ffmpeg-9.0.tar.xz.asc"
            ),
            "url": "https://ffmpeg.org/releases/ffmpeg-9.0.tar.xz",
            "version": "9.0",
        },
        "packageVersion": "1.0.0",
        "schemaVersion": 1,
        "toolchain": {
            "cctoolsVersion": "cctools-test",
            "clangVersion": "clang-test",
            "iPhoneOSSDKVersion": "18.5",
            "iPhoneSimulatorSDKVersion": "18.5",
            "macOSSDKVersion": "15.5",
            "makeVersion": "make-test",
            "mesonVersion": "meson-test",
            "ninjaVersion": "ninja-test",
            "pkgConfigVersion": "pkg-config-test",
            "xcodeBuild": "16F6",
            "xcodeVersion": "16.4",
        },
    }


def base_package() -> str:
    return f'''// swift-tools-version: 6.1

import PackageDescription

// This comment and all surrounding bytes must survive candidate generation.
let ffmpegBinaryTarget: Target =
    Context.environment["SWIFT_FFMPEG_USE_LOCAL_XCFRAMEWORK"] == "1"
        ? .binaryTarget(name: "FFmpeg", path: "Artifacts/FFmpeg.xcframework")
        : .binaryTarget(
            name: "FFmpeg",
            url: "https://github.com/vvisionnn/swift-ffmpeg/releases/download/1.0.0/{ARTIFACT_NAME}",
            checksum: "{BASE_ARTIFACT_SHA}"
        )

let untouched = "sentinel"
'''


def discovery(version: str = "9.0.1", configured: str = "9.0") -> dict:
    return {
        "configuredVersion": configured,
        "release": {
            "releaseDate": "2026-08-12",
            "signatureURL": (
                f"https://ffmpeg.org/releases/ffmpeg-{version}.tar.xz.asc"
            ),
            "sourceURL": f"https://ffmpeg.org/releases/ffmpeg-{version}.tar.xz",
            "version": version,
        },
        "schemaVersion": 1,
        "updateAvailable": True,
    }


def capabilities(version: str) -> dict:
    runtime = {
        "decoders": ["aac", "h264"],
        "demuxers": ["mov", "wav"],
        "muxers": ["spdif"],
        "inputProtocols": ["file", "https"],
        "hardwareDeviceTypes": ["videotoolbox"],
    }
    registrations = {
        "decoders": ["_ff_aac_decoder", "_ff_h264_decoder"],
        "demuxers": ["_ff_mov_demuxer", "_ff_wav_demuxer"],
        "muxers": ["_ff_spdif_muxer"],
        "protocols": ["_ff_file_protocol", "_ff_https_protocol"],
        "hardwareDeviceTypes": ["_ff_hwcontext_type_videotoolbox"],
    }
    return {
        "schemaVersion": 1,
        "generatedFrom": {"ffmpegVersion": version},
        "runtimeCapabilities": {
            key: {"count": len(names), "names": names}
            for key, names in runtime.items()
        },
        "registrationSymbols": {
            key: {"count": len(names), "names": names}
            for key, names in registrations.items()
        },
    }


def write_xcframework(root: Path) -> Path:
    framework = root / "FFmpeg.xcframework"
    (framework / "Info.plist").parent.mkdir(parents=True)
    (framework / "Info.plist").write_bytes(b"plist-sentinel")
    for index, relative in enumerate(SLICE_ARCHIVES.values()):
        path = framework / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(
            f"archive-{index}\x00FFmpeg version 9.0.1\x00".encode()
        )
        (path.parent / "Headers").mkdir()
        (path.parent / "Headers" / "FFmpeg.h").write_bytes(b"header")
    return framework


def write_zip(framework: Path, output: Path) -> None:
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(framework.rglob("*")):
            if path.is_file():
                relative = path.relative_to(framework).as_posix()
                archive.write(path, f"FFmpeg.xcframework/{relative}")


class ReleaseCandidateGenerationTests(unittest.TestCase):
    def test_generates_next_point_candidate_and_preserves_unrelated_content(self) -> None:
        original_config = base_config()
        original_package = base_package()
        candidate, package = generate_candidate_documents(
            original_config,
            original_package,
            discovery(),
            NEW_SOURCE_SHA,
        )

        self.assertEqual(original_config, base_config())
        self.assertEqual(candidate["packageVersion"], "1.0.1")
        self.assertEqual(candidate["ffmpeg"]["version"], "9.0.1")
        self.assertEqual(candidate["ffmpeg"]["sha256"], NEW_SOURCE_SHA)
        self.assertEqual(candidate["dav1d"], original_config["dav1d"])
        self.assertEqual(candidate["build"]["iOSMinimumVersion"], "15.0")
        self.assertEqual(candidate["build"]["macOSMinimumVersion"], "12.0")
        self.assertEqual(candidate["build"]["sourceDateEpoch"], 1786492800)
        self.assertEqual(candidate["toolchain"], original_config["toolchain"])
        hashes = [
            candidate["artifact"]["swiftPackageChecksum"],
            candidate["artifact"]["xcframework"]["infoPlistSHA256"],
            *candidate["artifact"]["xcframework"]["slices"].values(),
        ]
        self.assertEqual(hashes, [PLACEHOLDER_SHA256] * 5)
        expected_package = original_package.replace(
            "/1.0.0/", "/1.0.1/"
        ).replace(BASE_ARTIFACT_SHA, PLACEHOLDER_SHA256)
        self.assertEqual(package, expected_package)

    def test_rejects_rollback_and_equal_release(self) -> None:
        for version in ("8.1.2", "9.0"):
            with self.subTest(version=version), self.assertRaisesRegex(
                CandidateError, "roll back or repeat"
            ):
                generate_candidate_documents(
                    base_config(), base_package(), discovery(version), NEW_SOURCE_SHA
                )

    def test_rejects_non_point_branch_and_skipped_point(self) -> None:
        for version, message in (
            ("9.1", "point-release branch"),
            ("10.0", "point-release branch"),
            ("9.0.2", "exactly one point release"),
        ):
            with self.subTest(version=version), self.assertRaisesRegex(
                CandidateError, message
            ):
                generate_candidate_documents(
                    base_config(), base_package(), discovery(version), NEW_SOURCE_SHA
                )

    def test_rejects_prerelease_and_noncanonical_zero_patch(self) -> None:
        for version in ("9.0-rc1", "9.0.0"):
            with self.subTest(version=version), self.assertRaisesRegex(
                CandidateError, "canonical stable FFmpeg version"
            ):
                generate_candidate_documents(
                    base_config(), base_package(), discovery(version), NEW_SOURCE_SHA
                )

    def test_rejects_discovery_schema_ambiguity_and_stale_configuration(self) -> None:
        cases = []
        wrong_schema = discovery()
        wrong_schema["schemaVersion"] = True
        cases.append(wrong_schema)
        extra_key = discovery()
        extra_key["unexpected"] = "value"
        cases.append(extra_key)
        stale = discovery(configured="8.1")
        cases.append(stale)
        not_update = discovery()
        not_update["updateAvailable"] = 1
        cases.append(not_update)
        for document in cases:
            with self.subTest(document=document), self.assertRaises(CandidateError):
                generate_candidate_documents(
                    base_config(), base_package(), document, NEW_SOURCE_SHA
                )

    def test_rejects_noncanonical_urls_and_invalid_release_date(self) -> None:
        cases = []
        source = discovery()
        source["release"]["sourceURL"] = "https://example.com/ffmpeg-9.0.1.tar.xz"
        cases.append(source)
        signature = discovery()
        signature["release"]["signatureURL"] += "?mirror=1"
        cases.append(signature)
        date = discovery()
        date["release"]["releaseDate"] = "2026-02-30"
        cases.append(date)
        for document in cases:
            with self.subTest(document=document), self.assertRaises(CandidateError):
                generate_candidate_documents(
                    base_config(), base_package(), document, NEW_SOURCE_SHA
                )

    def test_rejects_untrusted_source_digest_forms(self) -> None:
        for digest in ("A" * 64, "f" * 63, PLACEHOLDER_SHA256):
            with self.subTest(digest=digest), self.assertRaises(CandidateError):
                generate_candidate_documents(
                    base_config(), base_package(), discovery(), digest
                )

    def test_rejects_package_url_checksum_and_duplicate_target_mismatch(self) -> None:
        packages = (
            base_package().replace("/1.0.0/", "/0.9.0/"),
            base_package().replace(BASE_ARTIFACT_SHA, "f" * 64),
            base_package() + base_package(),
        )
        for package in packages:
            with self.subTest(package=package), self.assertRaises(CandidateError):
                generate_candidate_documents(
                    base_config(), package, discovery(), NEW_SOURCE_SHA
                )

    def test_rejects_base_with_pending_or_malformed_schema(self) -> None:
        pending = base_config()
        pending["artifact"]["swiftPackageChecksum"] = PLACEHOLDER_SHA256
        unexpected = base_config()
        unexpected["artifact"]["unexpected"] = "not in schema one"
        for document in (pending, unexpected):
            with self.subTest(document=document), self.assertRaises(CandidateError):
                generate_candidate_documents(
                    document, base_package(), discovery(), NEW_SOURCE_SHA
                )

    def test_duplicate_json_keys_and_nonfinite_numbers_fail_closed(self) -> None:
        with self.assertRaisesRegex(CandidateError, "duplicate JSON key"):
            parse_json_bytes(b'{"schemaVersion":1,"schemaVersion":1}', "fixture")
        with self.assertRaisesRegex(CandidateError, "invalid JSON constant"):
            parse_json_bytes(b'{"value":NaN}', "fixture")


class ReleaseCandidateFinalizationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.framework = write_xcframework(self.root)
        self.release_zip = self.root / ARTIFACT_NAME
        write_zip(self.framework, self.release_zip)
        self.candidate, self.package = generate_candidate_documents(
            base_config(), base_package(), discovery(), NEW_SOURCE_SHA
        )
        self.reviewed = capabilities("9.0")
        self.built = capabilities("9.0.1")

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def finalize(self):
        return finalize_candidate_documents(
            self.candidate,
            self.package,
            self.framework,
            self.release_zip,
            self.reviewed,
            self.built,
        )

    def test_finalizes_exact_hashes_url_and_capability_version_only(self) -> None:
        config, package, oracle, digests = self.finalize()

        expected_zip = hashlib.sha256(self.release_zip.read_bytes()).hexdigest()
        self.assertEqual(config["artifact"]["swiftPackageChecksum"], expected_zip)
        self.assertEqual(digests["swiftPackageChecksum"], expected_zip)
        self.assertIn("/1.0.1/FFmpeg.xcframework.zip", package)
        self.assertIn(f'checksum: "{expected_zip}"', package)
        self.assertEqual(config["ffmpeg"], self.candidate["ffmpeg"])
        self.assertEqual(config["build"], self.candidate["build"])
        for slice_name, relative in SLICE_ARCHIVES.items():
            expected = hashlib.sha256((self.framework / relative).read_bytes()).hexdigest()
            self.assertEqual(
                config["artifact"]["xcframework"]["slices"][slice_name],
                expected,
            )
        expected_oracle = copy.deepcopy(self.reviewed)
        expected_oracle["generatedFrom"]["ffmpegVersion"] = "9.0.1"
        self.assertEqual(oracle, expected_oracle)

    def test_capability_name_addition_or_loss_blocks_finalization(self) -> None:
        for mutation in ("addition", "loss"):
            built = copy.deepcopy(self.built)
            names = built["runtimeCapabilities"]["decoders"]["names"]
            if mutation == "addition":
                names.append("zlib")
            else:
                names.pop()
            built["runtimeCapabilities"]["decoders"]["count"] = len(names)
            with self.subTest(mutation=mutation), self.assertRaisesRegex(
                CandidateError, "explicit capability review"
            ):
                finalize_candidate_documents(
                    self.candidate,
                    self.package,
                    self.framework,
                    self.release_zip,
                    self.reviewed,
                    built,
                )

    def test_capability_count_and_version_mismatches_fail_closed(self) -> None:
        wrong_count = copy.deepcopy(self.built)
        wrong_count["registrationSymbols"]["muxers"]["count"] = 9
        with self.assertRaisesRegex(CandidateError, "count does not match"):
            finalize_candidate_documents(
                self.candidate,
                self.package,
                self.framework,
                self.release_zip,
                self.reviewed,
                wrong_count,
            )
        wrong_version = copy.deepcopy(self.built)
        wrong_version["generatedFrom"]["ffmpegVersion"] = "9.0.2"
        with self.assertRaisesRegex(CandidateError, "does not match"):
            finalize_candidate_documents(
                self.candidate,
                self.package,
                self.framework,
                self.release_zip,
                self.reviewed,
                wrong_version,
            )

    def test_finalizer_requires_every_candidate_digest_to_be_placeholder(self) -> None:
        candidate = copy.deepcopy(self.candidate)
        candidate["artifact"]["xcframework"]["infoPlistSHA256"] = "f" * 64
        with self.assertRaisesRegex(CandidateError, "pending placeholders"):
            finalize_candidate_documents(
                candidate,
                self.package,
                self.framework,
                self.release_zip,
                self.reviewed,
                self.built,
            )

    def test_zip_content_change_and_unexpected_file_are_rejected(self) -> None:
        changed = self.root / "changed.zip"
        write_zip(self.framework, changed)
        with zipfile.ZipFile(changed, "a") as archive:
            archive.writestr("FFmpeg.xcframework/unexpected", b"unexpected")
        with self.assertRaisesRegex(CandidateError, "does not exactly match"):
            verify_release_zip_matches_xcframework(changed, self.framework)

        altered = self.root / "altered.zip"
        write_zip(self.framework, altered)
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(altered, "a") as archive:
                archive.writestr("FFmpeg.xcframework/Info.plist", b"altered")
        with self.assertRaisesRegex(CandidateError, "duplicate path"):
            verify_release_zip_matches_xcframework(altered, self.framework)

    def test_zip_traversal_off_root_and_symlink_are_rejected(self) -> None:
        cases: list[tuple[str, callable]] = []

        def traversal(archive: zipfile.ZipFile) -> None:
            archive.writestr("FFmpeg.xcframework/../escape", b"escape")

        def off_root(archive: zipfile.ZipFile) -> None:
            archive.writestr("Other.framework/file", b"file")

        def symlink(archive: zipfile.ZipFile) -> None:
            info = zipfile.ZipInfo("FFmpeg.xcframework/link")
            info.create_system = 3
            info.external_attr = (stat.S_IFLNK | 0o777) << 16
            archive.writestr(info, b"Info.plist")

        cases.extend((name, writer) for name, writer in (
            ("traversal", traversal),
            ("off-root", off_root),
            ("symlink", symlink),
        ))
        for name, writer in cases:
            path = self.root / f"{name}.zip"
            with zipfile.ZipFile(path, "w") as archive:
                writer(archive)
            with self.subTest(name=name), self.assertRaises(CandidateError):
                verify_release_zip_matches_xcframework(path, self.framework)

    def test_embedded_binary_version_mismatch_blocks_finalization(self) -> None:
        archive = self.framework / SLICE_ARCHIVES["ios-arm64"]
        archive.write_bytes(b"FFmpeg version 9.0\x00")
        write_zip(self.framework, self.release_zip)
        with self.assertRaisesRegex(CandidateError, "embedded FFmpeg version mismatch"):
            self.finalize()


class ReleaseCandidateCLITests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.config = self.root / "release.json"
        self.package = self.root / "Package.swift"
        self.discovery = self.root / "discovery.json"
        self.config.write_text(json.dumps(base_config()), encoding="utf-8")
        self.package.write_text(base_package(), encoding="utf-8")
        self.discovery.write_text(json.dumps(discovery()), encoding="utf-8")

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def run_cli(self, script: str, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SCRIPT_ROOT / script), *arguments],
            cwd=PROJECT_ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def test_generator_writes_only_explicit_outputs_atomically(self) -> None:
        output_config = self.root / "candidate.json"
        output_package = self.root / "Candidate.swift"
        result = self.run_cli(
            "generate-release-candidate.py",
            "--base-config", str(self.config),
            "--base-package", str(self.package),
            "--discovery", str(self.discovery),
            "--ffmpeg-source-sha256", NEW_SOURCE_SHA,
            "--output-config", str(output_config),
            "--output-package", str(output_package),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["packageVersion"], "1.0.1")
        self.assertTrue(output_config.is_file())
        self.assertTrue(output_package.is_file())
        self.assertEqual(
            sorted(path.name for path in self.root.iterdir()),
            [
                "Candidate.swift",
                "Package.swift",
                "candidate.json",
                "discovery.json",
                "release.json",
            ],
        )

    def test_relative_output_and_input_alias_are_rejected_without_writes(self) -> None:
        result = self.run_cli(
            "generate-release-candidate.py",
            "--base-config", str(self.config),
            "--base-package", str(self.package),
            "--discovery", str(self.discovery),
            "--ffmpeg-source-sha256", NEW_SOURCE_SHA,
            "--output-config", "relative.json",
            "--output-package", str(self.root / "candidate.swift"),
        )
        self.assertEqual(result.returncode, 2)
        self.assertFalse((PROJECT_ROOT / "relative.json").exists())
        self.assertFalse((self.root / "candidate.swift").exists())

        original = self.config.read_bytes()
        alias = self.run_cli(
            "generate-release-candidate.py",
            "--base-config", str(self.config),
            "--base-package", str(self.package),
            "--discovery", str(self.discovery),
            "--ffmpeg-source-sha256", NEW_SOURCE_SHA,
            "--output-config", str(self.config),
            "--output-package", str(self.root / "candidate.swift"),
        )
        self.assertEqual(alias.returncode, 2)
        self.assertEqual(self.config.read_bytes(), original)
        self.assertFalse((self.root / "candidate.swift").exists())

    def test_symlink_output_is_rejected_without_touching_target(self) -> None:
        target = self.root / "target.json"
        target.write_text("sentinel", encoding="utf-8")
        link = self.root / "output.json"
        link.symlink_to(target)
        result = self.run_cli(
            "generate-release-candidate.py",
            "--base-config", str(self.config),
            "--base-package", str(self.package),
            "--discovery", str(self.discovery),
            "--ffmpeg-source-sha256", NEW_SOURCE_SHA,
            "--output-config", str(link),
            "--output-package", str(self.root / "candidate.swift"),
        )
        self.assertEqual(result.returncode, 2)
        self.assertEqual(target.read_text(encoding="utf-8"), "sentinel")
        self.assertFalse((self.root / "candidate.swift").exists())

    def test_finalizer_cli_writes_all_three_outputs_after_capability_parity(self) -> None:
        candidate_config = self.root / "candidate.json"
        candidate_package = self.root / "Candidate.swift"
        candidate, package = generate_candidate_documents(
            base_config(), base_package(), discovery(), NEW_SOURCE_SHA
        )
        candidate_config.write_text(json.dumps(candidate), encoding="utf-8")
        candidate_package.write_text(package, encoding="utf-8")
        framework = write_xcframework(self.root)
        release_zip = self.root / ARTIFACT_NAME
        write_zip(framework, release_zip)
        oracle = self.root / "capabilities.json"
        built = self.root / "built-capabilities.json"
        oracle.write_text(json.dumps(capabilities("9.0")), encoding="utf-8")
        built.write_text(json.dumps(capabilities("9.0.1")), encoding="utf-8")
        final_config = self.root / "final.json"
        final_package = self.root / "Final.swift"
        final_oracle = self.root / "final-capabilities.json"
        result = self.run_cli(
            "finalize-release-candidate.py",
            "--candidate-config", str(candidate_config),
            "--candidate-package", str(candidate_package),
            "--xcframework", str(framework),
            "--release-zip", str(release_zip),
            "--capability-oracle", str(oracle),
            "--built-capabilities", str(built),
            "--output-config", str(final_config),
            "--output-package", str(final_package),
            "--output-capability-oracle", str(final_oracle),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            json.loads(final_oracle.read_text())["generatedFrom"]["ffmpegVersion"],
            "9.0.1",
        )
        self.assertEqual(
            json.loads(final_config.read_text())["packageVersion"], "1.0.1"
        )
        self.assertIn(json.loads(result.stdout)["swiftPackageChecksum"], final_package.read_text())

    def test_capability_mismatch_cli_leaves_every_output_absent(self) -> None:
        candidate_config = self.root / "candidate.json"
        candidate_package = self.root / "Candidate.swift"
        candidate, package = generate_candidate_documents(
            base_config(), base_package(), discovery(), NEW_SOURCE_SHA
        )
        candidate_config.write_text(json.dumps(candidate), encoding="utf-8")
        candidate_package.write_text(package, encoding="utf-8")
        framework = write_xcframework(self.root)
        release_zip = self.root / ARTIFACT_NAME
        write_zip(framework, release_zip)
        oracle = self.root / "capabilities.json"
        built = self.root / "built-capabilities.json"
        oracle.write_text(json.dumps(capabilities("9.0")), encoding="utf-8")
        changed = capabilities("9.0.1")
        changed["runtimeCapabilities"]["decoders"]["names"].append("zlib")
        changed["runtimeCapabilities"]["decoders"]["count"] += 1
        built.write_text(json.dumps(changed), encoding="utf-8")
        outputs = [
            self.root / "final.json",
            self.root / "Final.swift",
            self.root / "final-capabilities.json",
        ]
        result = self.run_cli(
            "finalize-release-candidate.py",
            "--candidate-config", str(candidate_config),
            "--candidate-package", str(candidate_package),
            "--xcframework", str(framework),
            "--release-zip", str(release_zip),
            "--capability-oracle", str(oracle),
            "--built-capabilities", str(built),
            "--output-config", str(outputs[0]),
            "--output-package", str(outputs[1]),
            "--output-capability-oracle", str(outputs[2]),
        )
        self.assertEqual(result.returncode, 2)
        self.assertTrue(all(not path.exists() for path in outputs))


if __name__ == "__main__":
    unittest.main()
