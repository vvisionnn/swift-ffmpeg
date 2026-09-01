# FFmpeg source and static-relinking guide

The released `FFmpeg.xcframework` is a static FFmpeg build under GNU LGPL 2.1
or later and includes dav1d under BSD 2-Clause. This guide describes the
materials supplied by `swift-ffmpeg` and what a downstream application
distributor must still preserve. It is not legal advice.

## Materials in every release

- exact FFmpeg source archive and detached upstream signature;
- exact dav1d source archive;
- SHA-256 checksums for every source and produced asset;
- complete patch series, build scripts, configuration, and toolchain manifest;
- LGPL 2.1, dav1d BSD, and Independent JPEG Group terms/notices; and
- the exact static `FFmpeg.xcframework` consumed by SwiftPM.

The build verifies pristine sources before extraction, applies the published
patches, builds five thin slices, validates each Mach-O member, merges three
XCFramework variants, and proves deterministic release packaging. To exercise
the right to modify FFmpeg, unpack the corresponding source kit, change the
source or patches, and run the documented build. Replace the released binary
with the resulting XCFramework when rebuilding the consuming Swift package.

## Downstream static-linking obligations

Providing this repository and its release kit does not itself discharge duties
created when another application statically links this library. A downstream
distributor should review LGPL 2.1 section 6 and, at minimum:

1. Preserve copyright notices, the LGPL text, corresponding-source
   availability, and the recipient's permitted modification/reverse-engineering
   rights for debugging those modifications.
2. Supply the complete corresponding FFmpeg/dav1d source and local build
   transformations, or another source-delivery method permitted by the license.
3. Retain and provide application object files or another permitted form that
   lets a recipient relink the application against a modified FFmpeg library,
   together with link ordering, flags, non-system static libraries, and relevant
   build settings.
4. Ensure the application's distribution terms do not prohibit modification or
   reverse engineering that the LGPL permits for this purpose.

Application object files and final link commands are application-specific, so
this binary package cannot supply them for a downstream distributor.
