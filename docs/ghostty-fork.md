# Ghostty Fork Changes (manaflow-ai/ghostty)

This repo uses a fork of Ghostty for local patches that aren't upstream yet.
When we change the fork, update this document and the parent submodule SHA.

## Fork update checklist

1) Make changes in `ghostty/`.
2) Commit and push to `manaflow-ai/ghostty`.
3) Update this file with the new change summary + conflict notes.
4) In the parent repo: `git add ghostty` and commit the submodule SHA.

## Current fork changes

Fork rebased onto upstream `v1.3.0` plus newer `main` commits as of March 12, 2026.

### 1) OSC 99 (kitty) notification parser

- Commit: `a2252e7a9` (Add OSC 99 notification parser)
- Files:
  - `src/terminal/osc.zig`
  - `src/terminal/osc/parsers.zig`
  - `src/terminal/osc/parsers/kitty_notification.zig`
- Summary:
  - Adds a parser for kitty OSC 99 notifications and wires it into the OSC dispatcher.

### 2) macOS display link restart on display changes

- Commit: `c07e6c5a5` (macos: restart display link after display ID change)
- Files:
  - `src/renderer/generic.zig`
- Summary:
  - Restarts the CVDisplayLink when `setMacOSDisplayID` updates the current CGDisplay.
  - Prevents a rare state where vsync is "running" but no callbacks arrive, which can look like a frozen surface until focus/occlusion changes.

### 3) Keyboard copy mode selection C API

- Commit: `a50579bd5` (Add C API for keyboard copy mode selection)
- Files:
  - `src/Surface.zig`
  - `src/apprt/embedded.zig`
- Summary:
  - Restores `ghostty_surface_select_cursor_cell` and `ghostty_surface_clear_selection`.
  - Keeps cmux keyboard copy mode working against the refreshed Ghostty base.

### 4) macOS resize stale-frame mitigation

Sections 3 and 4 are grouped by feature, not by commit order. The section 4 resize commits were
applied earlier than the section 3 copy-mode commit, but they are kept together here because they
touch the same stale-frame mitigation path and tend to conflict in the same files during rebases.

- Commits:
  - `769bbf7a9` (macos: reduce transient blank/scaled frames during resize)
  - `9efcdfdf8` (macos: keep top-left gravity for stale-frame replay)
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

### 5) zsh prompt redraw markers use OSC 133 P

- Commit: `8ade43ce5` (zsh: use OSC 133 P for prompt redraws)
- Files:
  - `src/shell-integration/zsh/ghostty-integration`
- Summary:
  - Emits one `OSC 133;A` fresh-prompt mark for real prompt transitions.
  - Uses `OSC 133;P` markers for prompt redraws so async zsh themes do not look like extra prompt lines.

### 6) zsh Pure-style multiline prompt redraws

- Commits:
  - `0cf559581` (zsh: fix Pure-style multiline prompt redraws)
  - `312c7b23a` (zsh: avoid extra Pure continuation markers)
  - `404a3f175` (Fix Pure prompt redraw markers)
- Files:
  - `src/shell-integration/zsh/ghostty-integration`
- Summary:
  - Handles multiline prompts that use `\n%{\r%}` to return to column 0 before the visible prompt line.
  - Keeps redraw-safe prompt-start markers for async themes.
  - Avoids inserting an explicit continuation marker after Pure's hidden carriage return, because Ghostty already tracks the newline as prompt continuation and the extra marker duplicates the preprompt row.
  - Restores that prompt-marker behavior on top of the current Ghostty `main` base after the older redraw fix drifted out during later submodule updates.

The fork branch HEAD is now the section 6 zsh redraw follow-up commit.

### 7) cmux theme picker helper hooks

- Commit: `0c52c987b` (Add cmux theme picker helper hooks)
- Files:
  - `build.zig`
  - `src/cli/list_themes.zig`
  - `src/main_ghostty.zig`
- Summary:
  - Adds a `zig build cli-helper` step so cmux can bundle Ghostty's CLI helper binary on macOS.
  - Lets `+list-themes` switch into a cmux-managed mode via env vars, writing the cmux theme override file and posting the existing cmux reload notification for live app-wide preview.
  - Fixes the helper-only `app-runtime=none` stdout path so the Ghostty CLI binary builds with the current Zig toolchain.

The fork branch HEAD is now the section 7 cmux theme picker helper commit.

### 8) macos-background-from-layer config flag

- Branch: `feat-layer-bg`
- Files:
  - `src/config/Config.zig`
  - `src/renderer/generic.zig`
- Summary:
  - Adds a `macos-background-from-layer` bool config (default false).
  - When true, sets `bg_color[3] = 0` in the per-frame uniform update so the Metal renderer skips the full-screen background fill.
  - Allows the host app to provide the terminal background via `CALayer.backgroundColor` for instant coverage during view resizes, avoiding alpha double-stacking.

### 9) Initial focus seeding and DECSET 1004 startup behavior

- Status: working tree change (not yet committed)
- Files:
  - `include/ghostty.h`
  - `macos/Sources/Ghostty/Surface View/SurfaceView.swift`
  - `src/Surface.zig`
  - `src/apprt/embedded.zig`
  - `src/termio/stream_handler.zig`
- Summary:
  - Adds an explicit initial `focused` flag to surface creation so host apps can start background panes unfocused.
  - Seeds renderer and termio focus bookkeeping from that initial state before the IO thread starts.
  - Keeps DECSET 1004 enablement side-effect free so focus sequences are emitted only on subsequent real focus transitions, preventing `CSI I/O` from leaking into shells during pane creation.

## Upstreamed fork changes

### cursor-click-to-move respects OSC 133 click-to-move

- Was local in the fork as `10a585754`.
- Landed upstream as `bb646926f`, so it is no longer carried as a fork-only patch.

## Merge conflict notes

These files change frequently upstream; be careful when rebasing the fork:

- `src/terminal/osc/parsers.zig`
  - Upstream uses `std.testing.refAllDecls(@This())` in `test {}`.
  - Ensure `iterm2` import stays, and keep `kitty_notification` import added by us.

- `src/terminal/osc.zig`
  - OSC dispatch logic moves often. Re-check the integration points for the OSC 99 parser.

- `src/shell-integration/zsh/ghostty-integration`
  - Prompt marker handling is easy to regress when upstream adjusts zsh redraw behavior. Keep the
    `OSC 133;A` vs `OSC 133;P` split intact for redraw-heavy themes. Pure-style `\n%{\r%}`
    prompt newlines should not get an extra explicit continuation marker after the hidden CR.

- `src/cli/list_themes.zig`
  - cmux now relies on the upstream picker UI plus local env-driven hooks for live preview and restore.
    If upstream reorganizes the preview loop or key handling, re-check the cmux mode path and keep the
    stock Ghostty behavior unchanged when the cmux env vars are absent.

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

If you resolve a conflict, update this doc with what changed.
