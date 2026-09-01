# swift-ffmpeg implementation plan

This is the authoritative ledger for creating a small, independently
maintained Apple FFmpeg package. The goal is packaging and release automation,
not a playback framework.

## Mission

Publish an immutable, checksum-pinned `FFmpeg` Swift package product for iOS,
iOS Simulator, and macOS. Every release must be reproducible, LGPL-compliant,
validated as a fresh SwiftPM dependency, and built from the canonical signed
FFmpeg source. A daily GitHub Actions check should do no expensive build when
upstream is unchanged and should fail closed before publication when anything
changes unexpectedly.

## Boundary

`swift-ffmpeg` owns only:

- canonical FFmpeg and dav1d source discovery, download, and verification;
- the reviewed local FFmpeg hardening patches;
- deterministic five-slice compilation and three-variant XCFramework assembly;
- binary, module, platform, configuration, symbol, license, and consumer tests;
- release archives, checksums, source/relink kits, provenance, and automation.

It does not own a player, Swift playback API, UI, media policy, custom network
transport, authentication, subtitles, or consumer-specific C shims. Its sole
library product and Clang module are both named `FFmpeg`.

## Supported artifact

| Variant | Architectures | Minimum OS |
| --- | --- | --- |
| iOS device | arm64 | iOS 15 |
| iOS Simulator | arm64, x86_64 | iOS 15 |
| macOS | arm64, x86_64 | macOS 12 |

No other Apple platform, Linux, or Windows support is claimed until a native
slice and an executable qualification gate exist for it.

## Release contract

- Version the Swift package independently from FFmpeg so a packaging-only
  correction has a valid new SemVer: bump the package major when a linked
  FFmpeg library major changes, minor for upstream feature releases with
  stable library majors, and patch for upstream point releases or packaging
  corrections. Record both versions in every manifest and release title.
  Never move a tag, replace an asset, or mutate a published release.
- Poll FFmpeg's canonical download page, not its GitHub mirror. Accept only the
  latest stable source tarball and detached signature served by `ffmpeg.org`.
- Verify the signature with an isolated checked-in release-key keyring and the
  exact allowed fingerprint before extracting anything.
- Keep dav1d at an explicitly reviewed version and SHA-256; updating it is a
  separate manifest change, even when triggered by an FFmpeg release.
- Build FFmpeg twice in independent roots, normalize the release ZIP twice,
  and require equal SHA-256 digests before promotion.
- Keep GPL, version-3-only, nonfree features, encoders, `avfilter`, and all
  muxers except `spdif` disabled. Preserve network, SecureTransport,
  VideoToolbox, AudioToolbox, zlib, bz2, iconv, and dav1d support.
- Preserve the reviewed decoder limits and the removal of private
  `_SecIdentityCreate`; a patch mismatch blocks a release.
- Put `FFmpeg.xcframework` at the ZIP root. The tag's `Package.swift` must name
  that same tag's GitHub Release URL and the checksum calculated by SwiftPM.
- Attach exact corresponding sources, patches, checksums, toolchain manifest,
  licenses, notices, relinking instructions, and build provenance to every
  binary release.
- Validate locally against the exact ZIP before publication, then validate a
  fresh remote SwiftPM consumer after the immutable tag and asset exist.

## Milestones

### 1. Architecture and baseline

- [x] Confirm the package boundary is the third-party `FFmpeg` binary target
  and does not include consumer-specific shims or media APIs.
- [x] Record the current FFmpeg 9.0/dav1d 1.5.4 artifact as the parity oracle:
  five thin slices, three variants, 515 decoders, 359 demuxers, one `spdif`
  muxer, 33 input protocols, and no private `_SecIdentityCreate` reference.
- [x] Record the canonical upstream and GitHub Actions security/release model.
- [x] Commit this plan as isolated checkpoint `37d91a8`.

### 2. Local package and reproducible build

- [x] Add the Swift package manifest, source manifest, patch series, legal
  materials, support headers, documentation, and ignored build directories.
- [x] Add pinned `mise` tools and task wrappers while keeping the invoked shell
  scripts directly runnable for contributors and relinking recipients.
- [x] Generalize the existing deterministic builder around explicit
  `DEVELOPER_DIR`, source-manifest inputs, isolated download/cache directories,
  and output paths.
- [x] Add cheap source/upstream checks plus artifact, configuration, symbol,
  platform, module import, package-consumer, and reproducibility gates.
- [x] Build and validate the initial XCFramework locally.

### 3. Public repository and bootstrap release

- [x] Create only `vvisionnn/swift-ffmpeg` as a public GitHub repository and
  push the locally reviewed history.
