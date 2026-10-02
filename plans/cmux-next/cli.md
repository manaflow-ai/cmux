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

On the merge of `feat-cmux-next` (2026-10-01):

- Screen metadata, order and screen groups have one storage, `feat-cmux-next`'s
  (`screen_presentation`, `screen_groups` keyed by workspace key, `screen_group_members`,
  `saved_screen_groups`), and one commit path (`mux/state_screens.rs`) that the raw
  `screen-metadata-v1`/`screen-groups-v1` commands and the v2 `screen.update`,
  `screen.move` and `screen_group.*` operations share. A registry written by the
  state-resources daemon (`screen_state`, groups by public workspace id) moves into it
  at open. Every screen commit restates changed screens and groups on `session.events`.
- The daemon advertises `state-resources-v1` in `identify`; the app opens `session.events`
  and takes the v2 paths only then (`DaemonStore.servesStateResources`), with no probe.
- `cmux history list|search` and `cmux bookmark list|search` read the app's
  `history.list`/`bookmark.list`; the incoming bookmark, history, theme, browser profile,
  accounts and remote actions are marked for the CLI.

On the merges of `feat-cmux-next` (2026-10-02, owner after feat-cmux-next-99):

- Five merges of `feat-cmux-next`; Leo Li's review fixes (`feat-cmux-next-acpmux-onhis`);
  `feat-cmux-next-followup-rust` (v2 state ops in `cmux-tui-core::state`, window records
  `window_record.*` with owner = install id and CAS, browser record owner, atomic
  `workspace.create {ephemeral}`, kept tabs in the state module, closed-history test) and
  `feat-cmux-next-followup-rust-cli` (`--all-sessions`, `<session>:` ids, coderouter verbs).
- `ActionDescriptor.cli` derives from the action surface plan (`ActionSurfaceCatalog.cliNamed`);
  `cliActionIDs` is gone. `cli::tests::action_surface_parity` (Rust) fails when an offered app
  CLI name parses in the mux grammar first. The nine it found are daemon verbs, so the app
  actions are `ownerVerb` CLI exemptions; `tab.focus` is `cmux app show-tab --target tab_…`.
- God-file budget: every cmux-tui file and Swift type is within its baseline (Rust split,
  `StateResourceClient`, `SessionStateStore`, `WindowRecordSaver`, `TerminalFontScale`).
- Fixes found by the tagged preflight: ids derived inside an action run use the UUIDv4
  layout (cmux-tui refused version 8 terminal ids, so `cmux tab new` failed); `cmux acp`
  in a tagged bundle without `CMUX_TAG` uses the bundle's acpmux home; a kind or `name:`
  before `:` is not a session (the `name:` escape hung the hosted tests); tab-less
  terminals carry `lifecycle` on every published record.

On `feat-cmux-next-mcp` (PR into `feat-cmux-next-acpmux`):

- `cmux mcp serve` and `cmux mcp tools [--json]`: MCP tools from the v2 catalog and the
  app's CLI actions, over the CLI's own transport (mcp.md). Off unless cmux.json sets
  `mcp.enabled`.

## Numeric refs replacement

The old CLI's refs and selector flags have no Rust equivalent; `cmux` takes the
daemon's public ids (C7). Discover them with `cmux workspace list`, `cmux screen list`,
`cmux pane list`, `cmux tab list`, `cmux terminal list` (add `--json` for the full
records) or `cmux window list` for app windows.

| Old form | New form |
| --- | --- |
| `workspace:N`, `--workspace workspace:N` | `ws_<32 hex>` or a unique prefix, as the selector (`cmux workspace ws_1a2b update …`); `current` for the session's focused workspace |
| `pane:N`, `--pane`/`--panel pane:N` | `pane_…` or a unique prefix (`cmux pane pane_9f split --right`) |
| `surface:N`, `tab:N`, `--surface …` | `tab_…` for the tab, `term_…` for its terminal (`cmux terminal term_77 write --text …`) |
| the caller's own terminal (`--surface` default) | `$CMUX_TUI_TERMINAL_ID` (set in every cmux terminal); `current` is the session's focused object |
| `window:N`, `--window …` | the app window id from `cmux window list` (`win_…` once window ids are typed, Remaining 1) |
| `build-box:workspace:N` | `--session build-box` with a public id, or the qualified form `build-box:ws_…` once qualified ids land (Remaining 12) |
| names (`--name build`) | exact names where a scope accepts them (rooms, groups); otherwise look up the id with `list` |

## Ports from main and feat-cmux-next

