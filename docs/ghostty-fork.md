# Ghostty Fork Changes (manaflow-ai/ghostty)

This repo uses a fork of Ghostty for local patches that aren't upstream yet.
When we change the fork, update this document and the parent submodule SHA.

## Fork update checklist

1) Make changes in `ghostty/`.
2) Commit and push to `manaflow-ai/ghostty`.
3) Update this file with the new change summary + conflict notes.
4) In the parent repo: `git add ghostty` and commit the submodule SHA.

## Current fork changes

Current cmux pinned fork head: `cc31d54ee`, a merge of upstream
`ghostty-org/ghostty` `main` (`d560c645`, 2026-07-03, ~271 first-parent
commits) onto the previous pin `541e5e89d`. Published via
manaflow-ai/ghostty#93.

### Upstream TLDR (`541e5e89d..d560c645`)

- Terminal: click/drag selection extracted into a `SelectionGesture` API with a
  new `selection_changed` notification (`GHOSTTY_ACTION_SELECTION_CHANGED`
  enum value added, additively); `click_events=2` support; OSC 7/9/1337
  `pwd_changed` callback; glyph-protocol glossary; configurable default cursor
  style/blink in libghostty-vt; prompt preservation on resize by default.
- Correctness: fixes for `Surface.setSelection` use-after-free, resize/scrollback
  wrap-count overflow, `resizeCols` cursor saturation, and utf-8 grapheme length
  overflow.
- macOS/platform: tab-bar appearance sync, macOS 27 beta tab-frame fix,
  notification retain-cycle fix, kitty-graphics generation stamps; plus routine
  i18n/colorscheme/dependency churn.

### Conflict notes (`src/Surface.zig`, resolved in the merge)

1. `mouseButtonCallback` link-click handling. Upstream refactored the
   left-release block to hold the renderer lock for the whole block and to pass
   a cached `release_pos` plus a `selection_gesture.left_click_dragged` guard.
   Resolution keeps the fork's latched ctrl/super link-click semantics
   (`link_click_active` / `link_press_over_link` / `armed_off_link`,
   manaflow-ai/cmux#5128), drops the fork's now-double-locking
   `renderer_state.mutex.lock()` (it would deadlock against the lock taken at
   the top of the block), reuses upstream's `release_pos`, and AND-s in
   upstream's `!left_click_dragged` guard.
2. Selection tests. Upstream removed the `mouseSelection` helper in favor of the
   new `SelectionGesture` API, so the fork's `testMouseSelection`-based
   `"Surface: selection logic"` / `"Surface: rectangle selection logic"` tests
   referenced deleted code. Those two tests were dropped; the fork-only
   `"Surface: mouseLinkRefreshAllowedState honors ctrl/super under mouse
   reporting"` test was kept (its target fn still exists).

Verified: `CMUX_GHOSTTYKIT_NO_PREBUILT=1 ./scripts/ensure-ghosttykit.sh` built
GhosttyKit cleanly from the merge; cmux's ghostty C ABI surface (51 called
`ghostty_*` functions) is unchanged in `include/ghostty.h` across the range
(only the additive `GHOSTTY_ACTION_SELECTION_CHANGED` enum value); tagged cmux
reload `gtyup`. Prebuilt archive:
https://github.com/manaflow-ai/ghostty/releases/tag/xcframework-cc31d54eef285de2f73b17a2aeafc24904722131-crashsubdir-cmux-crash-v1

### Previous pin

Previous cmux pinned fork head: `541e5e89d`, which merges the render-grid span
preservation head `1b454eb99` from manaflow-ai/ghostty#89 with the
Arabic/Hebrew RTL shaping head `7a5179843` from manaflow-ai/ghostty#88.

The render-grid change keeps wide or grapheme-backed cells in their own
`cmux.render-grid.v1` spans so mobile replay receives the producer's exact
start column and `cell_width` instead of inferring per-grapheme columns from an
aggregate same-style span.

The RTL series is based on ghostty-org/ghostty#11079 and adds the `itijah` bidi
resolver, extends the shared `uucode` tables with bidi fields, resolves visual
shaping runs per row, sets RTL shaping direction for CoreText/HarfBuzz, and
anchors Arabic combining marks/tashkeel to the correct base cluster. The
cmux-only follow-up commit adapts the new shaper tests to this pinned fork's
`vtStream().nextSlice` void-returning API. The RTL series was validated locally
with:

