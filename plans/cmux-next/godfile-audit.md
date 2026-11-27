# God-file audit (cmux-tui Rust files and cmux-next Swift types)

Owner: Rust CLI / daemon owner. Standing assignment (Lawrence, 2026-10-04): audit and
split god files with pure moves, keep the ratchet. Data from feat-cmux-next at
2026-10-04 and the branches with their own unmerged commits updated 10-02..10-04.

## Facts

- `scripts/cmux-next/godfile-baseline.tsv` grandfathers 108 Rust files (402,772 lines) and
  4 Swift types. New files are limited to 1000 lines / 60 fns (Rust) and the Swift type
  limit; baselines only go down (lowered 2026-10-04 in 34ecd6d35f0).
- The gate counts test files too (`workspace_registry/tests.rs` is grandfathered), so
  moving an inline `mod tests` out of a file only helps when the tests are split by
  topic into files under the new-file limit.
- The Swift type budget sums a type's declaration and ALL its extensions
  (check-no-godfiles.sh adds `ext` spans to the `decl` total). `TabStripView` is already
  spread over 15 `TabStripView+*.swift` files. Moving code into more extensions changes
  nothing: a Swift god type needs a new owner type (with its own state and tests), which
  is a refactor, not a pure move.

## Method for Rust splits (pure moves)

1. Inline tests: `mod tests { .. }` becomes `mod tests;` with `<file>/tests/<topic>.rs`
   submodules, each under 1000 lines, grouped by the feature under test. No test body
   changes.
2. Giant `impl X` blocks: methods move verbatim into child modules
   (`<file>/<area>.rs` holding `impl X { .. }`), grouped by responsibility. The only
   edit: a moved private method becomes `pub(super)` (a child module's private items are
   invisible to its parent). Fields stay where they are (children see parent privates).
3. One seam per commit, `git mv`-friendly, baseline lowered in the same commit, full
   hosted gate, short window, announced so lanes rebase. Never raise a baseline.

## Top files: seams, open branches, order

Lines / inline-test lines; "open" = branches with their own unmerged commits touching
the file (stale federation-tui r15..r22 and fedd-scratch rounds counted but likely dead).

| File | Lines (tests) | Natural seams | Open branches |
|---|---|---|---|
| cmux-tui/src/session/remote.rs | 10,017 (5,459) | tests by topic (attach, requests/shutdown, frames, surfaces); `RemoteSession` (1,882): transport/requests, attach, surfaces, frames | 0 |
| cmux-tui/src/config.rs | 9,940 (3,898) | tests; `Action` + `Keys` (keymap), `ChromeTheme` (theme), loader/merge, snapshot | 0 |
| cmux-tui/src/machine_provider_runtime.rs | 6,509 (3,957) | tests; `ProviderMachineRuntime` (1,496) vs `ProviderMachineController` | 0 |
| ghostty-vt/src/terminal.rs | 4,847 (0) | trackers out of `Terminal`: `ColorOverrideTracker`, `PromptSemanticTracker`, `MouseModeChangeDetector`, `VtBoundaryTracker`, `PaletteOverrideTracker`, `PaletteCommand` | 0 |
| cmux-tui-core/src/browser.rs | 11,511 (6,120) | tests; `BrowserSurface` (3,242): frames (830), screen, input/mouse/keys, config, session | 2 (browser-history-hold, daemon-idle-wakeups) |
| cmux-tui/src/remote_runtime.rs | 6,678 (3,600) | tests; reconnect groups, socket leases, daemon cleanup | 3 (idle-wakeups, stale pin, nightly clippy) |
| cmux-tui-core/src/terminal_host_runtime.rs | 10,343 (157) | host protocol records, launch, recovery, cell pixels | 4 (durable lane) |
| cmux-tui/src/remote_cli.rs | 5,325 (2,486) | tests; per-verb handlers (connect, ssh, forward, rpc, enroll) | 8 (server lane) |
| cmux-tui-core/src/surface.rs | 10,758 (3,360) | tests; `Surface` (4,413): host lifecycle (1,121), terminal I/O, browser shim, mouse/scroll; `PtySurface`. The spawn path is NOT in this plan: the terminal-interfaces lead moves it to `surface/spawn.rs` in its backend slice | 9 (P8 3b series, hostdeath, idle-wakeups, cmdretention) |
| cmux-tui/src/app.rs | 47,142 (22,004) | tests (22k, by area); `impl App` (14,555): input/handle (1,683), machine (1,031), sidebar (1,005), mouse (985), menus (977), scroll/drag, prompt, selection, workspace/pane/tab ops, render; `OrderedSession` (1,800) | 13 (feed daemon/app, my flakes, stale federation rounds) |
| cmux-tui-core/src/mux/resource_topology.rs | 6,820 (0) | resource ops by noun: tabs (1,095), panes, terminals, workspaces, close, screens | 17 (app-screens, durable, tabws-name, lone-width, rows, hostdeath, creation-order) |
| cmux-tui-core/src/workspace_registry.rs | 6,160 (0) | `WorkspaceRegistry` core (1,517), session lease/coordinator, state resetter | 22 (P8 3b series, rows, feed, hostdeath) |
| cmux-tui-core/src/workspace_registry/resource_store.rs | 5,332 (0) | resource patch commit vs topology snapshot vs reporters | 21 (P8 3b series, rows, tab-restart, docks) |
| cmux-tui-core/src/mux.rs | 34,018 (13,826) | tests (13.8k); `impl Mux` (15,663): workspaces (2,965), terminals (2,804), layout/resize/sizing, agents, notifications, journal, images, hooks | 37 (most lanes) |
| cmux-tui-core/src/server.rs | 27,746 (11,530) | tests (11.5k); `ClientRegistry` (1,142), outbound/writer, scheduler, request dispatch (3,036) | 61 (most lanes, incl. GPUI) |
| cmux-tui/src/main.rs | 3,239 | arg parsing, start modes | 20 (server, P8, apps) |

