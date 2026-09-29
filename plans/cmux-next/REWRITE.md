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
- Sidebar is fully custom (user 2026-09-28): no NSOutlineView/NSTableView/NSSplitViewController sidebar/SwiftUI List; own layer-backed rows, animations, selection, resize.
- Liquid Glass (`NSGlassEffectView`, `.glassEffect`) where it reads clean: palette, sidebar, tab strip, popovers. Not on terminal content.

## Architecture decisions

User decisions 2026-09-28:
- D1: new code in local SwiftPM packages (Packages/macOS/CmuxNext), sibling Xcode target `cmux-next`; on this branch the `cmux` scheme builds it, `cmux-legacy` keeps the old app. Delivery = one tagged app the user can dogfood with all changes in.
- D2: long-lived branch `feat-cmux-next`, sub-branches merge into it.
- D3: CEF fork + prebuilt artifact go to a new repo (manaflow-ai/cef, private until user says otherwise).
- D4: Cloud and iOS must keep working seamlessly. They may be rewritten so both ride cmux-tui (Cloud VMs already run the daemon; iOS should attach to the same daemon tree).
- Deployment target macOS 26 for cmux-next (flagged: appcast needs minimumSystemVersion before any release).

Design docs: cmux-tui-contract.md, inventory.md, browser.md, shell.md.

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
