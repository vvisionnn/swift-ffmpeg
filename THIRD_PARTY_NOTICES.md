# swift-ffmpeg third-party notices

These notices cover the linked code in the FFmpeg XCFramework identified by
the checked-out tag's
[`Configuration/release.json`](Configuration/release.json). Every GitHub
Release also carries the exact source archive, detached signature, patches,
configuration, checksums, license texts, and relinking instructions for that
binary. An application distributor remains responsible for reviewing its
complete application and distribution method. This is not legal advice.

## FFmpeg

- Project: <https://ffmpeg.org/>
- License in this build: GNU Lesser General Public License 2.1 or later
- Exact version, canonical source URL, signature URL, and SHA-256:
  [`Configuration/release.json`](Configuration/release.json)
- License: [Licenses/FFmpeg-LGPL-2.1.txt](Licenses/FFmpeg-LGPL-2.1.txt)
- Relinking guide: [Licenses/FFmpeg-Static-Relinking.md](Licenses/FFmpeg-Static-Relinking.md)

GPL, version-3-only, and nonfree configuration flags are disabled. The build
applies two published patches: bounded decoder defaults
(`max_pixels=8847360`, `max_samples=262144`) and removal of the
SecureTransport client-certificate path that references Apple's private
`_SecIdentityCreate` API. x86 assembly is disabled because its NASM objects do
not contain the required Apple platform/minimum-OS load commands.

### Independent JPEG Group code

This software is based in part on the work of the Independent JPEG Group.

The FFmpeg archive includes `libavcodec/jfdctfst.c`,
`libavcodec/jfdctint_template.c`, and `libavcodec/jrevdct.c`. This package does
not change those files. Their terms are reproduced in
[Licenses/Independent-JPEG-Group.txt](Licenses/Independent-JPEG-Group.txt) and
remain available in the exact FFmpeg source archive.

## dav1d

- Project: <https://code.videolan.org/videolan/dav1d>
- License: BSD 2-Clause
- Exact version, canonical source URL, and SHA-256:
  [`Configuration/release.json`](Configuration/release.json)
- License: [Licenses/dav1d-BSD-2-Clause.txt](Licenses/dav1d-BSD-2-Clause.txt)

dav1d is statically included to provide software AV1 decoding.

## Patents

Open-source copyright licenses do not grant every patent right that may be
required for H.264, HEVC, AAC, AC-3, or other formats. Patent licensing remains
the application distributor's responsibility.

## Repository-authored code

The package manifest, scripts, tests, patches, and documentation are licensed
under [LICENSE](LICENSE). That MIT license does not replace the third-party
terms above.
