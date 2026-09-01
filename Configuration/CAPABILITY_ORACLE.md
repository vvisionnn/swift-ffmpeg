# FFmpeg capability oracle

`capabilities.json` is a reviewed API and linker-registration oracle, not an
automatically updated build artifact. The release gate fails on both removed
and added capabilities so an upstream FFmpeg change cannot silently alter the
binary package's surface.

The runtime section comes from FFmpeg's public iteration APIs on the native
macOS slice. The registration section is extracted from every thin archive;
the gate also links a C reporter against all five shipped platform/architecture
combinations. This provides runtime truth where execution is possible and
compile/link plus exact-registration coverage everywhere else.

Run the gate with:

```sh
./Scripts/test-capabilities.sh
```

When intentionally updating FFmpeg, create a candidate outside the repository:

```sh
python3 -I -B Scripts/check-capabilities.py --emit-manifest \
  > /tmp/swift-ffmpeg-capabilities.json
diff -u Configuration/capabilities.json \
  /tmp/swift-ffmpeg-capabilities.json
```

Review every addition and removal, confirm the expected upstream release in
`generatedFrom`, and only then replace `Configuration/capabilities.json` in a
normal reviewed commit. Release automation must run the checking mode and must
never invoke `--emit-manifest` to approve its own output.
