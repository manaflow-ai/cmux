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

Done on `feat-cmux-next-acpmux` (PR 16174): acpmux in the workspace; `cmux acp` (all
three parts); app scopes and action verbs; app and daemon discovery. Build, 1762 cmux-tui
unit tests, the acpmux suite and clippy pass on a Linux Testbox; macOS-only discovery
code compiles only in macOS CI. `terminal_host_recovery::closing_one_hundred_terminals…`
misses its 15 s budget on the Testbox at the base commit too (timing flake, not this
change).

## Remaining

1. Cutover: bundle the cmux-tui binary as `cmux` with `cmux-tui` and `acpmux` symlinks;
   delete `CLI/`, `cmuxCLITests/`, the `cmux-cli` target, `CmuxNextControl/Compat/` and
   `CMUXAgentLaunch/ACPHost`; replace `cli-compat-e2e.py` with an e2e suite for the new
   surface; rewrite the skills and docs that name old verbs in the same change.
2. Frontend browser routing: resolve a browser tab through the daemon; page commands
   (navigate, eval, snapshot, click, fill) for a frontend-owned tab go to its app. Later
   the daemon can forward them, so a CLI on another machine reaches the app too.
3. App windows get typed ids (`win_<32 hex>`) in the control surface; today they are
   bare lowercase UUIDs (stable, but not typed like every other id).
4. Nightly and release apps both use daemon session `cmux-app` when untagged
   (`DaemonLauncher.sessionName`), so a nightly and a release running together share one
   session. Give each channel its own session.
5. acpmux CLI output is English only; the rest of `cmux` is English and Japanese.
