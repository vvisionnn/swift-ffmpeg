# swift-ffmpeg

`swift-ffmpeg` packages a reproducible, security-reviewed FFmpeg XCFramework
for Swift projects on iOS, iPadOS, and macOS. It intentionally exposes FFmpeg's
C module without prescribing a player, editor, or media-processing API.

## Supported platforms

| Platform | Architectures | Minimum version |
| --- | --- | --- |
| iOS / iPadOS | arm64 | 15 |
| iOS Simulator | arm64, x86_64 | 15 |
| macOS | arm64, x86_64 | 12 |

SwiftPM binary targets are Apple-platform binaries. This repository does not
claim Linux, Windows, tvOS, watchOS, or visionOS support.

## Add the package

Pin the exact release qualified by your application:

```swift
dependencies: [
    .package(
        url: "https://github.com/vvisionnn/swift-ffmpeg.git",
        exact: "1.0.0"
    ),
],
targets: [
    .target(
        name: "YourTarget",
        dependencies: [
            .product(name: "FFmpeg", package: "swift-ffmpeg"),
        ]
    ),
]
```

Then import the C module directly:

```swift
import FFmpeg

let version = String(cString: av_version_info())
```

The `FFmpeg` product carries its Apple framework/system-library link settings
and privacy manifest. Release `1.0.0` contains FFmpeg 9.0 with dav1d 1.5.4.

Maintainer validation may set `SWIFT_FFMPEG_USE_LOCAL_XCFRAMEWORK=1` to use the
ignored `Artifacts/FFmpeg.xcframework` path before a release is published.
Normal consumers should leave that variable unset and use the checksum-pinned
remote artifact.

## Build policy

The release build is intentionally narrow: static/PIC FFmpeg with decoding,
demuxing, network input, SecureTransport, VideoToolbox, AudioToolbox, and dav1d
enabled; encoders, `avfilter`, `avdevice`, programs, documentation, and every
muxer except `spdif` are disabled. GPL, version-3-only, and nonfree options are
rejected.

The build also applies reviewed patches that bound default video pixels and
audio samples and remove FFmpeg's use of private `_SecIdentityCreate`.
Patch drift, a capability regression, invalid Mach-O metadata, differing slice
headers, or a non-reproducible artifact blocks publication.

## Development

Install [mise](https://mise.jdx.dev/), then use the same tasks as CI:

```sh
mise install
mise run doctor
mise run check
```

The daily updater checks FFmpeg's canonical signed release first and performs
an expensive macOS build only when a new stable version exists. See
[CONTRIBUTING.md](CONTRIBUTING.md) for the release invariants and focused
commands.

## Licensing and redistribution

Repository-authored manifests, scripts, tests, and documentation use the MIT
license. The built FFmpeg libraries use LGPL 2.1-or-later; dav1d uses BSD
2-Clause; FFmpeg also contains Independent JPEG Group code. Static linking can
create source, notice, reverse-engineering, object-file, and relinking duties
for an application distributor. Every release includes exact corresponding
source and relinking materials, but those do not satisfy obligations for a
separate application. Read [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and
the relinking guide before distributing. This is not legal advice.
