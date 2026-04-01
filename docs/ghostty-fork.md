# Ghostty Fork Changes (manaflow-ai/ghostty)

This repo uses a fork of Ghostty for local patches that aren't upstream yet.
When we change the fork, update this document and the parent submodule SHA.

## Fork update checklist

1) Make changes in `ghostty/`.
2) Commit and push to `manaflow-ai/ghostty`.
3) Update this file with the new change summary + conflict notes.
4) In the parent repo: `git add ghostty` and commit the submodule SHA.

## Current fork changes

Fork rebased onto upstream `main` at `3509ccf78` (`v1.3.1-457-g3509ccf78`) on March 30, 2026.
Current cmux fork head: `0b231db94` (`v1.3.1-472-g0b231db94`).

### 1) macOS display link restart on display changes

- Commit: `05cf31b38` (macos: restart display link after display ID change)
- Files:
  - `src/renderer/generic.zig`
- Summary:
  - Restarts the CVDisplayLink when `setMacOSDisplayID` updates the current CGDisplay.
  - Prevents a rare state where vsync is "running" but no callbacks arrive, which can look like a frozen surface until focus/occlusion changes.

### 2) macOS resize stale-frame mitigation

The resize commits are grouped by feature because they touch the same stale-frame replay path and
tend to conflict together during rebases.

- Commits:
  - `a3588ac53` (macos: reduce transient blank/scaled frames during resize)
  - `9ba54a68c` (macos: keep top-left gravity for stale-frame replay)
- Files:
  - `pkg/macos/animation.zig`
  - `src/Surface.zig`
  - `src/apprt/embedded.zig`
  - `src/renderer/Metal.zig`
  - `src/renderer/generic.zig`
  - `src/renderer/metal/IOSurfaceLayer.zig`
- Summary:
  - Replays the last rendered frame during resize and keeps its geometry anchored correctly.
  - Reduces transient blank or scaled frames while a macOS window is being resized.

### 3) OSC 99 (kitty) notification parser

- Commits:
  - `2033ffebc` (Add OSC 99 notification parser)
  - `a75615992` (Fix OSC 99 parser for upstream API changes)
- Files:
  - `src/terminal/osc.zig`
  - `src/terminal/osc/parsers.zig`
  - `src/terminal/osc/parsers/kitty_notification.zig`
- Summary:
  - Adds a parser for kitty OSC 99 notifications and wires it into the OSC dispatcher.
  - Adapts the parser to upstream's newer capture API so the cmux OSC 99 hook survives the March 30 upstream sync.

### 4) cmux theme picker helper hooks

- Commits:
  - `1da7281fd` (Add cmux theme picker helper hooks)
  - `ea482b73e` (Fix cmux theme picker preview writes)
  - `c7ab66056` (Improve cmux theme picker footer contrast)
  - `c49f69f7b` (Respect system theme in cmux picker)
  - `599b0ff43` (Skip theme detection in cmux picker)
  - `b75388d95` (Match Ghostty theme picker startup)
  - `f985d2d04` (Harden cmux theme override writes)
- Files:
  - `build.zig`
  - `src/cli/list_themes.zig`
  - `src/main_ghostty.zig`
- Summary:
  - Adds a `zig build cli-helper` step so cmux can bundle Ghostty's CLI helper binary on macOS.
  - Lets `+list-themes` switch into a cmux-managed mode via env vars, writing the cmux theme override file and posting the existing cmux reload notification for live app-wide preview.
  - Keeps the preview UI readable in light mode, matches upstream picker startup behavior, and hardens writes to the cmux-managed theme override file.

### 5) Color scheme mode 2031 reporting

- Commits:
  - `2be58ee0e` (Fix DECRPM mode 2031 reporting wrong color scheme)
  - `74709c29b` (Send initial color scheme report when mode 2031 is enabled)
- Files:
  - `src/Surface.zig`
  - `src/termio/stream_handler.zig`
- Summary:
  - Keeps Ghostty's mode 2031 color-scheme response aligned with the surface's actual conditional state after config reloads.
  - Sends the initial DSR 997 report as soon as mode 2031 is enabled, which cmux relies on for immediate color-scheme awareness.

### 6) Keyboard copy mode selection C API

- Commit: `0b231db94` (Re-export cmux selection APIs removed from upstream)
- Files:
  - `include/ghostty.h`
  - `src/Surface.zig`
  - `src/apprt/embedded.zig`
- Summary:
  - Restores `ghostty_surface_select_cursor_cell` and `ghostty_surface_clear_selection`.
  - Keeps cmux keyboard copy mode working against the refreshed Ghostty base after upstream removed those exports.

### 7) macos-background-from-layer config flag

- Commit: `ae3cc5d29` (Restore macOS layer background hook)
- Files:
  - `src/config/Config.zig`
  - `src/renderer/generic.zig`
- Summary:
  - Adds a `macos-background-from-layer` bool config (default false).
  - When true, sets `bg_color[3] = 0` in the per-frame uniform update so the Metal renderer skips the full-screen background fill.
  - Allows the host app to provide the terminal background via `CALayer.backgroundColor` for instant coverage during view resizes, avoiding alpha double-stacking.
  - Replays the layer-background restore on top of the refreshed Ghostty base so cmux keeps the resize-coverage fix after the upstream sync.

The fork branch HEAD is now the section 7 layer-background restore commit.

## Upstreamed fork changes

### cursor-click-to-move respects OSC 133 click-to-move

- Was local in the fork as `10a585754`.
- Landed upstream as `bb646926f`, so it is no longer carried as a fork-only patch.

### zsh prompt redraw follow-ups

- Were local in the fork as `8ade43ce5`, `0cf559581`, `312c7b23a`, and `404a3f175`.
- Dropped during the March 30, 2026 rebase because newer Ghostty prompt-marking changes on the refreshed base superseded these fork-only zsh redraw patches, so cmux no longer carries them separately.

## Merge conflict notes

These files change frequently upstream; be careful when rebasing the fork:

- `src/terminal/osc.zig`
  - OSC dispatch logic moves often. Re-check the integration points for the OSC 99 parser and keep
    the newer `capture`/`captureTrailing()` API usage intact.

- `src/terminal/osc/parsers.zig`
  - Ensure `kitty_notification` stays imported after upstream parser reorganizations.

- `src/cli/list_themes.zig`
  - cmux now relies on the upstream picker UI plus local env-driven hooks for live preview and restore.
    If upstream reorganizes the preview loop or key handling, re-check the cmux mode path and keep the
    stock Ghostty behavior unchanged when the cmux env vars are absent.

- `build.zig`
  - Upstream's new wasm/libghostty work touched the same build graph. Keep the cmux-only `cli-helper`
    step wired in without regressing the upstream `lib-vt` or wasm build paths.

- `include/ghostty.h`, `src/Surface.zig`, `src/apprt/embedded.zig`
  - Upstream removed cmux-used selection exports. Preserve the re-exported
    `ghostty_surface_select_cursor_cell` and `ghostty_surface_clear_selection` functions.

- `src/renderer/generic.zig`
  - The `macos-background-from-layer` check sits next to the glass-style check in `updateFrame`.
    If upstream refactors the bg_color uniform update or the glass conditional, re-check that both
    paths still zero out `bg_color[3]` correctly.

If you resolve a conflict, update this doc with what changed.
