# cmux Chromium fork patches

Patches that must be applied to the upstream Chromium tree to make
content_shell / cmux_core_framework build on the cmux fork's hosts.
Each file documents the symptom, target, and rationale. When the fork
repo at `manaflow-ai/cmux-chromium` exists, these will be committed
directly to that tree and this directory will become an audit trail
of what changed and why.

Until the fork repo exists, the workflow is:
1. Patch lives here in cmuxterm-hq.
2. `scripts/chromium-build-host.sh` applies it to the build host's
   `~/chromium-fork/src/` checkout as part of `setup`.
3. When the fork repo lands, the patches get squashed into the
   fork's M148 base and this directory is deleted.

## Index

- `0001-angle-metal-wrapper-resolve-via-xcrun.patch` — fixes ANGLE
  Metal shader compilation under macOS 15 + Xcode 26, where the
  Xcode-shipped metal stub cannot locate the cryptex-mounted Metal
  Toolchain (only `xcrun` can).
