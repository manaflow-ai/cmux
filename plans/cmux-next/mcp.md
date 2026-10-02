# cmux next: the MCP server (`cmux mcp`)

`cmux mcp serve` gives MCP clients (Claude Code, Codex, any stdio MCP client) the
same control of cmux that the `cmux` CLI has. It is part of the Rust `cmux` binary
(cli.md, C2) and lives in `cmux-tui/crates/cmux-tui/src/cli/mcp*`. Phase 1, agreed
with the CLI owner (session feat-cmux-next-99) on 2026-10-01.

## Turn it on

The server is off by default. `serve` reads `mcp.enabled` from cmux.json
(`CMUX_NEXT_CONFIG_FILE` names another file, as in the app) and refuses with exit
status 1 unless it is `true`. It checks again before every tool call, so turning it
off stops the next call.

```sh
cmux settings set mcp.enabled true      # or "mcp": {"enabled": true} in cmux.json
cmux mcp tools                          # what serve offers, and what it leaves out
cmux mcp tools --json                   # the same, with schemas and exclusion reasons
```

Claude Code:

```sh
claude mcp add cmux -- cmux mcp serve
```

Codex (`~/.codex/config.toml`):

```toml
[mcp_servers.cmux]
command = "cmux"
args = ["mcp", "serve"]
```

Use the `cmux` inside the app bundle (`/Applications/cmux.app/Contents/Resources/bin/cmux`)
when `cmux` is not on the client's `PATH`. Global options go before `mcp`:
`cmux --session build-box mcp serve`, `cmux --app-socket /tmp/cmux-debug-x.sock mcp serve`.

## Contract

- Transport: newline-delimited JSON-RPC on stdin and stdout (MCP 2025-06-18, also
  2025-03-26 and 2024-11-05). Nothing listens on the network. The server runs as the
  user and finds the daemon and app sockets the way the CLI does.
- Tools come from the owners' catalogs, never from the CLI grammar:
  - one tool per `cmux.protocol/2` read or mutation operation the curated `cmux` CLI
    offers, from `spec/resource-operations-v2.json`; the name is the operation with
    `_` for `.` (`workspace_list`, `tab_create_terminal`, `terminal_input_write`), and
    the input schema is the operation's typed params;
  - `window_list` (the app's windows, for `win_` targets);
  - one tool per app action that `action.list` offers to the CLI and to MCP
    (`surfaces.cli` and `surfaces.mcp` are `offered`), named `app_` plus its
    CLI name (`app_new_window`, `app_workspace_move_to_window`), with the action's
    arguments (kinds, choices, ranges) as the schema. These appear only while the app
    answers. The server declares `tools.listChanged` and sends
    `notifications/tools/list_changed` when the app publishes `action.catalog.changed`
    on `events.stream` (the router does it when its actions change) or comes back after
    it quit or restarted; a thread reads the stream with blocking reads and retries an
    unreachable app with a doubling delay (0.5 s to 30 s).
- Calls go through `cli/mcp/transport.rs`, built from the CLI's own pieces (`resolve`
  route, encode and response reads, `app` discovery, read barrier, busy retry and
  `action_run_params`, `federation::qualified`): the same route
  defaults, `--session` routing, lookups on the request's connection, deadlines and
  protocol checks.
- Ids: public ids only (`ws_`, `screen_`, `pane_`, `tab_`, `term_`, `browser_`,
  `win_`). A unique prefix works for workspace, screen, pane, tab, terminal and
  browser selectors and top-level id fields (one list read on the request's own
  connection; `selector.ambiguous` with candidates otherwise). `<session>:<id>` routes
  the call to that session; one call reaches one session. The `session` argument
  does the same as `cmux --session`.
- Mutations carry an idempotency key: the `idempotency_key` argument, else a new
  one. A failed call returns `{error, state, idempotency_key}`: `error` is the
  owner's error unchanged, `state` is `rejected`, `not_run` or `in_progress`. Retry
  an `in_progress` call with the same key; it cannot apply twice.
- App actions send `action.run` with `wait: true`, `after: "sync"`, `cli: true` and
  `origin: "mcp"`. The app changes the user's focus, selection, shown workspace or key
  window only when the call passes `focus: true` or the action's purpose is focus.
  Destructive actions need `confirm: true`, as from the CLI (user decision
  2026-10-01: they stay tools; the run carries `origin: "mcp"` as its actor).
- Terminal input and command runs (`terminal_input_write`, `pane_run`,
  `workspace_run`) stay tools, as in the CLI (user decision 2026-10-01).
- Large reads: a read with an array result and no `limit` of its own answers
  `{items, total, offset, next_offset}` (default 100 items, at most 1000). Every
  result is cut to 256 KiB; a cut page says `truncated` and the next offset.

## Excluded

`cmux mcp tools --json` lists every exclusion with its reason. Summary:

| Excluded | Reason |
| --- | --- |
| stream operations (`session.events`, `terminal.attach`, `browser.attach`, `sidebar_view.attach`, `session.journal.subscribe`) | tools are request and response |
| connection control (`client.*` sizing and metadata, viewer resize and release, `request.cancel`, `stream.cancel`, renderer grants) | scoped to one socket connection |
| `machine.*`, `session.*` (list, get, open, snapshot, ping, creation, journal, defaults, window title, shutdown, reload), `client.get/list`, `frontend_projection.*`, `pairing_request.*`, `sidebar_view.*` | cmux-tui-only scopes the curated `cmux` CLI also refuses; pairing needs a person |
| app actions the app exempts from MCP (`surfaces.mcp` in `action.list`, its `ActionSurfacePlan`: `credentials` such as account connect/remove and sign in/out, `endsApp` such as quit, `systemChange` such as toggle setting or install CLI) | the app owns the decision; the server words the reason and refuses an action whose app reports no `surfaces.mcp` |
| GUI-only actions, `action.run` by id | only `cli: true` actions |
| `settings.*`, `history.list`, `bookmark.list`, `accounts.list`, `browser.page.*`, `events.stream`, `system.*` | not catalog operations or CLI actions; private data, credentials or page access; later phases decide |

The parity test (`cli/mcp/tests.rs`) fails when a catalog operation is neither a tool
nor excluded, when a tool's operation has no `cmux` command, or when `cmux` offers an
excluded operation. App actions are read from the running app, so the tests check the
rule instead (every `cli: true` action becomes a tool or an exclusion, and the tool
sends the same `action.run` as `cmux <noun> <verb>` except `origin`); the live check
in the PR lists the real registry.

`terminal_wait` and `terminal_wait_exit` default to a 30 s timeout and take at most
300 s, because the server answers one call at a time. A change whose result is larger
than 256 KiB still reports success (`applied: true`), so a client never retries it.

## Later phases

- A bounded `events_read` tool (app `events.stream` and daemon `session.events`
  with a count and a deadline).
- Policy for `browser.page.*` (eval, fill and click reach signed-in pages) and the
  history, bookmark, accounts and settings reads (excluded in phase 1, user decision
  2026-10-01).
- Prefix resolution in the daemon (cli.md, Remaining 7) replaces the client-side
  lookup.
