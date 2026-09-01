# swift-ffmpeg third-party notices

These notices cover the linked code in the `1.0.0` FFmpeg XCFramework. Every
GitHub Release also carries the exact source archive, detached signature,
patches, configuration, checksums, license texts, and relinking instructions
for that binary. An application distributor remains responsible for reviewing
its complete application and distribution method. This is not legal advice.

## FFmpeg 9.0

- Project: <https://ffmpeg.org/>
- License in this build: GNU Lesser General Public License 2.1 or later
- Canonical source: <https://ffmpeg.org/releases/ffmpeg-9.0.tar.xz>
- Source SHA-256: `7f607a00dd0d28a729d5a4811205812eef01cf6ef6155025febb6f36a9062d52`
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

## dav1d 1.5.4

- Project: <https://code.videolan.org/videolan/dav1d>
- License: BSD 2-Clause
- Canonical source: <https://code.videolan.org/videolan/dav1d/-/archive/1.5.4/dav1d-1.5.4.tar.bz2>
- Source SHA-256: `2abfb0c89212e6e4733a54e0ae509ec00a5b845a6360946f918806e14aedb011`
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
