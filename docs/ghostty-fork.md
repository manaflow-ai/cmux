# Ghostty Fork Changes (manaflow-ai/ghostty)

This repo uses a fork of Ghostty for local patches that aren't upstream yet.
When we change the fork, update this document and the parent submodule SHA.

## Fork update checklist

1) Make changes in `ghostty/`.
2) Commit and push to `manaflow-ai/ghostty`.
3) Update this file with the new change summary + conflict notes.
4) In the parent repo: `git add ghostty` and commit the submodule SHA.

## Current fork changes

The fork was refreshed from upstream `main` again on April 28, 2026.
Current cmux pinned fork head: `04ec69173`, merged into fork `main` via
`manaflow-ai/ghostty` PR https://github.com/manaflow-ai/ghostty/pull/50
(`xcframework-d3117e03ea19665bc83a28f7e0428c63937e6140-8-g04ec69173`).
This head restores the cmux theme picker hooks on top of `d3117e03e`, which
merged upstream `659019666` and preserved the previous cmux pin `465a9a621`.

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
  - `66ff6ec4d` (Add cmux theme picker helper hooks)
  - `aa650937d` (Fix cmux theme picker preview writes)
  - `89d3612c9` (Improve cmux theme picker footer contrast)
  - `0dc979889` (Respect system theme in cmux picker)
  - `d9e0ab512` (Skip theme detection in cmux picker)
  - `042cbaaab` (Match Ghostty theme picker startup)
  - `eb34bcdd6` (Harden cmux theme override writes)
  - `04ec69173` (Apply highlighted cmux theme on Enter)
- Files:
  - `build.zig`
  - `src/cli/list_themes.zig`
  - `src/main_ghostty.zig`
- Summary:
  - Adds a `zig build cli-helper` step so cmux can bundle Ghostty's CLI helper binary on macOS.
  - Lets `+list-themes` switch into a cmux-managed mode via env vars, writing the cmux theme override file and posting the existing cmux reload notification for live app-wide preview.
  - Keeps the preview UI readable in light mode, matches upstream picker startup behavior, and hardens writes to the cmux-managed theme override file.
  - Restores Enter as the cmux apply action by writing the currently highlighted theme before the picker exits.

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

- Commits:
  - `ae3cc5d29` (Restore macOS layer background hook)
  - `aa28e1bcb` (Add macos-background-from-layer config flag)
  - `1a01b36d9` (Skip fullscreen bg draw call in layer-background mode)
  - `82e20630b` (Preserve bg images in layer background mode)
  - `465a9a621` (Restore bg-image alpha in layer background mode)
- Files:
  - `src/config/Config.zig`
  - `src/renderer/generic.zig`
- Summary:
  - Adds a `macos-background-from-layer` bool config (default false).
  - When true, sets `bg_color[3] = 0` in the per-frame uniform update so the Metal renderer skips the full-screen background fill.
  - Allows the host app to provide the terminal background via `CALayer.backgroundColor` for instant coverage during view resizes, avoiding alpha double-stacking.
  - Replays the layer-background restore on top of the refreshed Ghostty base so cmux keeps the resize-coverage fix after the upstream sync.

### 8) TerminalStream kitty graphics APC handling

- Commit: `a8e92c9c5` (terminal: add APC handler to stream_terminal)
- Files:
  - `src/terminal/stream_terminal.zig`
- Summary:
  - Wires `.apc_start`, `.apc_put`, and `.apc_end` through the shared APC parser in `TerminalStream`.
  - Restores kitty graphics execution and APC OK/error replies for the non-termio stream path used by cmux/libghostty integrations.

### 9) Config load string C API

- Commit: `f7880c473` (Add config load string C API)
- Files:
  - `include/ghostty.h`
  - `src/config/CApi.zig`
  - `src/config/Config.zig`
- Summary:
  - Adds a C API for loading Ghostty config from an in-memory string.
  - Lets cmux parse generated or override config without materializing a separate config file first.

The current cmux pin is the head listed above. It is reachable from the
`manaflow-ai/ghostty` fork `main` branch and has a matching prebuilt release
tag `xcframework-04ec69173f8f5ac5a2568afca0faf8e4a74b2dc2`.

## Upstreamed fork changes

### cursor-click-to-move respects OSC 133 click-to-move

- Was local in the fork as `10a585754`.
- Landed upstream as `bb646926f`, so it is no longer carried as a fork-only patch.

### zsh prompt redraw follow-ups

- Were local in the fork as `8ade43ce5`, `0cf559581`, `312c7b23a`, and `404a3f175`.
- Dropped during the March 30, 2026 rebase because newer Ghostty prompt-marking changes on the refreshed base superseded these fork-only zsh redraw patches, so cmux no longer carries them separately.