## Split order (fewest conflicts first)

1. Files no open branch touches, smallest risk first: `ghostty-vt/src/terminal.rs`
   trackers, then `session/remote.rs`, `config.rs`, `machine_provider_runtime.rs`
   (tests first, then impl seams). Each in a short window; they cannot conflict.
2. Low overlap: `browser.rs`, `remote_runtime.rs` (after daemon-idle-wakeups lands),
   `terminal_host_runtime.rs` (after the durable lane), `remote_cli.rs` (after the server
   lane's current stack).
3. Hot files, tests modules first (lanes rarely touch existing tests modules), then impl
   seams by area, each after the branches touching that area land:
   `mux.rs` and `server.rs` after chief's cloud-proxy branch b6ff7619fa0 (it already moves
   capabilities, journal plugin host, loopback policy out); `surface.rs`,
   `workspace_registry.rs`, `resource_store.rs` after P8 3b; `app.rs` after feed-app and my
   fcn-flakes-2; `resource_topology.rs` after app-screens, rows and tab-restart.
4. Swift types (refactors, each with tests; cmux-ci gates, no cmux-tui window):
   `TabStripView` (2,116): drag/drop state into a `TabStripDragController`, hover cards and
   inline rename into their own owners. `DaemonConnection` (1,477): request/response
   correlation and the event demux into separate types. `WindowManager` (1,131),
   `TerminalSurfaceView` (1,106): smaller; take after the first two.

## Decisions (coordinator, 2026-10-04)

1. The four Swift types are refactors into new owner types with focused tests (not pure
   moves), each landed through a cmux-ci run.
2. The new-file Rust limit drops from 1000 to 800 lines; a split never creates a new
   grandfathered row.

## Progress

- `ghostty-vt/src/terminal.rs` 4,846 -> 3,335 lines (224 -> 168 fns): six tracker seams
  moved to `terminal/` (mouse_mode_change, palette_override, cursor_override,
  color_override, vt_boundary, prompt_semantic), one pure-move commit each.

## Ratchet proposals

- Keep: never raise a baseline; lower it in the same commit as every split.
- Propose: lower the new-file Rust limit from 1000 to 800 lines; keep 60 fns.
- Propose: a `tests/` file may not exceed the same limit (already enforced) and a split
  must not create a new grandfathered row.
