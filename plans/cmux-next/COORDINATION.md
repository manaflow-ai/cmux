# cmux-next coordination ledger

One line per landed change to a shared surface (daemon protocol or state, layout ops, store/projection, CLI grammar, build/CI). Newest first. Format: `YYYY-MM-DD <sha> <area>: <what changed> (owner)`. Read this before you change a shared surface.

## Active streams (who owns what)

- Rust `cmux` CLI, compat-layer removal, daemon v2 state ops in `cmux-tui-core::state`: session feat-cmux-next-99, PR #16174 (branch feat-cmux-next-acpmux).
- Ownership rewrite (session host / workspace store / client view state, strict projection, intent log + universal transaction echo, daemon-owned workspace lifecycle): plans/cmux-next/ownership.md (design; code on hold until decisions).
- Typed LayoutOp, daemon tab-conservation validation, proptest, TLA+ model (plans/cmux-next/formal/): tab-loss agent.
- Sticky column (layout document fields + app) and strip scrollbar: sticky-column lead.
- Federation daemon (remote-terminal tabs, detached create, terminal.project delta): branch feat-cmux-next-federation-tui-r8.
- Upstream cmux-tui test fixes (kitty-shell-cwd, clear-history test env, ReconnectPolicy maximum_duration): branch feat-cmux-next-tui-upstream-fixes.
- cmux-tui pin cuts: the next cut belongs to the Rust CLI session (feat-cmux-next-99), from #16174's merged tree. Pending for it: terminal-command-journal-v1 (6ed2890368a) and the federation daemon caps when they land. The daemon-features agent is finished; all its daemon commits are in pin 63626e2d798.

## Landed

- 2026-10-01 (follow-up to 85e88d62e91) CI/CLI: scripts/cmux-next/check-no-swift-cli.sh in cmux-next.yml fails when CLI/, cmuxCLITests/, cmuxCLITestSupport/, the Compat dirs, CmuxFoundation, Resources/Localizable.xcstrings or a cmux-cli target come back (Swift CLI freeze); `cmux history|bookmark list|search`, `cmux accounts list`; action flags map to camelCase arguments, a bare flag is true (`cmux app quit --keep-sessions`); accounts, history, quit, bookmark, browser-profile, theme, remote actions marked cli (feat-cmux-next-99)
- 2026-10-01 bd434071dc0 daemon/app: `state-resources-v1` in identify; the app gates the v2 state paths and `session.events` on it (no probe) (feat-cmux-next-99)
- 2026-10-01 bd434071dc0 daemon: screen metadata, order and screen groups have one storage (screen_store tables) and one commit path (mux/state_screens.rs) for the raw screen-metadata-v1/screen-groups-v1 commands and the v2 screen.update/move, screen_group.create/add_screens/remove_screens/update/ungroup; a registry from the state-resources daemon (screen_state, groups by public workspace id) migrates at open (feat-cmux-next-99)
- 2026-10-01 bd434071dc0 daemon v2 state ops (families: workspace metadata/ephemeral/status/progress/log, tab pin/state/groups, saved tab groups (personal, room-scoped), personal workspace groups and placements, rooms, screens and screen groups, closed history); `session.events` carries `state_upsert`/`state_delete` and decorated `extra` fields (feat-cmux-next-99)
- 2026-10-01 bd434071dc0 CLI: the Rust cmux-tui binary is `cmux` (bin/cmux, cmux-tui and acpmux symlinks); Swift CLI, compat layer and wrappers deleted; curated noun-first grammar over cmux.protocol/2 plus app actions with `cli: true`; ids are daemon public ids (ws_/screen_/pane_/tab_/term_, unique prefix for app targets) with an optional `<session>:` qualifier; `action.run` waits by default, carries an idempotency key, accepts `after` (read barrier) (feat-cmux-next-99)
- 2026-10-01 bd434071dc0 app: Recently Closed, `history.list kind:closed` and history reopen read the daemon's closed history when it serves state-resources-v1; the app's closed-tab tracker skips those daemons (feat-cmux-next-99)
- 2026-10-01 270b069f273 CLI/control: `ActionDescriptor.waitsForResult` (JSON `waits_for_result`) and a 40 s `action.run` limit with `wait` (ControlMethod.withLimit) for accounts.connect/remove; socket methods accounts.list, coderouter.claude_upstream.*, coderouter.machines, coderouter.accounts.list (fdb08f68315); the Rust CLI port must add accounts.show/refresh/reauthenticate/connect/remove to cliActionIDs (CodeRouter agent)
- 2026-10-01 63626e2d798 build: pin cmux-tui f39636c811a (verified run 36814040800, artifacts 36814037092); optional gains notification-source-v1, terminal-shell-args-v1, launch-snapshot-v1, personal-terminals-v1, browser-profiles-v1; awaitingPin keeps remote-terminal-tabs-v1, detached-terminals-v1 (daemon-features agent)
- 2026-10-01 a88885ccb59 daemon: launch-snapshot-v1, launch-snapshot.json next to the registry, identify.launch_snapshot_path; app draws it before connect (d5fad6dfe4a) (daemon-features agent)
- 2026-10-01 dfc7bc05347 daemon: terminal-shell-args-v1, `shell_args` on new-tab/split/new-pane/new-pane-right/create-terminal; app sends bash --posix / nushell --execute (a84f244800d) (daemon-features agent)
- 2026-10-01 52ff0d719e7 daemon: notification-source-v1, `source` on notify/event/tab marker; daemon parses OSC 9/777/99 from every terminal; app path removed (facce30063b) (daemon-features agent)
- 2026-10-01 0f367840d96 build: removed legacy CmuxControlSocket/Coordinator files that main merge 308a1d2e7c9 brought back (coordinator)
- 2026-10-01 383bdf1a9a1 store: DaemonStore applies `tab-changed` pane moves from the daemon (tear-off desync) (tab-drag agent)
- 2026-10-01 f6283380c5c app: all window paths use WindowPlacement.containedOnTestScreen; debug.mouse events are not user input (tab-drag agent)
- 2026-10-01 155f8d0fb2b CLI: federation `--all-sessions`, local-only default, qualified refs to the app (federation agent)