### initial focus seeding and DECSET 1004 startup behavior

- Was local in the fork as `c19c82bfd`.
- Dropped from the current pinned fork head when cmux removed the corresponding
  app-side initial focus seed and went back to post-create focus sync.

## Merge conflict notes

These files change frequently upstream; be careful when rebasing the fork:

- April 28, 2026, upstream merge:
  - Merged upstream `659019666` into `465a9a621` without textual conflicts.
  - Verified with `CMUX_GHOSTTYKIT_NO_PREBUILT=1 ./scripts/ensure-ghosttykit.sh`.
  - Verified cmux with `./scripts/reload.sh --tag gtyup`.
  - Published `xcframework-d3117e03ea19665bc83a28f7e0428c63937e6140` and pinned
    its archive checksum in `scripts/ghosttykit-checksums.txt`.
  - Merged `d3117e03e` into fork `main` with https://github.com/manaflow-ai/ghostty/pull/48.
  - Package GhosttyKit archives with `COPYFILE_DISABLE=1`; the archive validator rejects
    macOS AppleDouble entries such as `._GhosttyKit.xcframework`.

- April 28, 2026, theme picker restore:
  - Reapplied the section 4 cmux picker hooks on top of `d3117e03e`.
  - Enter in cmux mode must call the same selection-apply path used by keyboard/mouse navigation
    before setting the picker outcome to apply.
  - Verified with `zig build cli-helper -Dapp-runtime=none -Demit-macos-app=false -Demit-xcframework=false -Doptimize=ReleaseFast`.
  - Verified Enter writes `theme = light:0x96f,dark:0x96f` in a PTY temp-config run.
  - Published `xcframework-04ec69173f8f5ac5a2568afca0faf8e4a74b2dc2` and pinned
    its archive checksum in `scripts/ghosttykit-checksums.txt`.

- `src/terminal/osc.zig`
  - OSC dispatch logic moves often. Re-check the integration points for the OSC 99 parser and keep
    the newer `capture`/`captureTrailing()` API usage intact.

- `src/terminal/osc/parsers.zig`
  - Ensure `kitty_notification` stays imported after upstream parser reorganizations.

- `src/cli/list_themes.zig`
  - cmux now relies on the upstream picker UI plus local env-driven hooks for live preview and restore.
    If upstream reorganizes the preview loop or key handling, re-check the cmux mode path and keep the
    stock Ghostty behavior unchanged when the cmux env vars are absent.
  - The April 28, 2026 restore requires Enter in cmux mode to call the same selection-apply path
    used by keyboard/mouse navigation before setting the picker outcome to apply.

- `build.zig`
  - Upstream's new wasm/libghostty work touched the same build graph. Keep the cmux-only `cli-helper`
    step wired in without regressing the upstream `lib-vt` or wasm build paths.

- `src/main_ghostty.zig`
  - The April 28, 2026 restore only conflicted on stdout writer API usage. Keep the current
    `std.fs.File.stdout().writer(&buf)` API plus explicit flush.

- `include/ghostty.h`, `src/Surface.zig`, `src/apprt/embedded.zig`
  - Upstream removed cmux-used selection exports. Preserve the re-exported
    `ghostty_surface_select_cursor_cell` and `ghostty_surface_clear_selection` functions.

- `src/renderer/generic.zig`
  - The `macos-background-from-layer` check sits next to the glass-style check in `updateFrame`.
    If upstream refactors the bg_color uniform update or the glass conditional, re-check that both
    paths still zero out `bg_color[3]` correctly.

- `src/Surface.zig`, `src/apprt/embedded.zig`, `macos/Sources/Ghostty/Surface View/SurfaceView.swift`
  - The initial `focused` plumbing has to stay aligned across the C config, embedded runtime surface,
    and macOS wrapper. If upstream refactors surface creation or post-create focus sync, re-check that
    background panes can start unfocused without synthesizing a focus-loss transition during creation.

- `src/termio/stream_handler.zig`
  - Keep DECSET 1004 enablement side-effect free. xterm-compatible focus reporting should only emit
    `CSI I` / `CSI O` on actual focus transitions, not immediately when the mode is enabled.

- `src/terminal/stream_terminal.zig`
  - Keep the APC handler wired into `.apc_start`, `.apc_put`, `.apc_end`, and preserve the
    `apcEnd()` response path so kitty graphics still reach `Terminal.kittyGraphics()` and reply via
    `write_pty`.

If you resolve a conflict, update this doc with what changed.
