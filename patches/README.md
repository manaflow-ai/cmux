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
- `0005-ax-cocoa-rename-private-symbol-backports.patch` — renames
  anonymous-namespace `NSAccessibilityUIElementsForSearchPredicateParameterizedAttribute`
  and `NSAccessibilityScrollToVisibleAction` in
  `browser_accessibility_cocoa.mm` to `CmuxNS…` prefixes. The macOS
  26.2 SDK now publishes the same identifiers (@available(macos 26.0)),
  causing a hard *ambiguous reference* compile error that a diagnostic
  pragma cannot silence. Rename preserves the string-literal values
  and behavior; older deployment targets still work.

## Note on Chromium base

The earlier README revision claimed the checkout was at Chromium main
HEAD rather than M148 stable, and that switching to `refs/branch-heads/7204`
would likely eliminate the SDK forward-compat noise. **That claim was
wrong**: `git ls-remote origin refs/branch-heads/7204` resolves to the
same commit (`72a51d14d794ce9211145ecc9b7464e222d40153`) that the
checkout is already on. The HEAD-shaped output of
`git log --oneline -1` shows `LKGM 16295.95.0 for chromeos.` because
that LKGM happens to be the tip of `branch-heads/7204` at the time it
was cut. So M148-stable and "the LKGM the checkout is on" are
literally the same commit, and there is no cheaper base to switch to.
The five patches in this directory are needed against M148 stable as
shipped today.
