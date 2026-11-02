# cmux next: the MCP server (`cmux mcp`)

How Chiefs get MCP servers (tool packs, `.mcp.json` and codex config per Chief) is in
[chief-toolpacks-DESIGN.md](chief-toolpacks-DESIGN.md) section 6; this file stays the contract of
`cmux mcp serve`.

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
  - one tool per browser host REPL operation (`browser_repl_open`, `browser_repl_eval`,
    `browser_repl_close`, `browser_repl_reset`, `browser_repl_list`, `browser_repl_guide`),
    from `spec/browser-host-operations.json` (owner `browser-host`, browser-host.md; the
    host owns the file and step e extends it with the discrete `browser.*` ops). Calls go
    to the host's listener (`CMUX_BROWSER_HOST_SOCKET`, else
    `$XDG_RUNTIME_DIR/cmux/browser-host.sock`, else `$TMPDIR/cmux-<uid>/browser-host.sock`)
    with `origin: "mcp"`; the host applies its policy gate, secret vault and masking.
    `browser_repl_eval` defaults to a 60 s timeout and takes at most 300 s. The raw CDP
    grant (`rawCdp`) is not a tool argument. When no host listens the call fails with
    `browser_host.unavailable`; the server does not start the host (the session daemon
    will supervise it, browser-host.md decision 1);
  - `machine_list` and `machine_get` read the connected daemon's machine catalog.
    The native owner stays authoritative; admitted Cloud/SSH/server records are
    bounded metadata from the app's existing connections. `machine_list` uses
    the normal list pagination. `machine_get` requires a `machine` selector;
    the selector looks up metadata and grants no connection or execution rights.
    Session operations remain excluded, and other tools keep their existing
    machine scope. No catalog read starts, enrolls or reconnects a machine;
  - `window_list` (the app's windows, for `win_` targets);
  - `agents_snapshot` (the composed app and daemon topology, paged) and one tool per
    `cmux agents` action (`cli/agents.rs`): `agents_workspace_select`,
    `agents_workspace_create`, `agents_tab_select`, `agents_terminal_focus`,
    `agents_terminal_split`, `agents_palette_open`, `agents_dialog_list` and
    `agents_dialog_answer`. A call builds the CLI's words and runs the CLI's own code
    (`cli/mcp/agent_tools.rs`), so it answers the CLI's receipt `{action, result, state}`,
    where `state` is a fresh `agents_snapshot`-shaped snapshot. Selects and focus show
    the object in the app's window (their purpose is focus); create and split leave the
    user's focus alone. All but the dialog tools take `idempotency_key`, and the receipt
    names the key a change carried. A receipt over the result limit keeps `action`,
    `result` and the key and replaces `state` with `{truncated, hint}`. The dialog tools
    reach other agents' pending tool inputs: `agents_dialog_answer` only denies a
    permission (`mode: "deny"`; a person approves in cmux) or answers a question, and a
    reply whose transport drops after sending reports `in_progress`;
  - `agents_doctor`: the checks of `cmux agents doctor` (`cli/agents_doctor.rs`, one
    code path), as `{schema_version, findings}`. A finding is `{id, status, reason,
    summary, fix}`: `status` is `ok` (CLI ok or not applicable), `warn` (only inside
    cmux chats, unknown, or a missing harness while another is installed) or `fail`
    (missing), and `fix` is null or `{text, command, palette, url}`, where `text` is the
    CLI's fix, `command` a command it names as written (`cmux agents doctor`,
    `open '<url>'`; never an install), `palette` the command palette entry it names
    (Computer Use Setup) and `url` the System Settings pane. `checks` (distinct ids)
    narrows the report; the app is asked for grants only when a grant row is wanted.
    Read-only (`readOnlyHint`): it runs no fix and changes no setting. Like the CLI it
    prints paths under HOME (as set or resolved) as `~/...`, under `CODEX_HOME` and
    `CLAUDE_CONFIG_DIR` by those names, and a config parse error as its line and
    message, never the file's text;
  - `agents_wait` (`cmux agents wait`, same code path, `cli/agents/wait.rs`): waits
    `until` `idle` (the agent of a `term_`, `tab_` or `agent_` id or an agent chat's
    session stops working: idle, done or blocked on a dialog), `dialog` (a permission or
    question dialog is pending, a target's when given) or `text` (literal text, or a
    regex with `regex: true`, on a terminal's screen), for `timeout_seconds` (default
    30, at most 120). It answers `{until, matched, waited_seconds, match, state}` with a
    fresh snapshot; a timeout is `matched: false`, not an error, and a condition that
    already holds answers at once. `text` is the daemon's `terminal.wait` (it wakes on
    output); `idle` and `dialog` hold `session.events` open and check on each event, and
    every second for what only the app knows (chat agent state, dialogs), which has no
    event. A call with `_meta.progressToken` gets `notifications/progress` every 5 s
    (`progress` seconds waited, `total` the timeout). An invalid regex, and a `term_`,
    `tab_` or `agent_` target no owner knows (for every `until`), are refused as
    `not_run`; a dialog target of another kind (a request id) may name a dialog that
    has not appeared yet, so it waits. A `text` target that closes mid-wait reports
    `match.state: "closed"`, as `idle` does. The server answers one call at a time,
    so a wait holds later calls for up to its timeout (120 s), as `terminal_wait`
    does. `cmux agents wait` exits 1 when it times out, as `screen wait` does.
    Read-only: it reads what
    `agents_snapshot`, `agents_dialog_list` and `terminal_wait` already read;
  - `agents_events` (`cmux agents events`, same code path, `cli/agents/events.rs`): a
    long-poll on what changes, `{events: [{seq, kind, at, change, id, ...}], next_after,
    timed_out}`. Kinds are `dialog` (opened, closed), `notification` (created, read,
    cleared), `tab` and `workspace` (changed, closed) and `agent` (a terminal agent's or
    agent chat's `state`); `reset` says the daemon's journal restarted, the cursor
    expired or is unknown, or an earlier call never reached the daemon (read
    `agents_snapshot` again) and comes whatever `kinds` asks for. Without `after` it
    starts from now and returns nothing old; `next_after` continues with no gaps or
    duplicates. It answers at once when events are pending (a burst for up to 200 ms),
    else on the first event, else at `timeout_seconds` (default 30, at most 60, because
    the server answers one call at a time) with `timed_out: true`. `limit` (default 100,
    at most 200) is exact: a full answer stops inside a journal batch and the cursor
    resumes there. Tabs, workspaces, notifications and terminal agents come from the
    daemon's `session.events` journal, resumed from the cursor's revision; dialogs (the
    `agents_dialog_list` feed) and agent chat states (the app's tabs) have no event and
    are read every second (each app read bounded by the call's time left; the daemon
    read that scopes them is skipped under 50 ms left but else has the transport's own
    timeout) and diffed against the state the cursor carries (opaque: `evc1_` and base64url JSON, at most 64 KiB).
    So a dialog that opens and resolves between two reads is missed, and the baseline is
    the first app read that answers. A cursor that would pass 64 KiB drops that state and
    gives a `reset` (`cursor_too_large`); a reset that finds an answer full waits in the
    cursor for the next call. Scoped like `agents_snapshot`: chat tabs and dialogs of
    terminals or tabs outside the session are left out, and when a daemon there was does
    not answer, the app is not diffed that time (nothing from other sessions leaks).
    A cursor whose event number is past 2^53 is refused as not a cursor. Events carry
    ids, states and short titles; no terminal text, chat text or tool input, and notification title and
    body are cut to 80 and 160 characters (`truncated: true`). Kinds not asked for are
    skipped, not kept. Read-only;
  - `agents_chat_new`, `agents_chat_state` and `agents_chat_interrupt` (`cmux agents
    chat new|state|interrupt`, plus `chat continue`, a send with default text;
    `cli/agents/chat_control.rs`, #23026): `new` starts a chat in the acpmux `cmux acp`
    reaches with the harness, model, effort, mode and policy given (acpmux decides what
    the caller may pick) and `CMUX_WORKSPACE_ID` of its workspace, then the app shows it
    through `agent.openSessionWorkspace` in the given pane, workspace or a new workspace,
    without focus (`opened: false` and `open_error` when no app answers); a first prompt
    goes as a send. `state` reads `_acpmux/info`; `interrupt` is `session/cancel`, never
    on the caller's own chat. Both reach only this session's chats, as below;
  - `agents_chat_send` and `agents_chat_read` (`cmux agents chat send|read`,
    `cli/agents/chat.rs`): one agent prompts another agent chat and reads its
    transcript. Both reach only chats whose acpmux session runs in a workspace of this
    cmux session (`sessionEnv.CMUX_WORKSPACE_ID` against the snapshot's `extra.key`); a
    chat with none is refused (`chat.out_of_scope`). A send is a `cmux agent message`:
    the daemon stores it under its policy and limits, then it reaches the chat as an
    acpmux prompt with `_meta.acpmux.provenance`, so the chat shows it as another agent's
    message. It never goes to the caller's own chat (`chat.own_chat`), refuses empty text
    and text over 32 KiB, is `destructiveHint`, and answers `{action, origin, result:
    {chat, message_id, state}, idempotency_key}`; a retry with the key is the same
    message. A message stored but not handed to the chat is an error that keeps its
    receipt (`state: failed`; the CLI exits 1). The CLI takes the text as one argument
    or after `--`. A read answers items `{id, role, text}` (`user` with `origin`/`from`
    for an agent's prompt, `assistant`, `tool` as kind and status only, never its title,
    which harnesses fill with the input, `turn_end`), paged with `after` = `next_after`;
    an answer being written or a tool call running is `partial`, and `next_after` never
    passes it.
    Waiting for the reply is `agents_wait` with `until: idle` and the chat as target;
  - `render` (`html`, `title`, `id`): a page the cmux NEXT chat draws as a live render card
    above the turn's answer (webviews `renderCall.ts`). It reaches no owner; the result is
    the receipt (`rendered`, `id`, `updated`, `bytes`, `title`). `id` is the page's render
    id, which the chat derives from the call's input too. A render without `id` is always a
    card of its own; one that passes an id this server returned shows its page in place in
    the most recent card with that id, the earlier page a previous version in the side
    panel (cx-ncc.94). An id it did not return is refused;
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
| `session.*` (list, get, open, snapshot, ping, creation, journal, defaults, window title, shutdown, reload), `client.get/list`, `frontend_projection.*`, `pairing_request.*`, `sidebar_view.*` | cmux-tui-only scopes the curated `cmux` CLI also refuses; pairing needs a person |
| app actions the app exempts from MCP (`surfaces.mcp` in `action.list`, its `ActionSurfacePlan`: `credentials` such as account connect/remove and sign in/out, `endsApp` such as quit, `systemChange` such as toggle setting or install CLI) | the app owns the decision; the server words the reason and refuses an action whose app reports no `surfaces.mcp` |
| GUI-only actions, `action.run` by id | only `cli: true` actions |
| `settings.*`, `history.list`, `bookmark.list`, `bookmark.importSources`, `accounts.list`, `browser.page.*`, `events.stream`, `system.*` | not catalog operations or CLI actions; private data, credentials or page access; later phases decide |

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
