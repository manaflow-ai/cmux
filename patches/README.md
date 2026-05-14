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
- `0002-webnn-coreml-handle-new-mlmultiarraydatatype.patch` — adds a
  default branch to `GetDataTypeByteSize` so the macOS 26.2 SDK's
  new `MLMultiArrayDataType` values (Int8, UInt8, …) don't trip
  `-Werror,-Wswitch`. Drop when upstream lands the proper fix.
- `0003-ax-inspect-mac-suppress-new-availability.patch` — locally
  suppresses `-Wunguarded-availability-new` in `IsValidAXAttribute`
  so the macOS 26-introduced `NSAccessibility*` attribute constants
  don't break the build when chromium's deployment target is 11.0.
- `0004-ax-platform-node-cocoa-suppress-new-availability.patch` —
  file-level suppression of the same diagnostic in
  `ax_platform_node_cocoa.mm`, where ~6 spread-out usages would
  require many per-function pragma pairs.

## Strategic note for next session

These availability-suppression patches (0003, 0004) and the SDK
forward-compat patches (0001 metal, 0002 webnn) are accumulating
because the current checkout is at Chromium **main HEAD** (commit
`72a51d14d794ce9211145ecc9b7464e222d40153`, a ChromeOS LKGM from
2026-04-16) rather than the **M148 stable branch** the build host
script targets (`refs/branch-heads/7204`).

The handoff plan was to repoint to `7204` once the fork repo lands.
Doing it sooner — even before the fork repo exists — would likely
eliminate most of the SDK-forward-compat noise because M148 stable
was tested against earlier SDKs. The cost is one git checkout + a
`gclient sync` (hours, but cached). The benefit is fewer patches to
maintain. Worth investigating at the start of session 3 as an
alternative to chasing every new failure.
