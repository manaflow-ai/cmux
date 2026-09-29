# cmux next: Swift frontend rewrite on cmux-tui

Living document. Branch `feat-cmux-next`, worktree `worktrees/feat-cmux-next`.

## Goals (user, 2026-09-28)

1. Remove bonsplit entirely.
2. Terminals and layout state live in the cmux-tui daemon. Quit and reopen cmux keeps every terminal, tab, pane, column, screen, workspace.
3. Tabs: Chrome-style. Tabs shrink as count grows, hover a tiny tab for a live preview, Chrome-level open and close animations. Also a bonsplit-like mode.
4. niri-style scrolling columns: create columns, scroll horizontally between them.
5. Screens: supported, UI hidden until the user opts in.
6. Command palette (Cmd-Shift-P): Raycast quality, Liquid Glass, fast fuzzy search, every action registered.
7. Sidebar: Arc/Dia/Chrome quality, Liquid Glass, better drag reorder, groups.
8. Browser: WebKit and CEF (patched fork with real Chrome extensions). POC ~/fun/cmux2, fork ~/fun/cef-cmux, dist ~/fun/cef-cmux-dist.
9. Delete and rewrite. Do not port old Swift. Modern Swift 6 / AppKit / Observation. Move state into cmux-tui where it belongs.

## Visual rules

- No blue accent anywhere. Subtle grays for selection, focus, hover.
- Compact by default (user 2026-09-28), still extremely well designed: use CmuxNextDesign `Metrics` / `Typography` tokens only (2 pt grid, 12 pt chrome body, 28 pt tab strip, 26 pt sidebar rows). No hardcoded sizes in feature modules. Density is configurable (user 2026-09-28): `appearance.density` (compact|comfortable) plus per-metric overrides `appearance.metrics.<MetricKey>` in cmux.json, a Settings control and palette actions; `DesignSettings.shared` is @Observable so changes apply live. Views must read Metrics/Typography inside Observation-tracked layout, never cache them.
- No god files (user 2026-09-28): max 400 lines per Swift file (tests 600), max 3 top-level types per file, one responsibility per file. `scripts/cmux-next/check-no-godfiles.sh` must pass before any merge into feat-cmux-next.
- Sidebar is fully custom (user 2026-09-28): no NSOutlineView/NSTableView/NSSplitViewController sidebar/SwiftUI List; own layer-backed rows, animations, selection, resize.
- Liquid Glass (`NSGlassEffectView`, `.glassEffect`) where it reads clean: palette, sidebar, tab strip, popovers. Not on terminal content.

## Architecture decisions

User decisions 2026-09-28:
- D1: new code in local SwiftPM packages (Packages/macOS/CmuxNext), sibling Xcode target `cmux-next`; on this branch the `cmux` scheme builds it, `cmux-legacy` keeps the old app. Delivery = one tagged app the user can dogfood with all changes in.
- D2: long-lived branch `feat-cmux-next`, sub-branches merge into it.
- D3: CEF fork + prebuilt artifact go to a new repo (manaflow-ai/cef, private until user says otherwise).
- D4: Cloud and iOS must keep working seamlessly. They may be rewritten so both ride cmux-tui (Cloud VMs already run the daemon; iOS should attach to the same daemon tree).
- Deployment target macOS 26 for cmux-next (flagged: appcast needs minimumSystemVersion before any release).

Design docs: architecture.md (state ownership, AppKit, RAM/CPU budgets, Chrome tab group parity; binding for every agent), cmux-tui-contract.md, inventory.md, browser.md, shell.md, cloud-ios.md.

## Status

- 2026-09-28: worktree created off main fde44232c35. Research wave launched.
- 2026-09-28: app shell scaffold landed. `Packages/macOS/CmuxNext` (tools 6.2, Swift 6, `.macOS(.v26)`; modules CmuxNextApp, CmuxNextDesign, CmuxNextActions, CmuxNextDaemon placeholder, CmuxNextTerminal Ghostty host with manual-mirror IO, not yet wired into the window). Xcode target `cmux-next` (added by `scripts/cmux-next/add-xcode-target.py`), `cmux` scheme repointed to it, `cmux-legacy` scheme builds the old app. `swift build` and `xcodebuild -scheme cmux` pass on Xcode 27 and 26.3; no tagged launch or fleet build yet.
- 2026-09-28: scaffold landed (feb033d, fc9833c). Feature module stubs + AGENT-BRIEF.md pushed (90c0fdc). Wave 2 running, one branch per module into feat-cmux-next: daemon, terminal, tabs, sidebar, palette, layout, browser. Daemon gaps branch feat-cmux-next-daemon (Rust). CEF spike in ~/fun/cmux2-spike. CEF fork pushed to manaflow-ai/cef (private) branch cmux/8037.
- Defaults taken (user may override): raw v12 protocol; session `cmux-app` / `cmux-app-<tag>`; WebKit tabs are daemon tab kind; libghostty manual-mirror rendering; no mixed-machine workspaces in v1; keep simulator stream service, drop Mac simulator pane; delete Canvas and custom sidebars; Go remote daemon deleted only after cmux-tui parity; thin new mobile.* compat adapter for shipped iOS.

