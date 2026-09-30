# cmux next: the `cmux` CLI in Rust

Plan for replacing the Swift CLI (`CLI/`, about 106k lines, target `cmux-cli`) and the
app-side compat layer (`CmuxNextControl/Compat/`, see cli-compat.md) with one Rust
binary. Decisions by the user on 2026-09-30 unless marked (agent).

## Decisions

- C1. The CLI is Rust. No Swift code ships in the CLI.
- C2. One multicall binary, `cmux`. It links the CLI, acpmux (as a library) and cmux-tui
  (as a library once it has one). `argv[0]` of `acpmux` or `cmux-tui` runs that program's
  main, so the app bundle ships one Mach-O plus symlinks and every piece has one version.
- C3. No compatibility with the old CLI. Old verbs, flags, `workspace:N` style refs and the
  v1 text protocol are gone. Old verbs fail with `unknown command`, and where a clear
  replacement exists the error names it. `CmuxNextControl/Compat/` is deleted at cutover.
- C4. `cmux acp` has three parts: the acpmux session verbs, an ACP agent on stdio for
  editors, and `cmux acp open` to show a session in the app.
- C5. acpmux reaches cmux-next by merging PR 15512 into a branch off `feat-cmux-next`,
  not through `main`. The legacy app never ships acpmux. The native chat pane prototype
  (PR 15521) targets deleted legacy code and is rebuilt for cmux-next separately.
- C6 (agent). The crate is `cmux-tui/crates/cmux-cli`, in the cmux-tui workspace, so it
  shares the protocol crates, the lockfile and the Linux build. The same binary runs
  inside Cloud VMs.
- C7 (agent). Object ids on the command line are the daemon resource ids (`ws_…`,
  `pane_…`, `tab_…`, `term_…`), qualified with the session for non-home sessions
  (data-model.md 1.2). Any unique prefix is accepted. No per-process numeric refs.
- C8 (agent). Old Swift ACP host (`CMUXAgentLaunch/ACPHost`, PR 15976, no caller) is
  deleted. acpmux already speaks ACP to its clients, so `cmux acp` bridges to it.

## Owners and routing

Every verb has exactly one owner. The CLI talks to the owner directly; nothing is
forwarded through a second process.

| Owner | Verbs | Works with the app closed |
| --- | --- | --- |
| cmux-tui daemon | workspace, tab, pane, terminal (send, key, read), notify, agent reports, groups, pins | yes |
| app control socket | window, focus and selection, browser page operations, `action`, `events`, `identify` focus fields | no |
| acpmux daemon | `cmux acp …` | yes (started on demand) |

Discovery, first match wins:

- App socket: `--socket`, `CMUX_SOCKET_PATH`, `CMUX_TAG` (tag path rules from
  `ControlSocketPath`), then the channel default. The Rust function mirrors the Swift
  one; both are tested against one shared fixture table in `cmux-tui/spec/`.
- Daemon socket: `--tui-socket`, `CMUX_TUI_SOCKET`, then `system.identify` on the app
  socket (the app reports the home session and its socket), then the cmux-tui default
  path for the channel's session name.
- acpmux: the acpmux client resolution, with the state dir derived from the channel and
  tag so tagged builds never share an acpmux daemon with the user's release app.

Terminals started by cmux-next get `CMUX_SOCKET_PATH`, `CMUX_TUI_SOCKET`,
`CMUX_WORKSPACE_ID` and `CMUX_SURFACE_ID` (the daemon ids), so a CLI call from inside a
terminal targets its own workspace and tab without flags.

## Command surface

Noun first, then verb. `--json` on every read; human output by default.

```
cmux identify | tree | ping | version
cmux workspace ls|new|close|rename|select|move
cmux tab ls|new|close|rename|move|pin|unpin
cmux pane ls|split|focus|swap|close
cmux terminal send|key|read|clear
cmux window ls|new|focus|close
cmux browser open|goto|eval|snapshot|click|fill|url
cmux notify [--title] [--body]      cmux notifications ls|ack
cmux action ls|describe|run <id> [--arg k=v] [--target id]
cmux events [--filter …]            (JSON lines, streaming)
cmux hook <agent> <event>           (called by agent hook configs; reads stdin)
cmux hooks install|uninstall|status [agent]
cmux acp …                          (below)
cmux tui …                          (the cmux-tui frontend)
```

`cmux action run` is the escape hatch for every registered action (REWRITE.md action
contract). The CLI does not copy the registry: `cmux action ls` and shell completion read
`action.list` at run time. A noun verb exists only when it has an owner outside the app
(the daemon) or needs typed arguments beyond `--arg`.

All user-facing CLI text is localized (English and Japanese) through the cmux-tui
localization module.

## `cmux acp`

- Session verbs: `cmux acp ls|new|send|attach|wait|stop|rm|fork|web|tui|daemon`. These
  call the acpmux library; behavior matches the acpmux CLI. `cmux acp` with no verb opens
  the acpmux TUI, like `acpmux` does now.
- `cmux acp stdio [--session NAME | --agent HARNESS [--cwd DIR]]`: an ACP agent on
  stdin/stdout for Zed and other editors. It connects to the acpmux daemon (starting it if
  needed), binds or creates the session, and relays JSON-RPC. `session/new` from the
  editor creates an acpmux session; `session/load` attaches to one, so the editor sees
  sessions started from the TUI, the web dashboard or the app.
- `cmux acp open NAME`: runs the app action that shows an agent session in a tab of the
  current pane. Needs the cmux-next chat pane (separate work item; the React pane from
  PR 16042 is the starting point).

## Agent hooks

`cmux hook <agent> <event>` replaces the Swift hook machinery. It reads the agent's JSON
payload on stdin and sends one `report-agent` to the daemon for the calling terminal
(`CMUX_SURFACE_ID`). The daemon owns agent state (status, needs-input, unread), so the
sidebar, iOS and the TUI read the same value. `cmux hooks install` writes the hook
entries into each agent's config and replaces entries that call old verbs
(`claude-hook`, `codex-hook`, …). Agents that run through acpmux need no hooks.

## Phases

1. acpmux on the cmux-next line (merge of PR 15512), this plan. Done in
   feat-cmux-next-acpmux.
2. `cmux-cli` crate: multicall dispatch, socket discovery with the shared fixture,
   `identify`, `tree`, `ping`, `action`, and the full `cmux acp` session verbs.
3. Daemon verbs (workspace, tab, pane, terminal, notify) and terminal env ids.
4. `cmux acp stdio`, hooks and `hooks install`.
5. App verbs (window, browser, events) and `cmux acp open`.
6. Cutover: bundle the Rust `cmux` at `Contents/Resources/bin/cmux` with `acpmux` and
   `cmux-tui` symlinks; delete `CLI/`, `cmuxCLITests/`, the `cmux-cli` target,
   `CmuxNextControl/Compat/` and `CMUXAgentLaunch/ACPHost`; rewrite the skills and docs
   that name old verbs; replace `cli-compat-e2e.py` with an e2e suite for the new
   surface.

## Risks

- C3 breaks every user's existing agent hook config and scripts at the first update.
  `hooks install` runs on first launch of cmux-next to repair hook configs; scripts are
  not repaired.
- Shipped skills (`skills/`) and docs describe old verbs. They must change in the same
  cutover PR, or agents will call commands that do not exist.
- cmux-tui is a binary crate. C2 needs a `lib.rs` split first.
- Rust builds and tests run on a Blacksmith Testbox or CI, never on the local Mac.
