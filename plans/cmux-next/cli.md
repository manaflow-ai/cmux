# cmux next: the `cmux` CLI in Rust

Plan for replacing the Swift CLI (`CLI/`, about 106k lines, target `cmux-cli`) and the
app-side compat layer (`CmuxNextControl/Compat/`, see cli-compat.md) with the Rust
cmux-tui binary. Decisions by the user on 2026-09-30 unless marked (agent).

## Decisions

- C1. The CLI is Rust. No Swift code ships in the CLI.
- C2. One binary. The cmux-tui binary ships as `Contents/Resources/bin/cmux`, with
  `cmux-tui` and `acpmux` as symlinks to it; `argv[0]` of `acpmux` runs acpmux. Every
  piece has one version. acpmux is linked into it as a library.
- C2a (user, revised). The base is cmux-tui's existing resource CLI (`cli.rs`,
  `cli/command.rs`), not a new crate: it already is the noun-first grammar over
  `cmux.protocol/2`, localized, with public-id selectors (spec/resource-api-v2.md "CLI").
  A new crate would have duplicated it and forced a change to the 42 places where
  cmux-tui, cmux-tui-core, cmux-remote and cmux-pty start their own executable.
- C3. No compatibility with the old CLI. Old verbs, flags, `workspace:N` style refs and the
  v1 text protocol are gone. `CmuxNextControl/Compat/` is deleted at cutover.
- C4. `cmux acp` has three parts: the acpmux session verbs, an ACP agent on stdio for
  editors, and `cmux acp open` to show a session in the app.
- C5. acpmux reaches cmux-next by merging PR 15512 into a branch off `feat-cmux-next`,
  not through `main` (PR 15512 closed). The native chat pane prototype (PR 15521)
  targets deleted legacy code and is rebuilt for cmux-next separately.
- C6. Bare `cmux` opens the TUI (attach or start the session), as cmux-tui does now.
- C7 (user). Every object has a unique, stable identifier that survives app and daemon
  restarts, terminals included. The CLI uses the daemon's public ids (`ws_`, `screen_`,
  `pane_`, `tab_`, `term_`, `browser_`, `split_`, `notification_`, `agent_`), all
  persisted in the resource store, and speaks only `cmux.protocol/2`, whose selectors
  take them. Raw v12 per-boot numeric handles never reach the CLI.
- C8 (user). The Swift ACP host (`CMUXAgentLaunch/ACPHost`, PR 15976) is deleted at
  cutover; its author was told on the PR. acpmux already speaks ACP.
- C9 (agent). Route by the owner of each object, not by the frontend. Windows exist only
  in the app. A cmux-tui browser (`browser_…`) is daemon-owned; a Swift-app browser tab is
  frontend-owned (the daemon holds its placement, the app holds the page).

## Owners and routing

| Owner | Scopes | Works with the app closed |
| --- | --- | --- |
| cmux-tui daemon (`cmux.protocol/2`) | machine, session, client, workspace, screen, pane, tab, terminal, browser (daemon-owned), notification, agent, sidebar, projection | yes |
| app control socket (JSON lines, `{"id","method","params"}`) | `app`, `window`, `action`, `settings`, `events`, and any `<noun> <verb>` that is an app action's CLI name | no |
| acpmux daemon | `acp` | yes (started on demand) |

Discovery (`app_identity.rs`):

- App socket: `--app-socket`, then `CMUX_SOCKET_PATH`/`CMUX_BUNDLE_ID`/`CMUX_TAG` (set in
  the app's terminals), then the app bundle that contains the executable (Info.plist
  `CFBundleIdentifier` and `LSEnvironment.CMUX_TAG`). The path table mirrors
  `ControlSocketPath`; the Rust tests pin it.
- Daemon socket: `--socket`/`--session`, `CMUX_TUI_SOCKET`, then (macOS) the app's session
  `cmux-app[-tag]` under the Darwin per-user temp directory the app starts it with, then
  cmux-tui's `main`.
- acpmux: `ACPMUX_HOME`, else `~/.acpmux/tags/<tag>` under `CMUX_TAG`, else `~/.acpmux`
  (shared with a standalone acpmux). The home is passed to the daemon it starts.

The app's action registry is the list of app verbs: `cmux app new-window` and
`cmux workspace move-to-window --target ws_…` run the action with that CLI name. The mux
grammar is tried first; only words it rejects and the app reports as an action run there.

## `cmux acp`

- Session verbs: every acpmux command (`ls`, `new`, `send`, `attach`, `wait`, `session …`,
  `daemon …`, `web`). Bare `cmux acp` opens the acpmux TUI. acpmux's CLI moved from its
  binary into `acpmux::cli::entry` for this; a started daemon reports readiness through
  its `--ready-fd` pipe (no connect retry loop).
- `cmux acp stdio [-m HARNESS[/MODEL]] [--policy P] [--effort E] [--preset P]`: an ACP
  agent on stdin/stdout for editors (Zed: `"command": "cmux", "args": ["acp", "stdio",
  "-m", "claude"]`). It relays newline-delimited JSON-RPC to the daemon, which speaks
  plain ACP, and adds the flags as defaults to each `session/new`.
