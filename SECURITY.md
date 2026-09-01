# Security policy

## Supported versions

Before `1.0.0` is published, security fixes are maintained on `main`. After
publication, the newest package release is supported; older binary releases
remain immutable and may be marked affected rather than replaced.

## Reporting a vulnerability

Use GitHub private vulnerability reporting. Include the affected FFmpeg or
packaging version, platform, impact, minimal reproduction, and any mitigation.
Do not put exploit details, credentials, private media, or sensitive logs in a
public issue. If private reporting is unavailable, open a public issue asking
the maintainers to establish a private contact path without disclosing details.

An issue wholly inside FFmpeg or dav1d should also be reported through that
upstream project's security process. Do not test systems or data you do not own
or have permission to test.

## Supply-chain model

Release source must pass canonical signature/fingerprint verification before
extraction. Untrusted upstream code builds in a read-only job. A separate
publication job validates fixed-name checksums and metadata without executing
or loading the produced binary, then creates an immutable release. Consumers
must retain SwiftPM's checksum and an exact package version.
