# Changelog

Hand-authored packaging and policy changes are documented here. Package
versions are independent from FFmpeg versions so packaging-only corrections
always receive a new immutable SemVer release. For every release, the exact
package version, upstream versions, sources, and artifact checksums are recorded
in `Configuration/release.json`, the release manifest, and the release notes.

## 1.0.0 — 2026-09-01

- Package the FFmpeg 9.0/dav1d 1.5.4 Apple XCFramework.
- Preserve iOS device, iOS Simulator, and universal macOS slices.
- Add deterministic build, validation, source/relink, and release automation.