- `cmux acp open NAME [--pane ID]`: runs `cmux acp attach NAME` in a new tab of the pane
  (`pane <id|current> run`). Switches to the native chat pane when the app has one.

## Agent hooks

cmux-tui already installs and runs agent hooks (`agent hooks`, `agent_hook_install.rs`,
`report-agent` into the daemon's durable agent projection). The Swift hook machinery is
not ported. Agents that run through acpmux need no hooks.

## Status

On `feat-cmux-next-acpmux` (PR 16174):

- acpmux in the cmux-tui workspace; `cmux acp` (session verbs, `stdio`, `open`).
- App scopes and action verbs; app and daemon discovery.
- `browser.page.*` app methods for app browser tabs; `cmux browser tab_…|page …`.
- Cutover: the app bundles the cmux-tui binary as `bin/cmux` with `cmux-tui` and `acpmux`
  symlinks. Deleted: the `cmux-cli`/`cmuxCLITests` targets, `CLI/`, the ten CLI-only
  packages, `CmuxNextControl/Compat` and `CmuxNextApp/Compat`, the agent wrapper scripts
  (not on the PATH of cmux-next terminals; cmux-tui's agent shim replaces them).
- `action.run` targets take public ids or unique prefixes (`PublicIDTargetResolver`);
  the topology carries each workspace's `ws_` id.
- Web docs keep the old CLI until cmux-next ships (user). Repo skills and docs follow the
  new grammar.

Verification: Linux Testbox build, clippy and tests (1762 cmux-tui unit tests, acpmux);
`swift test` CmuxNextControlTests (68). `terminal_host_recovery::closing_one_hundred…`
misses its 15 s budget on the Testbox at the base commit too (timing flake).

On `feat-cmux-next-cli-state` (state-ownership.md step D, CLI part):

- Curated commands for the v2 state resources: `workspace <sel> update`,
  `workspace [<sel>] status|progress|log`, `workspace placement list`, `workspace create
  --ephemeral`, `tab <sel> pin|unpin|zoom|update`, `tab group …` and `tab group saved …`
  over `tab_group.*`/`saved_tab_group.*`, `room …`, `screen <sel> update|pin|unpin|move`,
  `screen group …`, `closed list|<id> reopen`. New curated scopes `room` and `closed`.
- Rooms and groups take an id or exact name; status/progress/log without a selector
  target the caller's workspace. Both resolve with reads on the request's own connection
  before it is sent (`cli/resolve.rs`), so the request carries ids only.
- Still private (no v2 operation): `tab group <g> split|column|new-workspace|unsave`.
- Verification: Linux Testbox build, clippy `--all-targets -D warnings`, fmt; cmux-tui
  1794 unit tests, cmux-tui-core 1494, integration suites green except the two known
  timing flakes (`session_shutdown_exits_an_interactive_detached_owner_client`,
  `closing_one_hundred_terminals…`).

On `feat-cmux-next-browser-input` (browser group 4):

- `browser.page.press|hover|scroll|scroll_into_view|select|check|uncheck` and the CLI verbs
  `press KEY [--selector S]`, `hover`, `scroll [SELECTOR] [--dx N] [--dy N]`,
  `scroll-into-view`, `select SELECTOR VALUE`, `check`, `uncheck`: page scripts like
  `click`, with the old app's events and errors (`not_checkable`, `disabled`,
  `not_changed`). `press` is the old app's page-world fallback for every key, with its key table
  (`BrowserPageKey`: names, punctuation codes, legacy keyCode, location; unknown names pass
  through); the old app replayed mapped keys as trusted native
  events, which needs engine input support (not done). Selector actions do not retry for
  an element that has not appeared yet (browser group 1 adds `wait` for that).

## Remaining

1. App windows get typed ids (`win_<32 hex>`); today they are bare lowercase UUIDs.
2. Nightly and release apps both use daemon session `cmux-app` when untagged
   (`DaemonLauncher.sessionName`); give each channel its own session.
3. acpmux CLI output is English only; the rest of `cmux` is English and Japanese.
4. Browser waits, screenshots, cookies and downloads have no new-CLI equivalent yet
   (the compat layer had partial ones). Workspace status/log/progress are done.
5. `Resources/Localizable.xcstrings` (987 `cli.*` keys plus legacy app keys) is probably
   unused by the cmux-next app; prove it and remove it from the Resources phase.
6. The daemon forwards page commands for frontend browser tabs to their app, so a CLI on
   another machine reaches them.
7. The daemon's `cmux.protocol/2` selectors take full ids only; unique prefixes work only
   for app action targets and `browser tab_…`. Add prefix resolution to the daemon
   selector (one snapshot, `selector.ambiguous` with candidates) so C7 holds everywhere.
8. An app action whose target matches nothing still reports `ran: true` (for example
   `workspace rename --target ws_zzz`). Handlers must fail with `not_found`; the
   resolver passes unknown ids through so objects the snapshot has not seen yet work.
9. `current` means the session's focused object, not the caller's terminal; the caller's
   own terminal is `$CMUX_TUI_TERMINAL_ID`.
