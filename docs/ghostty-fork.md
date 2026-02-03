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

### 2) Manual termio backend + embedded IO mode (cmuxd support)

- Commit: `8851d16a6` (manual backend + embedded IO mode + C API hook)
- Files:
  - `src/termio/Manual.zig`
  - `src/termio/backend.zig`
  - `src/termio.zig`
  - `src/Surface.zig`
  - `src/apprt/embedded.zig`
  - `src/cmuxd.zig`
  - `include/ghostty.h`
- Summary:
  - Adds a manual termio backend for driving the terminal with externally-fed output.
  - Adds embedded `io_mode` to select between pty and manual backends.
  - Adds `ghostty_surface_process_output` C API for feeding output into surfaces.
  - Adds a small `cmuxd.zig` re-export entrypoint for terminal+pty use in cmuxd.

## Merge conflict notes

These files change frequently upstream; be careful when rebasing the fork:

- `src/terminal/osc/parsers.zig`
  - Upstream uses `std.testing.refAllDecls(@This())` in `test {}`.
  - Ensure `iterm2` import stays, and keep `kitty_notification` import added by us.

- `src/terminal/osc.zig`
  - OSC dispatch logic moves often. Re-check the integration points for the OSC 99 parser.

- `src/termio/backend.zig`
  - Backend enum/dispatch changes often; ensure manual backend wiring is preserved.

- `src/apprt/embedded.zig`
  - Embedded config surface changes often; re-check `io_mode` additions.

If you resolve a conflict, update this doc with what changed.
