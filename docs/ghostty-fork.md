# Ghostty Fork Changes (manaflow-ai/ghostty)

This repo uses a fork of Ghostty for local patches that aren't upstream yet.
When we change the fork, update this document and the parent submodule SHA.

## Fork update checklist

1) Make changes in `ghostty/`.
2) Commit and push to `manaflow-ai/ghostty`.
3) Update this file with the new change summary + conflict notes.
4) In the parent repo: `git add ghostty` and commit the submodule SHA.

## Current fork changes

### 1) OSC 99 (kitty) notification parser

- Commit: `4713b7e23` (Add OSC 99 notification parser)
- Files:
  - `src/terminal/osc.zig`
  - `src/terminal/osc/parsers.zig`
  - `src/terminal/osc/parsers/kitty_notification.zig`
- Summary:
  - Adds a parser for kitty OSC 99 notifications and wires it into the OSC dispatcher.

### 2) macOS display link restart on display changes

- Commit: `7c2562cbe` (macos: restart display link after display ID change)
- Files:
  - `src/renderer/generic.zig`
- Summary:
  - Restarts the CVDisplayLink when `setMacOSDisplayID` updates the current CGDisplay.
  - Prevents a rare state where vsync is "running" but no callbacks arrive, which can look like a frozen surface until focus/occlusion changes.

### 3) OSC 777 survives malformed UTF-8 boundaries

- Commits:
  - `1f8f10f06` (test(terminal): cover OSC 777 chunked stream parsing)
  - `8c1f9112f` (fix(terminal): preserve OSC parsing after malformed UTF-8)
- Files:
  - `src/terminal/stream.zig`
- Summary:
  - Adds regression coverage for OSC 777 desktop notifications across chunk splits and malformed UTF-8 boundaries.
  - Fixes the SIMD-to-scalar fallback so an `ESC` byte surfaced during UTF-8 error recovery switches back to control-sequence parsing instead of printing the rest of the OSC payload as raw text.

## Merge conflict notes

These files change frequently upstream; be careful when rebasing the fork:

- `src/terminal/osc/parsers.zig`
  - Upstream uses `std.testing.refAllDecls(@This())` in `test {}`.
  - Ensure `iterm2` import stays, and keep `kitty_notification` import added by us.

- `src/terminal/osc.zig`
  - OSC dispatch logic moves often. Re-check the integration points for the OSC 99 parser.

- `src/terminal/stream.zig`
  - The SIMD/scalar handoff is performance-sensitive. Re-check chunk-boundary handling when rebasing stream parser changes.

If you resolve a conflict, update this doc with what changed.
