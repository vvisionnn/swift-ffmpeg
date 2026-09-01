# Contributing to swift-ffmpeg

Keep this package focused on reproducible FFmpeg binaries. Playback APIs,
media policy, UI, application authentication, and player-specific C shims
belong in consuming applications and libraries.

## Setup and checks

Use macOS with the Xcode version declared by the repository and install the
pinned tools through mise:

```sh
mise install
mise run doctor
mise run check
```

Each mise task delegates to a directly runnable repository script so LGPL
relinking recipients are not required to use mise. Source downloads and build
outputs are ignored; do not commit tarballs, XCFrameworks, ZIPs, DerivedData,
or credentials.

## Changes

- Keep source URLs, signatures, SHA-256 values, versions, configure flags, and
  toolchain details machine-readable and reviewable.
- Never auto-refresh a signing key. A key rotation requires a reviewed commit.
- Treat every upstream archive and its build system as untrusted. Builds run
  without repository write permission; publication happens in a fresh job.
- Add adversarial tests for parser, manifest, patch, archive, or workflow logic.
- Keep release tags and assets immutable. Correct a bad release with a new
  package SemVer, never a moved tag or replacement asset.
- Update notices and exact source/relink materials whenever linked code changes.

Use focused Conventional Commits and run the smallest relevant task while
iterating. Before a pull request, run `mise run check`. Release changes also
require `mise run reproducibility` and a clean remote-consumer test.