Every Swift CLI, compat-layer and wrapper change since the branch point
(`git log 6ae6960d8d1..origin/feat-cmux-next -- CLI/ Resources/bin/ …/Compat`), and
the CLI requests that came with the merge, with the decision taken.

| Commit | Author | Change | Decision |
| --- | --- | --- | --- |
| 270b069f273 | Lawrence Chen | accounts: CLI waits for CodeRouter | ported: `accounts show|refresh|reauth|connect|remove` are app actions with `cli: true`; connect/remove `waits_for_result`, the CLI reads for 45 s; `cmux rpc accounts.list` is now `cmux accounts list` (`accounts.list`) |
| fdb08f68315, 803d2877c33 | Lawrence Chen | `cmux coderouter status|machines|claude …`, `cmux cr …` | deferred: needs `coderouter` app scope over `coderouter.claude_upstream.*`, `coderouter.machines`, `coderouter.accounts.list` (secrets from env/stdin/TTY only) and exec of the bundled `bin/coderouter` with `CMUX_*` removed; the native handoff waits for PR 10194 |
| c900ee9bad1 | Leo | Search All Windows (⌥⌘F) | not needed: a palette page; scripts read text with `terminal <sel> screen read`/`history read` |
| 137e95e5f83 | Leo Li | namespace types refactor | not needed: compat-internal |
| 73ae48025f9 | nightcityblade | browser JSON flags in help | not needed: Swift browser verbs; `cmux browser` help is cmux-tui's |
| 2bb742d3705, a4e862d030f, 8aa9b5c995c | Alejandro Florez, Leo | Codex/OpenCode auto-naming | not needed: the Swift hook auto-naming is not ported (Agent hooks) |
| 86230a59c43 | Leo | custom sidebar templates | not needed: cmux-next has no custom sidebar |
| 2f574d677c4, 24f1ee0007f | Abdulaziz Albahar, Lawrence Chen | Codex transcript monitor | not needed: cmux-tui's agent projection reports agent state |
| a20ed74ca17 | Austin Wang | `new-window --name` | deferred: add a `name` argument to `newWindow` (`cmux app new-window --name`) |
| 64bb5e9f3fb, 974d0a0c941, b3d644ba873, e94800760c4 | Austin Wang, Leo, Lawrence Chen | legacy app model, updater revert, guarded close UX, Cmd-hold pills | not needed: legacy app |
| fa7fa0aa2c0, f627d1fb076 | Leo, Alejandro Florez | tmux compat options, extra send-key operands | not needed: no tmux compat (C3); the Rust parser rejects extra operands |
| 2e75b7ca209 | Lawrence Chen | bookmark verbs | ported: `bookmark list|search` (`bookmark.list`); `bookmark add-page|add|new-folder|open|open-in-new-tab|open-all|edit|move|remove|import|export` are app actions with `cli: true` |
| 91fca8c8ab4 | Austin Wang | `cmux pr` handoff | not needed: cmux-next has no PR sidebar link |
| 448f7ab1c2b | Lawrence Chen | notification source | ported: the daemon stamps `source` (`notification-source-v1`); `notification create` sends `cli` |
| 155f8d0fb2b, c07e6d9f505, 2f3e13d8ce0 | Lawrence Chen | federation: local default, `--all-sessions`, session-qualified refs, send/read-screen on remote-terminal tabs | partly: lists act on the one session the CLI addresses (`--session` picks another) and `cmux --session S terminal term_… write|keys|screen read` reaches a remote terminal over v2; deferred: `--all-sessions`, `<session>:` qualified ids (resolve to `--session` in `cli/resolve.rs`), and tab-to-terminal routing, until the remote tab fields are in the merged tree |
| federation-tui-r8 (not landed) | federation agent | create-terminal {detached}, remote-terminal tab create/update/snapshot, set-terminal-keep | deferred: waiting for v2 ops (terminal.create {detached}, tab.create_remote_terminal, tab.update_remote_terminal, tab.remote_terminal_snapshot, terminal.update {keep}); then `cmux terminal create --detached [--keep]`, `cmux tab create remote-terminal --session S --terminal term_…`, `cmux terminal <term_> keep|unkeep` |
| 17dee8d2801 | Lawrence Chen | Open Terminal on Machine Here | ported: `remote open-terminal-here` (`cli: true`) |
| 63ae925e97f | Lawrence Chen | history queries | ported: `history list|search [--kind] [--range] [--limit]` (`history.list`); `history back|forward|last|locations|closed|show|search-in-palette|resume|reopen|clear` and `layout undo` run as app actions (`cli: true` for show, resume, reopen, clear, layout undo) |
| 6ed2890368a | Lawrence Chen | terminal command history (`set-terminal-command-history`) | deferred: no CLI verb yet (app setting `history.terminalCommands`) |
| c8779bdd6f3 | Lawrence Chen | `tab new` of the focused pane's kind | ported: `tab new` (`newTab.sameKind`) and `tab new-terminal` (`newSurface`) are app actions with `cli: true` |
| quit flags | Lawrence Chen | `app quit --keep-sessions|--end-sessions|--end-everything` | ported: `quit` is `cli: true`; a bare flag is true and flags map to camelCase arguments |
| 43478eb63bd | sticky-column lead | `column make-sticky|make-sticky-left|unstick|toggle-sticky-overlay`, `settings toggle-column-scrollbar` | ported: app actions with `cli: true`; `column` reaches the app fallback and `settings <verb>` other than get/set/unset falls through to actions; `sticky-columns-v1` stays awaiting the pin |
| ca831d42829, fa5e63276d5, 61128c6ca92, 7ba97404a02 | Lawrence Chen, Leo, Austin Wang | compile fix, test timing, SSH/Mosh launcher, pool VMs | not needed: Swift CLI internals and verbs outside the curated surface |
| 5e33b84e085, 258c2ee9b11 | Leo | `cmux agent message` (and over the SSH relay) | deferred: Remaining 10 |
| 7bce471a35f | Leo | `cmux agent hibernate|wake` | ported: `tab hibernate|wake` (`hibernateTab`/`wakeTab`, `cli: true`) |
| 90d931ab9c8 | Lawrence Chen | surface size verbs | not needed: compat message |
| ef3e6588f55, 555d7507823, 6606ca2cf76, ea6e02be168 | Leo | Claude hook sessions, auto-resume, notification ring, hook activity | not needed: Swift hook machinery is not ported (Agent hooks) |
| 8216c54b526 | Leo | refuse `send` over an agent prompt draft | deferred: a daemon guard on `terminal.input.write` from the agent projection's prompt state |
| 258501989df, 5605b57c1f6 | Lawrence Chen | Sentry redaction, no `--yolo` from transcript evidence | not needed: no Sentry or restore in the Rust CLI; a future restore keeps the rule (paths inside `CODEX_HOME` only, no full-access flags from evidence) |
| df28c39c9c7 | Abdulaziz Albahar | iOS agent Feed | not needed for the CLI |
| d453f3aaf7d | Leo | `cmux shot|record`, `docs capture` | deferred: app window capture control methods and Rust verbs (Remaining 4) |
| 10e78b5cf6f | Leo | setting actions, `cmux config set` | ported: `settings get|set|unset`; setting actions run as `settings toggle-setting` |
| d13dde39006 | Lawrence Chen | diff viewer review labels | not needed: no diff viewer CLI |
| 7b2979e6345, 5f7699ecd26, 6eaa946e7b5 | Lawrence Chen | team invites and roster verbs | deferred: app-owned team service; add app control methods and an `auth team` scope |

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
10. `cmux agent message` (Leo Li's PR 16430 owns it) has no port yet: it needs a daemon v2 message operation, a Rust verb and hook
    entries in `agent_hook_install.rs`.
11. `send`/`read-screen` on a remote-terminal tab need the daemon side of
    `remote-terminal-tabs-v1`, which is not in cmux-tui yet.
12. Done: session-qualified ids (`build-box:ws_…`) and `--all-sessions`.
13. Done: `cmux tab new` reports the created tab and terminal (an earlier `created: []`
    was a slow snapshot, not a missing path).
14. With an explicit `--app-socket` but a different app's `CMUX_*` environment, the daemon
    is found from the environment, not from the named app.
15. v2 `session.identify` and `capabilities` on `client.metadata.update` (SDK clients
    still fall back to raw v12 for both).
16. `cmux tab search [--query Q] [--json]` and MCP `tab_search` over the app's read-only
    `tabs.search` (PR 16796), and a session-host `foreground_process` per terminal (the
    PTY's foreground process name) so the search matches vim or htop; next pin.
17. Rust CLI verbs owned by other lanes, landing as their PRs: `cmux status …` and
    `cmux terminal <t> wait --until …` (status lead), `cmux browser repl|host` (browser
    lead), `cmux cua …` (CUA lead), `cmux apps …` (app platform), `cmux task …` (tasks,
    `cmux_tasks::cli::run` mount after this PR merges).
