# cmux-next coordination ledger

One line per landed change to a shared surface (daemon protocol or state, layout ops, store/projection, CLI grammar, build/CI). Newest first. Format: `YYYY-MM-DD <sha> <area>: <what changed> (owner)`. Read this before you change a shared surface.

## Active streams (who owns what)

- Rust `cmux` CLI, compat-layer removal, daemon v2 state ops in `cmux-tui-core::state`: session feat-cmux-next-99, PR #16174 (branch feat-cmux-next-acpmux).
- Ownership rewrite (session host / workspace store / client view state, strict projection, intent log + universal transaction echo, daemon-owned workspace lifecycle): plans/cmux-next/ownership.md (design; code on hold until decisions).
- Typed LayoutOp, daemon tab-conservation validation, proptest, TLA+ model (plans/cmux-next/formal/): tab-loss agent.
- Sticky column (layout document fields + app) and strip scrollbar: sticky-column lead.
- Federation daemon (remote-terminal tabs, detached create, terminal.project delta): branch feat-cmux-next-federation-tui-r8.
- Upstream cmux-tui test fixes (kitty-shell-cwd, clear-history test env, ReconnectPolicy maximum_duration): branch feat-cmux-next-tui-upstream-fixes.
- cmux-tui pin cuts: the next cut belongs to the Rust CLI session (feat-cmux-next-99), from #16174's merged tree. Pending for it: terminal-command-journal-v1 (6ed2890368a, review fixes dc6227eb6ce) and the federation daemon caps when they land. The daemon-features agent is finished; all its daemon commits are in pin 63626e2d798.

## Landed

- 2026-10-01 9033c0e089a control/app: action.run `origin` (user|cli|mcp|script|remote, absent = cli) and `focus`; ActionInvocation.origin/focusRequested; AppServices.viewChangeAllowed; DropRevealPolicy (view change after a user drop or move; Option files away); WindowActivation.presentBehind; WindowManager.claim(select:) with quiet pending claims (review fixes e9ed036b585). Gap: the check is read by the move handlers, not yet central for every action; no descriptor `focuses` flag (Rust CLI session adds it) (tab-loss agent)
- 2026-10-01 7b80809f580..43478eb63bd+ layout/app: sticky columns (app side): LayoutColumn.sticky, LayoutIntent.setColumnSticky (validated, no optimistic copy), daemon client SetColumnStickyRequest + columns[].sticky decode, capability sticky-columns-v1 in awaitingPin (actions disabled until a pin includes it), debug.sticky, layout.stripScrollbar setting; daemon side lands from branch feat-cmux-next-sticky-tui (sticky-column lead)
- 2026-10-02 dc6227eb6ce daemon: terminal-command-journal-v1 review fixes: command line from Ghostty semantic input cells (Terminal::latest_input_text; no B-cursor rows), one bounded journal worker (queue 256) and 10 commands/s per terminal, cmux_shell reserved (append refused, not installable as plugin), producer install never downgrades, cwd as local path (36b58da0388..dc6227eb6ce, red run 36948355561, green linux run 36948357857; macOS jobs refused by runner toolchain 1.98.1). Gap: the switch is one daemon-wide value any trusted local client sets, and turning it off keeps written records (history agent)
- 2026-10-01 6ed2890368a daemon: terminal-command-journal-v1: local-admin `set-terminal-command-history {enabled}` (off by default and after every start), journal kind `shell.command.finished` from reserved producer `cmux_shell`; app setting `history.terminalCommands` (default off) syncs it (30865b694a1); capability awaitingPin in the app until a pin carries it (history agent)
- 2026-10-01 6b375581207, 3a1cf81bf1f build: cmux-remote/cmux-tui tests set ReconnectPolicy.maximum_duration after main merge 308a1d2e7c9 (history agent)
- 2026-10-01 ae180e80019 keys: Cmd-[ / Cmd-] act only in browser contexts; consumed elsewhere (BrowserChordTable.browserOnlyActions); Go Back/Forward on Ctrl-Cmd-Left/Right (history agent)
- 2026-10-01 92cab8d60ba store: DaemonStore.restoredTabIDs (first snapshot per connection and the launch snapshot) decides restored vs new browser tabs for page history (history agent)
- 2026-10-01 795df9cb0c3 app (interim): closed tabs, screens and workspaces listed from what the app mirror saw close; to be replaced by #16174 store ops closed.list / closed.reopen (state-resources-v1); no more closed-history inference is added in the app (history agent)
- 2026-10-01 db4ea257a73 store/projection: DaemonStore.whenApplied (echo, write barrier, snapshot; after the batch; all on disconnect), TabDragLifecycle.release on every drag end, resolver own place = no operation (TabDragContext sourceStripID/sourceIndex/sourceGroupID), debug.desync invariant DP1, plans/cmux-next/layout-invariants.md (tab-loss agent)
- 2026-10-01 270b069f273 CLI/control: `ActionDescriptor.waitsForResult` (JSON `waits_for_result`) and a 40 s `action.run` limit with `wait` (ControlMethod.withLimit) for accounts.connect/remove; socket methods accounts.list, coderouter.claude_upstream.*, coderouter.machines, coderouter.accounts.list (fdb08f68315); the Rust CLI port must add accounts.show/refresh/reauthenticate/connect/remove to cliActionIDs (CodeRouter agent)
- 2026-10-01 63626e2d798 build: pin cmux-tui f39636c811a (verified run 36814040800, artifacts 36814037092); optional gains notification-source-v1, terminal-shell-args-v1, launch-snapshot-v1, personal-terminals-v1, browser-profiles-v1; awaitingPin keeps remote-terminal-tabs-v1, detached-terminals-v1 (daemon-features agent)
- 2026-10-01 a88885ccb59 daemon: launch-snapshot-v1, launch-snapshot.json next to the registry, identify.launch_snapshot_path; app draws it before connect (d5fad6dfe4a) (daemon-features agent)
- 2026-10-01 dfc7bc05347 daemon: terminal-shell-args-v1, `shell_args` on new-tab/split/new-pane/new-pane-right/create-terminal; app sends bash --posix / nushell --execute (a84f244800d) (daemon-features agent)
- 2026-10-01 52ff0d719e7 daemon: notification-source-v1, `source` on notify/event/tab marker; daemon parses OSC 9/777/99 from every terminal; app path removed (facce30063b) (daemon-features agent)
- 2026-10-01 0f367840d96 build: removed legacy CmuxControlSocket/Coordinator files that main merge 308a1d2e7c9 brought back (coordinator)
- 2026-10-01 383bdf1a9a1 store: DaemonStore applies `tab-changed` pane moves from the daemon (tear-off desync) (tab-drag agent)
- 2026-10-01 f6283380c5c app: all window paths use WindowPlacement.containedOnTestScreen; debug.mouse events are not user input (tab-drag agent)
- 2026-10-01 155f8d0fb2b CLI: federation `--all-sessions`, local-only default, qualified refs to the app (federation agent)
- 2026-10-01 d7e22f6a1c7 app: debug.mouse `scroll` goes to the view under the point (synthesized wheel events had no window); debug.themes edge_fades reports top_down and mask alphas (edge-fade agent)
