# Local dependency cache

Managed local reloads automatically reuse an available immutable SwiftPM seed at the profile-provided `CMUX_SOURCE_PACKAGES_DIR`. The cache preflight never contacts a cache server or waits for another process to download a seed. Existing populated dependency directories are preserved. A miss continues through normal dependency setup, which may fetch missing dependencies.

To populate shared seeds explicitly, run from the repository when downloading is convenient:

```sh
python3 scripts/local-build-cache-preflight.py --warm --receipt /tmp/cmux-cache-warm.json
```

Warming fetches compressed SwiftPM archives (`.tar.zst`, or `.tar.gz`), and the existing checksum-pinned compressed GhosttyKit distribution. There is no uncompressed archive fallback. An available local exact or same-platform prefix SwiftPM seed is reused without another download. The compressed transport file is discarded after successful seed publication. Warming does not create a consumer SourcePackages directory or install a workspace GhosttyKit link.

The default shared cache is `~/Projects/.cmux-build-cache`; `--cache-root` overrides it. `--timeout` sets the total preparation budget in seconds (default 120, maximum 600). A transfer is additionally capped at 90 seconds. Download, extraction, copy and seed preparation failures are recorded as misses in the JSON receipt. A miss does not block the normal build. Receipts identify the mode, requested and matched SwiftPM keys, local reuse versus remote transport, and failure reasons.

Normal SwiftPM resolution still validates the current lockfile. SwiftPM consumers receive private writable copies (APFS clones where supported), with stale workspace metadata removed. GhosttyKit seeds are checksum verified and their macOS archives indexed with the selected toolchain before readonly publication. Custom, dirty or differently configured Ghostty builds keep normal setup behavior. Compiler caches and whole-app build products are not restored.

The automated tests exercise compressed loopback transfers, network-free reuse, held download locks, private-copy isolation, invalid archives and hard deadlines. These tests establish cache behavior, not a measured full-build speedup or application runtime correctness.
