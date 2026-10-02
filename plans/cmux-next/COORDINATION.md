# cmux-next coordination ledger

One line per landed change to a shared surface (daemon protocol or state, layout ops, store/projection, CLI grammar, build/CI). Newest first. Format: `YYYY-MM-DD <sha> <area>: <what changed> (owner)`. Read this before you change a shared surface.

## Active streams (who owns what)

- Rust `cmux` CLI, compat-layer removal, daemon v2 state ops in `cmux-tui-core::state`: session feat-cmux-next-99, PR #16174 (branch feat-cmux-next-acpmux).
- Ownership rewrite (session host / workspace store / client view state, strict projection, intent log + universal transaction echo, daemon-owned workspace lifecycle): plans/cmux-next/ownership.md (design; code on hold until decisions).
- Typed LayoutOp, daemon tab-conservation validation, proptest, TLA+ model (plans/cmux-next/formal/): tab-loss agent.
- Sticky column (layout document fields + app) and strip scrollbar: sticky-column lead.
- Federation daemon (remote-terminal tabs, detached create, terminal.project delta): branch feat-cmux-next-federation-tui-r8.
- Upstream cmux-tui test fixes (kitty-shell-cwd, clear-history test env, ReconnectPolicy maximum_duration): branch feat-cmux-next-tui-upstream-fixes.
- cmux-tui pin cuts: daemon-features agent.

## Landed

- 2026-10-01 0f367840d96 build: removed legacy CmuxControlSocket/Coordinator files that main merge 308a1d2e7c9 brought back (coordinator)
- 2026-10-01 383bdf1a9a1 store: DaemonStore applies `tab-changed` pane moves from the daemon (tear-off desync) (tab-drag agent)
- 2026-10-01 f6283380c5c app: all window paths use WindowPlacement.containedOnTestScreen; debug.mouse events are not user input (tab-drag agent)
- 2026-10-01 155f8d0fb2b CLI: federation `--all-sessions`, local-only default, qualified refs to the app (federation agent)