```bash
cd ghostty
zig build test -Dapp-runtime=none -Demit-macos-app=false -Demit-xcframework=false -Dtest-filter=arabic
zig build test -Dapp-runtime=none -Demit-macos-app=false -Demit-xcframework=false -Dtest-filter=hebrew
zig build test -Dapp-runtime=none -Demit-macos-app=false -Demit-xcframework=false -Dtest-filter=bidi
zig build test -Dapp-runtime=none -Demit-macos-app=false -Demit-xcframework=false -Dtest-filter=RTL
zig build test -Dapp-runtime=none -Demit-macos-app=false -Demit-xcframework=false -Dtest-filter=mixed
zig build test -Dapp-runtime=none -Demit-macos-app=false -Demit-xcframework=false -Dtest-filter=Bengali
```

The corresponding prebuilt archive is published at
https://github.com/manaflow-ai/ghostty/releases/tag/xcframework-541e5e89db0448d5cd85a7b348d8f6a64618c900-crashsubdir-cmux-crash-v1
and pinned in `scripts/ghosttykit-checksums.txt`.

The previous cmux pinned fork head was `1b454eb99`, which retained the
Darwin-only `ghostty_surface_set_renderer_realized` C API (a
`display_realized` renderer-thread mailbox message that drives
`displayUnrealized()`/`displayRealized()`) on top of `5697db81`. cmux uses it to
release an occluded terminal's GPU renderer resources (Metal swap chain /
IOSurface) while keeping its PTY alive, then rebuild them on re-show. The API
returns whether the message was enqueued so the embedder only advances its
realize/unrealize mirror state on success. The push is `.instant`
(non-blocking) so it never stalls the embedder's main thread waiting on the
renderer. See manaflow-ai/ghostty branch `feat-renderer-realized-offscreen`,
the copy-mode read branches `issue-6170-surface-read-screen-text-main` and
`issue-6170-screen-clipboard-text`, and
https://github.com/manaflow-ai/cmux/issues/4607. The corresponding prebuilt
archive is published at
https://github.com/manaflow-ai/ghostty/releases/tag/xcframework-49cb510f759aa109a5b1d30329583195155e58a4-crashsubdir-cmux-crash-v1
and pinned in `scripts/ghosttykit-checksums.txt`. The `1b454eb99` render-grid
head's corresponding prebuilt archive is published at
https://github.com/manaflow-ai/ghostty/releases/tag/xcframework-1b454eb999d6f4aea28a18ca0e1500c0477383ef-crashsubdir-cmux-crash-v1
and pinned in `scripts/ghosttykit-checksums.txt`. The `7a5179843` RTL shaping
head's corresponding prebuilt archive is published at
https://github.com/manaflow-ai/ghostty/releases/tag/xcframework-7a51798436fa2cfcfcc9a2ed1e109ba69bdb68f9-crashsubdir-cmux-crash-v1
and pinned in `scripts/ghosttykit-checksums.txt`.