## Integration notes (for the App wiring wave)

- Layout (PR 15503, merged): replace the "daemon wins on 3rd snapshot after drag" rule with transaction-id echo (LayoutTransactionID round-trips through the daemon). Hacky as merged.
- Layout animates hosted view frames per frame: debounce/lease PTY resize (only send resize at animation end or on sizing-lease change).
- Map daemon `stack` nodes to one leaf. App must call `model.focus` when terminal first responder changes.
- Horizontal trackpad gestures over column screens are captured by layout; terminal apps lose horizontal scroll there. Revisit with a modifier or edge-only policy after dogfood.
- CEF: lazy init works (external_message_pump + CFRunLoopTimer). Fork patches for clip/scroll/destroy signal in progress on manaflow-ai/cef cmux/8037-clip.

## Tab drag (user requirement 2026-09-28): as fluid as possible

One drag, every destination. Dragging a tab can end as: reorder in its strip; move into another pane's strip (any window); new split (pane edge zones L/R/T/B); new pane in a column; new niri column (between columns or past the last column); new workspace (sidebar gap, or onto the sidebar "new" zone); move into an existing workspace (hover a sidebar row, Arc-style spring-load: hovering opens that workspace so you can keep dragging into its panes); new window (release outside any window: Chrome tear-off, the window appears under the cursor already carrying the tab).

Design:
- `TabDragSession` lives in CmuxNextApp (the only module that sees every surface). It owns one floating borderless panel with a live glass "ghost" of the tab (thumbnail from the terminal/browser snapshot API) that follows the cursor across windows and outside them. Chrome behavior: while over a tab strip the ghost collapses into an inline tab with neighbors sliding; when it leaves the strip it expands into a preview card; over a pane it shows the drop-zone highlight.
- Each surface implements a `TabDropTargetProviding` protocol (in CmuxNextDesign so every module can conform without importing each other): hit-test(point in screen coords) -> DropProposal(kind, highlightFrame, commit closure). Tab strip, layout, sidebar conform; the window background and "outside" are handled by the session.
- Commit is ONE daemon command per outcome (atomic, undoable): move-tab(to pane, index), tab-to-new-split(pane, edge), tab-to-new-column(screen, after column), tab-to-new-workspace(group?, index), move-tab-to-workspace. Windows are frontend-local: which workspace each window shows persists in a `personal` frontend projection so windows restore after relaunch. Tear-off = tab-to-new-workspace + open that workspace in a new window.
- Optimistic UI: apply locally at drop, reconcile via transaction-id echo. Escape cancels with a spring back to origin. Spring-loaded sidebar hover 500 ms. Auto-scroll strips, sidebar and niri columns near edges during drag. Multi-tab drag (cmd-click select) later.
- Tabs (PR 15509, merged): App must end every drag (model removal or restoreDetachedTab) or the tab stays hidden. Optimistic reorder is kept until model order changes: on daemon rejection the App must push the authoritative order (transaction-id echo) to reset it. Rename the App's placeholder TabStripView.

## Action contract (user requirement 2026-09-28): every feature, every entrypoint

Every user-visible capability is ONE `ActionDescriptor` in CmuxNextActions plus ONE handler. Entrypoints are generated from the registry, never hand-wired per surface:

| Entrypoint | Generated how |
| --- | --- |
| Command palette | lists every available action; args collected inline from the action's argument schema |
| Keyboard | every action is bindable; default shortcut optional; user bindings in cmux.json `shortcuts.<actionID>`; Settings shortcut editor lists the registry |
| Right-click | menus are declared as ordered lists of action IDs per context (tab, tab group, pane, column, workspace row, workspace group, sidebar background, terminal selection, browser page, link); the menu builder renders title/shortcut/enabled state from the registry |
| CLI | `cmux action list [--json]`, `cmux action run <id> [--arg k=v ...] [--target ref]`; plus a friendly generated verb per action (`cliName`, e.g. `cmux tab-group create --name X`), all over the app control socket (`action.list`, `action.run`, `action.describe`) |
| Menu bar | main menu built from action IDs too |