- [x] Add SHA-pinned, read-only-by-default CI for pushes, pull requests, and
  manual runs.
- [x] Bootstrap `1.0.0` as an immutable FFmpeg 9.0 parity release, calculate its
  SwiftPM checksum, commit the matching remote manifest, and prove a fresh
  remote consumer can import and link `FFmpeg` on macOS and iOS Simulator.

### 4. Daily upstream automation

- [ ] Add a serialized daily/default-branch and manual workflow that exits
  successfully without a macOS build when the stable version is unchanged.
- [ ] For a new version, verify source provenance, build twice, validate every
  gate, prepare the same-tag manifest, create a draft release, upload and
  verify all assets, attest the binary/source-kit provenance, publish, and
  synchronize the released manifest to `main`.
- [ ] Manually dispatch the workflow for current stable FFmpeg 9.0.1, produce
  the independently versioned package update, and debug at most five attempts
  until the hosted release and post-publish remote consumer tests pass.

### 5. Consumer integration

- [ ] Switch the target consumer from its local binary target to an exact
  `swift-ffmpeg` package/product dependency and generate deterministic lockfiles.
- [ ] Remove only externalized FFmpeg/dav1d binary-build inputs while retaining
  all consumer sources, subtitles, fixtures, behavior, and public APIs.
- [ ] Update architecture/release scanners and consumer documentation.
- [ ] Pass the full package, policy, coverage (at least 95%), platform,
  Simulator, codec/format, Demo, audio/video GUI, and metrics qualification.
- [ ] Complete both plan ledgers, commit each isolated result, push both repos,
  and verify clean synchronized local and remote states.

## Retry ledger

Each failing milestone gate gets at most five fix-and-retry attempts. A failed
release never reuses a published version or asset.

| Gate | Attempt | Result / next action |
| --- | ---: | --- |
| Architecture and plan | 1 | PASS: minimal ownership and immutable release model recorded |
| Local package | 1 | PASS: signed sources, five-slice build, deterministic ZIP, macOS consumer, and iPhone 16 Simulator gates passed |
| Bootstrap release | 2 | PASS: immutable `1.0.0`, exact assets, and clean local remote-consumer fixture |
| Daily upstream release | 0 | Not started |
| Consumer integration | 0 | Not started |
| Final qualification | 0 | Not started |

## Evidence ledger

Evidence will be appended as each checkbox completes. A checkbox is not done
without the command, artifact digest, workflow run, test result, or manual
observation that proves it.

- Architecture plan committed at `37d91a8`; the package façade and legal/docs
  surface committed at `a044bbf`.
- `Scripts/fetch-sources.sh` verified FFmpeg 9.0's detached signature with the
  pinned `FCF986EA15E6E293A5644F10B4322F04D67658D8` key, plus the configured
  FFmpeg and dav1d SHA-256 digests and archive roots.
- `Scripts/build-xcframework.sh` rebuilt all five slices with Xcode 16.4
  (`16F6`), iOS SDK 18.5, and macOS SDK 15.5, then assembled the three expected
  variants with no private symbol or configuration-policy rejection.
- `Scripts/validate-artifact.sh` accepted the host-path-independent archive
  hashes: `85edc67f...192ba` (iOS), `84cb9a14...f6f16` (Simulator), and
  `277b50f5...37fd7` (macOS).
- Two normalized packages matched SwiftPM checksum
  `02a8f3f7...e9b66`. Three Swift package smoke tests, a release build, and an
  external consumer with no linker settings passed on macOS.
- Two complete builds from distinct checkout roots and distinct Xcode path
  aliases produced the same XCFramework file manifest and release ZIP in
  661 seconds. Exact capability parity passed for all five thin slices.
- Simulator attempt 1 rejected the assumed `swift-ffmpeg-Package` scheme;
  after binding the generated `swift-ffmpeg` scheme, attempt 2 built and ran
  all three tests on iPhone 16 successfully. The final gate also linked a
  generic arm64 iOS-device test bundle with signing disabled.
- `mise` 2026.8.16 installed and locked Python 3.13.15, Meson 1.11.2, Ninja
  1.13.2, jq 1.8.2, ShellCheck 0.11.0, and actionlint 1.7.12. `mise run doctor`
  and `mise run lint` pass.
- Thirty adversarial discovery tests pass, and the canonical FFmpeg download
  page identifies signed stable release 9.0.1 (2026-08-12) as the one update
  over the configured 9.0 baseline.
- Release-asset generation is byte-reproducible across two runs and produces
  exactly six explicit assets. The 69-entry corresponding-source/relink kit,
  SPDX 2.3 SBOM, metrics, release manifest, and checksums all pass structural,
  inventory, timestamp, mode, digest, and path-traversal validation.