The prior head was refreshed from upstream `main` on May 1, 2026.
Earlier cmux pinned fork head: `34cbf180d`, merging the surface registry
serialization for https://github.com/manaflow-ai/cmux/issues/5458 (`e5c962a72`,
landed on cmux `main`) into the iOS render bounded-acquire line (`f78189ac1`)
combined with the cmd-click link refresh under mouse reporting (`df789cd4b`,
manaflow-ai/ghostty#71 and PRs #74 through #79) for
https://github.com/manaflow-ai/cmux/issues/5128. This keeps the previous head's
manual embedded IO patch in https://github.com/manaflow-ai/ghostty/pull/53,
the Metal renderer row rebuild guard for https://github.com/manaflow-ai/cmux/issues/3369,
the URL/path regex bound for spaced file paths followed by prose, and the iOS
render serial-queue bounded acquire fix from manaflow-ai/ghostty#80. This head
keeps the cmux theme picker hooks, exposes the manual surface IO needed by
libghostty iOS clients, bounds shaped glyph iteration during IME/preedit row
rebuilds, prevents Cmd-hover from highlighting normal sentence text after a file
path, and lets Cmd-click open links even while a mouse-reporting alt-screen TUI
(Claude Code, Codex) has grabbed the mouse.
It also supports Ctrl-N and Ctrl-P in the cmux theme picker.
The corresponding prebuilt archive is published at
https://github.com/manaflow-ai/ghostty/releases/tag/xcframework-34cbf180d8917b802d61d9929cfb493594f2ab52-crashsubdir-cmux-crash-v1
and pinned in `scripts/ghosttykit-checksums.txt`.

### 0) Render-grid span column preservation for mobile replay

- Commit: `79b5bb6ee` (render-grid: split nontrivial cells into own spans)
- PR: https://github.com/manaflow-ai/ghostty/pull/89
- Files:
  - `src/apprt/embedded.zig`
- Summary:
  - Forces wide cells and cells with attached grapheme data to close the active
    render-grid span before and after emission.
  - Preserves exact producer columns for mixed-width same-style text, so iOS
    replay no longer has to reconstruct per-grapheme widths from one aggregate
    `cell_width`.
  - Conflict note: this sits in the render-grid JSON encoder's row/cell loop,
    near the span coalescing logic and `appendRenderGridCellText`.

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
  - `4265d3428` (Apply cmux theme from picker search)
  - `176bd550f` (Add ctrl navigation to cmux theme picker)
- Files:
  - `build.zig`
  - `src/cli/list_themes.zig`
  - `src/main_ghostty.zig`
- Summary:
  - Adds a `zig build cli-helper` step so cmux can bundle Ghostty's CLI helper binary on macOS.
  - Lets `+list-themes` switch into a cmux-managed mode via env vars, writing the cmux theme override file and posting the existing cmux reload notification for live app-wide preview.
  - Keeps the preview UI readable in light mode, matches upstream picker startup behavior, and hardens writes to the cmux-managed theme override file.
  - Restores Enter as the cmux apply action by writing the currently highlighted theme before the picker exits.
  - Applies the highlighted search result when Enter is pressed from search mode in cmux-managed picker sessions.
  - Supports Ctrl-N and Ctrl-P as one-row down/up navigation in cmux-managed picker sessions.

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

- Commits:
  - `0b231db94` (Re-export cmux selection APIs removed from upstream)
  - `46bd03a7` (surface: add absolute screen row text read)
  - `edad0cfec` (surface: format screen row clipboard text)
  - `e81fb65f` (surface: bound screen clipboard text formatting)
- Files:
  - `include/ghostty.h`
  - `src/apprt/embedded.zig`
  - `src/Surface.zig`
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

### 10) Manual embedded IO for libghostty iOS

- Commit: `22fa801f8` (Expose manual embedded IO for iOS)
- PR: https://github.com/manaflow-ai/ghostty/pull/53
- Files:
  - `include/ghostty.h`
  - `src/Surface.zig`
  - `src/apprt/embedded.zig`
  - `src/input.zig`
  - `src/input/text.zig`
  - `src/renderer/Thread.zig`
  - `src/termio.zig`
  - `src/termio/Manual.zig`
  - `src/termio/Termio.zig`
  - `src/termio/backend.zig`
- Summary:
  - Exposes `GHOSTTY_SURFACE_IO_MANUAL`, `io_write_cb`, `ghostty_surface_process_output`,
    `ghostty_surface_text_input`, and `ghostty_surface_render_now` through the embedded C API.
  - Wires the existing manual termio backend into embedded surfaces without taking stale
    xcframework or build-system changes from the old iOS branch.
  - Keeps manual surface writes inline so iOS typing does not wait on the termio thread wakeup path.
  - Comments each fork-only API/runtime hook with its upstream-removal condition.
  - Checked upstream `ghostty-org/ghostty` `4dcb09ada` on May 1, 2026. It does not expose
    equivalent libghostty surface IO selection, write callback, text-input callback,
    render-now C API, or output C API. Upstream already has internal
    `Termio.processOutput`, so prefer an upstream C bridge if one lands.

### 11) Metal renderer preedit row rebuild guard

- Commits:
  - `70b95dada` (Expose unsafe preedit catch-up in renderer rows)
  - `fe972c095` (Bound renderer preedit catch-up to shaped glyphs)
- Files:
  - `src/renderer/generic.zig`
- Summary:
  - Adds a regression test for the row-rebuild path where IME/preedit covers the
    only shaped glyph in a row and the remaining terminal cells are empty.
  - Bounds the shaped glyph cursor before reading from the shaped-cell slice, so
    `GenericRenderer(Metal).rebuildRow` no longer assumes terminal cells and
    shaped glyph cells have one-to-one cardinality.
  - The first commit intentionally preserves the panic so cmux can keep the
    required failing-test-then-fix history for https://github.com/manaflow-ai/cmux/issues/3369.

### 12) URL/path regex bounds for spaced file paths

- Commits:
  - `6e10706a7` (test: cover spaced file path link bounds)
  - `6eed7af92` (fix: bound spaced file path links)
  - `ff6e1260d` (fix: handle dotted spaced path prefixes)
- Files:
  - `src/config/url.zig`
- Summary:
  - Adds coverage for a path with spaces ending in `.mp4` followed by a normal sentence.
  - Routes dotted paths with spaced directory names through the stricter dotted-path branch.
  - Keeps single-space path components such as `Recovered Screen Recordings` while preserving
    the existing double-space stop case.
  - Trims trailing sentence punctuation when more text follows, without breaking dotted paths
    that end at end-of-line.
  - Preserves versioned or dotted path components before the first space, such as
    `/tmp/v1.2 captures/video.mp4`.

### 13) Cmd-click opens links under mouse reporting (alt-screen TUIs)

- Commits (manaflow-ai/ghostty#71, by @doronpr):
  - `1c7613c95` (fix: open terminal links on cmd-click even when mouse reporting is active)
  - `55d154a97` (fix: gate link refresh on effective mouse-reporting state)
- Follow-up commits (manaflow-ai/ghostty#74):
  - `354e3626b` (fix: suppress mouse reporting for the full cmd-clicked link click)
  - `d1dbbec9b` (fix: key cmd-click link suppression on the modifier, not over_link)
- Follow-up commit (manaflow-ai/ghostty#75):
  - `76ead3eae` (fix: also suppress motion reports during a cmd-clicked link drag)
- Follow-up commit (manaflow-ai/ghostty#76):
  - `f24195271` (fix: scope cmd-click link suppression to left button; clear stale hover)
- Follow-up commits (manaflow-ai/ghostty#77):
  - `5998abddd` (fix: latch cmd-click link suppression for the click lifecycle)
  - `59fb750c0` (fix: clear link-click latch unconditionally on left release)
- Follow-up commit (manaflow-ai/ghostty#78):
  - `9f014e98b` (fix: open latched link on release with press-time chord; defer-clear latch)
- Follow-up commit (manaflow-ai/ghostty#79):
  - `df789cd4b` (fix: only open a latched link click that started on a link)
- Files:
  - `src/Surface.zig`
- Summary:
  - Link hover/highlight state was refreshed in `keyCallback`/`cursorPosCallback`
    only when mouse reporting was off, or shift was releasing the mouse from
    capture. Holding the ctrl/super link-activation modifier was not considered,
    so under a mouse-grabbing alt-screen TUI (Claude Code, Codex) `over_link`
    stayed `false`, the link-click branch in `mouseButtonCallback` was skipped,
    and the Cmd-click was reported to the program — which made cmux fall back to
    the OS default browser instead of honoring the configured link-open target.
  - Adds a shared `mouseLinkRefreshAllowed` gate (pure logic in
    `mouseLinkRefreshAllowedState`) that also allows local link handling when the
    ctrl/super modifier is held, using the effective mouse-reporting state
    (`isMouseReporting()`), matching iTerm2 and macOS Terminal. Fixes
    https://github.com/manaflow-ai/cmux/issues/5128.
  - Follow-up (#74): `mouseButtonCallback` ran the link-open path only on
    release, while the mouse-report path ran for both press and release and only
    broke out for the shift-release case — so a Cmd-click over a link still
    reported the *press* to the program and leaked a half-click to mouse-grabbing
    TUIs. The follow-up breaks out of the report path whenever the ctrl/super
    link chord is held (keyed on the modifier, like the shift-release path, so
    cursor jitter can't leak a press or a release), suppressing the whole click.
  - Follow-up (#75): `cursorPosCallback` still emitted `.motion` reports while a
    button was held during the chord, so a drag during link activation leaked
    button-motion. Mirrors the shift "grab override" for the ctrl/super chord in
    the motion path. Net: the link chord suppresses the whole left click+drag —
    press, release, and motion — consistently.
  - Follow-up (#76): scopes that suppression to the left button (ctrl/super
    right/middle clicks still reach the program, since link activation is
    left-only), and clears a stale link highlight/cursor when the chord is
    released through `cursorPosCallback`'s mods (refresh when `over_link` is set,
    mirroring `keyCallback`'s existing reset branch).
  - Follow-up (#77): latches the suppression decision at left-button press
    (`mouse.link_click_active`) and applies it through the release, instead of
    re-checking the live modifier each event — so releasing ctrl/super before the
    mouse button can't leak the release as a half-click. Ties suppression to the
    click lifecycle (press/drag/release), fully closing the half-click class. The
    latch is cleared unconditionally on left release (independent of
    mouse-reporting state) so it can't go stale.
  - Follow-up (#78): unifies the open and suppression decisions. `linkAtPos`
    uses the latched chord while a click is active and the release attempts
    `processLinks` whenever latched, so releasing the modifier before the button
    still opens the link (instead of swallowing the click); the latch is cleared
    via a function-level `defer` so the early-return link-open path resets it.
  - Follow-up (#79): only opens the latched click when it started on a link
    (`link_press_over_link`), so a chord drag that began off a link and released
    over one is swallowed rather than opening a link the press never targeted.
  - Known limitation (noted by review): the bypass matches the default
    `ctrlOrSuper` chord, which is exactly what both link kinds already require to
    activate (OSC 8 `linkAtPos` and the default url `hover_mods = ctrlOrSuper`); a
    user who reconfigures `link.highlight.hover_mods` to a non-default chord would
    not get the under-mouse-reporting bypass. Out of scope for #5128.

### 14) Embedded surface registry serialization

- Commits:
  - `c9b61a8af` (Add surface registry mutation serialization test)
  - `e5c962a72` (Serialize Ghostty surface registry mutations)
- Files:
  - `src/App.zig`
- Summary:
  - Adds a deterministic regression test for concurrent embedded runtime
    surface registry mutation.
  - Protects the native `App.surfaces` list and `focused_surface` pointer with
    one mutex so an off-main `ghostty_surface_free` cannot overlap the main
    actor `ghostty_surface_new` insertion path.
  - Keeps callbacks such as the quit timer outside the registry mutex to avoid
    re-entrancy through the embedder.
- Conflict notes:
  - Any upstream change to `App.addSurface`, `App.deleteSurface`,
    `App.focusedSurface`, or the embedded surface close path should preserve
    serialization of registry/focus mutation across create and free.

The current cmux pin is the merged head `34cbf180d`, which merges the surface
registry serialization (`e5c962a72`, section 14, landed on cmux `main` via
branch `issue-5458-surface-registry-lock`) into the Cmd-click link fix line
(`df789cd4b`, section 13) on top of the iOS render bounded-acquire pin
(`f78189ac1`). It is reachable from `manaflow-ai/ghostty` through branch
`issue-5128-alt-screen-link-open`. Published
`xcframework-34cbf180d8917b802d61d9929cfb493594f2ab52-crashsubdir-cmux-crash-v1`
and pinned its archive checksum in `scripts/ghosttykit-checksums.txt`. The
release and checksum pin must be regenerated whenever this commit changes, even
for comment-only amends, because the release tag is keyed by the Ghostty commit
SHA.

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

- April 30, 2026, theme picker search Enter:
  - Search-mode Enter in cmux mode must apply the current filtered selection and exit with
    outcome `apply`.
  - Escape still leaves search mode, and stock Ghostty search Enter still returns to normal mode.
  - Verified with `./scripts/reload.sh --tag thmenter`.
  - Published `xcframework-4265d34282ce2023c27da851c454dabe6cdc76ce` and pinned
    its archive checksum in `scripts/ghosttykit-checksums.txt`.

- May 1, 2026, manual embedded IO for libghostty iOS:
  - Added only the manual embedded IO API/runtime pieces on top of fork `main` `495316732`.
  - Avoided old iOS branch `.gitignore`, package, and xcframework build-system changes.
  - Checked upstream `ghostty-org/ghostty` `4dcb09ada`; no equivalent public libghostty
    surface IO API exists yet.
  - Added comments to the fork-only hunks stating that they should be deleted in favor of
    an upstream implementation when one exists.
  - Verified with `zig build test`.
  - Verified the universal macOS plus iOS xcframework path with
    `CMUX_GHOSTTYKIT_NO_PREBUILT=1 ./scripts/ensure-ghosttykit.sh`.
  - Published `xcframework-22fa801f88f96fa842e54ecce6c34a5d36003d19` and pinned
    its archive checksum in `scripts/ghosttykit-checksums.txt`.
  - Merged https://github.com/manaflow-ai/ghostty/pull/53 so the submodule SHA is
    reachable from fork `main`.

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
  - The April 30, 2026 follow-up requires the same behavior from search mode, while preserving Escape
    as the search cancel path.

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

- `src/Surface.zig` (modifier tracking)
  - `modsChanged` and the key callback's link-highlight gate must compare binding mods against
    binding mods (stored mouse mods are binding-only). cmux sends sided modifier bits on key
    events for `macos-option-as-alt = left|right`; comparing raw mods re-dirties the screen and
    re-runs the link refresh on every event while a sided or lock modifier is held. If upstream
    refactors modifier tracking, keep the binding-normalized comparison.

- `src/termio/stream_handler.zig`
  - Keep DECSET 1004 enablement side-effect free. xterm-compatible focus reporting should only emit
    `CSI I` / `CSI O` on actual focus transitions, not immediately when the mode is enabled.

- `src/terminal/stream_terminal.zig`
  - Keep the APC handler wired into `.apc_start`, `.apc_put`, `.apc_end`, and preserve the
    `apcEnd()` response path so kitty graphics still reach `Terminal.kittyGraphics()` and reply via
    `write_pty`.

If you resolve a conflict, update this doc with what changed.