Descriptor fields: id (stable, = cmux.json shortcut key), title (localized), keywords, category, symbol, argument schema (typed: string, int, enum, target refs like tab/pane/workspace/group), target context kinds, availability predicate, default shortcut, cliName, menu placements.

Enforcement: a registry conformance test fails if an action lacks a cliName or a palette entry, if a context menu references an unknown ID, or if a handler is missing in the App. Adding a feature without all entrypoints does not compile/test. Layout/state mutations still go to the cmux-tui daemon, so the plain `cmux-tui` CLI can drive them even with the app closed; the app's action handlers are thin calls into daemon commands.

## Groups

- Workspace groups: sidebar sections (daemon state, feat-cmux-next-daemon).
- Tab groups: Chrome-style groups inside a pane's tab strip: name, color (gray-friendly palette), collapse/expand with animation, drag a whole group, drag tabs in/out, close group, ungroup, move group to new split/column/workspace/window. Daemon state (tab placement belongs to a group id in the pane), journaled, CLI-controllable.
- Both fully covered by the action contract (create, rename, recolor, collapse, move, ungroup, close, add/remove member) via right-click, shortcuts, CLI, palette.
- Sidebar (PR 15513, merged): App must `model.apply` intents optimistically. Fix later: auto-scroll timer should run only near edges; agent spinner should use a finite/paused animation when the window is occluded; group header double-click flicker. 1000 workspaces: ~55 row views, 0.14 ms layout.
- Terminal (PR 15511, merged): output lane has no backpressure (daemon client adds bounded buffering); remove the `CMUX_NEXT_DEBUG_TERMINAL` AppDelegate hook when real panes land; bundle Ghostty resources in the target.
- CEF (PR 15523, merged): artifact https://github.com/manaflow-ai/cef/releases/tag/cef-154.0.28-cmux.2-clip pinned in scripts/cmux-next/cef-manifest.json. Fleet workers cannot read the private release yet (user decision: public repo, worker read token, or mirror). Follow-ups: CEF-ready NSApplication subclass in the App (replace the shim's runtime method injection); drop the 30 Hz fallback pump timer (idle 0.5% CPU, budget is 0%); fork patch for the 28 pt dark band at page top; extension popup content in background launch; session cookie persistence without restoring old Chrome tabs.
- Control (PR 15524, merged): App calls SettingsController + ControlService (see PR). Gaps: chords not applied, cmuxOnly capability tokens not verified, password file/Keychain not read, remote relay denies action.*, `appearance` missing from web/data/cmux.schema.json.
- 2026-09-29: core wiring merged (PR 15522). Tag nxcore-v3: terminals/splits/columns/workspaces/scrollback survive quit+relaunch; idle app 94 MB footprint (136 MB RSS), 0.0% CPU; daemon 70 MB, 0.0%. 68/385 actions bound. Wave 4 running: stability (resize blank surface, partial column blank, inherited socket env, CEF embed local build, no-activate audit, drop shim injection), TabDragSession, action binding x3 (workspace/window, tab/pane/terminal, browser/agents/misc). Blocked on daemon branch (PR 15518) for groups, pins, frontend browser tabs, atomic tab moves; the bundled cmux-tui must come from that branch once merged.
- 2026-09-29 (after crash recovery): merged daemon-align (15554: pinned branch cmux-tui, env allowlist), tabdrag (15555), bind-workspace (15556). Stability (15560) and bind-misc (15558) are being reconciled; bind-tabs in progress. 65 actions typed-unavailable (Markdown/diff viewers, file preview, VS Code server, browser profiles/history/import, agent chat/Teams/Computer Use, 23 Cloud actions) = scope for next waves.
- Follow-ups from stability: empty workspace (no screens, e.g. after hard daemon kill) must auto-create a terminal instead of an empty content area; test orphans: `cmux-tui server stop` leaves __terminal-host processes (by design they survive; add a test-only teardown); browser tabs must use frontend-browser-tabs-v1 with engine choice now that the pinned daemon has it; debug CLI needs CMUX_NEXT_SOCKET_MODE=automation.
- Blocker for GUI verification: cmux-cua onboarding incomplete on this Mac; posted background events are ignored by the app. All pointer/drag/hover checks UNVERIFIED until fixed.
- 2026-09-29 PTY exhaustion incident: 419 leaked cmux-tui __terminal-host processes from cmux-next test runs (concurrency bench 232, daemon-align 64, binders/compat 15 each, daemon-client tests) pushed the Mac to 524 ttys (ptmx_max 511), which can stop the user's own cmux from opening terminals. Killed by exact test binary paths (not ~/.local/bin/cmux-tui). Root cause: cmux-tui close-workspace detaches but keeps session-owned terminals alive; tests never ended hosts. Required fixes: (1) app close-workspace/close-tab must end terminals that reach zero placements (terminal.close), or the daemon GCs zero-placement terminals after a grace period (design decision); (2) every test/bench tears down its daemon and hosts and asserts PTY count back to baseline.
- CLI compat (PR 15579) pending merge after concurrency: 40/40 e2e before PTY exhaustion; tests_v2 17 pass/81 fail (39 need old debug.* methods). Gaps: terminals lack CMUX_WORKSPACE_ID/CMUX_SURFACE_ID so agent hooks, feed.push and agent_journal_append do not reach cmux-next; sidebar status stored but not shown; bundled `cmux --help` crashes (missing resource bundle); select-workspace took 80-500 ms on main (one exceeded 2 s).
- Concurrency (PR 15575, merged): CLI storm (32 clients, 2,000 requests, 50 MB stream): 0 main stalls > 50 ms, frame p99 8.3 ms, read p99 10 ms, create p99 13 ms, slowest 26 ms; old app: create p99 765 ms, 873/1,718 reads rate-limited, 5 s timeouts, 555 -> 772 MB. Open: memory stays 10-37% above baseline after closing ~100 terminals (limit 10%); daemon closes terminals ~10/s serially; mutation timeouts can still apply later in the daemon (only tab close reconciles); action.run replies when the handler starts, not when the daemon applied it (need an optional wait-for-echo reply for CLI).
- Updater (PR 15623, merged): Sparkle via CmuxUpdater library (so B7 keeps CmuxUpdater), LSMinimumSystemVersion 26.0, appcast scripts write sparkle:minimumSystemVersion and fail without a floor. Before main: commit the final legacy release's appcast item as scripts/cmux-next/legacy-appcast-item.xml so macOS 14/15 land on the final legacy build; Homebrew cask needs `depends_on macos: ">= :tahoe"` in update-homebrew.yml; per-method socket deadlines (updates.check exceeds 2 s).
- 2026-09-29: B0-B2 deletion merged (PR 15659): bonsplit, Sources/, legacy targets/tests, TunnelExtension/WireGuardKit, 30+ legacy packages, 14 legacy workflows; ~1.40M lines deleted; pbxproj 18.8k -> ~2.1k lines. Targets left: cmux-next, cmux-cli, cmuxCLITests. Remaining M-gate (before main): nightly/release/sign scripts for cmux-next (they still expect tunnel extension, diff sidecar, cmux-cua, nucleo dylib), bundled `cmux --help` crash (missing CmuxFoundation resource bundle), CI lane for CmuxNext package tests, CEF artifact for CI, x86_64 cmux-tui/CEF or Apple-silicon-only decision, final legacy appcast item, Homebrew cask macOS floor, relay default-deny policy, Swift 6.0 rule vs tools 6.2 for App/CLI.
- Batch close (PR 15676, merged): `close-tabs` + `end_terminals` on close-pane/screen/workspace/tab-group in one transaction (one fsync), incremental projection skips unchanged rows; 100-terminal batch close reflects in 36-40 ms, hosts gone ~1 s; app close-workspace flow x100 10.5 s -> 3.9 s; new-tab unchanged (~120 ms). Pin f5d45a8. Tab closes detach (reap after 30 s) for undo; workspace close ends terminals at once. Known pre-existing cmux-tui failures: keep_on_exit_retains_tab_* and 13 cmux-tui-core unit tests (also on base).
- Deletion follow-up (PR 15693, merged): 178k more lines (B3-B5): 6 unlinked packages, unused resources, 47 tests_v2 debug.* files, 13 legacy CLI verbs (typed "unsupported in cmux-next"), CLI package shrink, leftover CI. Total deleted on branch so far ~1.58M lines. Follow-ups: localize the CLI "unsupported"/"Unknown command" errors (l10n rule), decide kept items (CmuxSimulator, import/sudo, themes, agent-session webview, CmuxSyncStore, daemon/ B6), clean launch env must include TMPDIR.
