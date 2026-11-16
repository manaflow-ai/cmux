# Chief MCP hub: "connect to X" just works, in code mode, with tasks and events

Status: built, 2026-11-08. Branch `feat-cmux-next`. Code: `Native/OptChat/optchat-chief/src/mcp_hub/`,
tests `Native/OptChat/optchat-chief/tests/mcp_hub.rs` (fake server
`tests/fixtures/mcp/fake_mcp.py`).

Ask (Lawrence, 2026-11-08): "chief needs to be able to support skills and mcp servers and u need to
be able to self add/register mcp servers with codemode, see how pi implements it, we should do
similar. like i want to be able to tell u to connect to mcp server, and it should just work. we
should support both mcp tasks and mcp events too".

Related: [mcp-connect-DESIGN.md](../plans/cmux-next/mcp-connect-DESIGN.md) (the card-based, acpmux-wide design for
every agent; its pure rules crate `cmux-mcp-connect` is reused here),
[chief-toolpacks-DESIGN.md](../plans/cmux-next/chief-toolpacks-DESIGN.md) (packs carry fixed MCP servers).

## 1. What others do (research, 2026-11-08)

| | How a server is added | How the model sees tools | Tasks | Events |
|---|---|---|---|---|
| pi built-in MCP (pi 0.99+/1.0, `earendil-works/pi`) | `pi mcp add`, `~/.pi/agent/mcp.json`, then `/reload`; extensions can `pi.registerMcpServer` for the session. The model has no add tool | `exposure: codemode` (default): one `codemode` tool, scripts find tools with `searchTools()` / `describeTool()`; plus `tool_search` (BM25); `direct` exposes `mcp__srv__tool` | no | no |
| pi-mcp-adapter (nicobailon) | the model calls `mcp({action: "install", url})`: added at runtime, no reload | one ~200-token `mcp` proxy tool: `mcp({search})`, `mcp({tool, args})`; lazy connect, idle close after 10 min, metadata cached on disk; code mode opt-in | yes (`protocolVersion: auto`) | no |
| Cloudflare Code Mode (2025-09-26) | Agents SDK bindings | tool schemas become TypeScript interfaces; the model writes TS that runs in a fresh V8 isolate; `fetch` throws; servers are pre-authorized bindings, so code never sees keys | | |
| Anthropic "Code execution with MCP" (2025-11-04) | | tools as a file tree (`servers/<srv>/<tool>.ts`), read on demand or found with `search_tools`; 150k -> 2k tokens; intermediate data stays in the sandbox | | |
| MCP 2025-11-25 | | | core Tasks (SEP-1686, experimental): `tools/call` with `params.task: {ttl}` -> `CreateTaskResult {task}`; `tasks/get`, `tasks/result` (blocks), `tasks/list`, `tasks/cancel`, `notifications/tasks/status`; server capability `tasks.requests.tools.call`; per tool `execution.taskSupport` forbidden/optional/required | `resources/subscribe` -> `notifications/resources/updated`; `*/list_changed`; `notifications/message` (logging); HTTP pushes on a GET SSE stream |
| MCP 2026-07-28 (current) | | | Tasks is the extension `io.modelcontextprotocol/tasks` (SEP-2663): the server may answer any request with `resultType: "task"`; poll `tasks/get` (the terminal state carries `result` or `error`); `tasks/update` answers `input_required`; no `tasks/result`, no `tasks/list` | `subscriptions/listen` (SEP-2575) replaces subscribe and the GET stream: one long-lived request with a filter (`toolsListChanged`, `resourceSubscriptions: [uri]`, ...); notifications carry `io.modelcontextprotocol/subscriptionId` |
| Events WG (SEP-3415, open PR) | | | | `io.modelcontextprotocol/events`: `events/list`, `events/poll`, `events/stream`, `events/subscribe` (Standard Webhooks). Not merged; no server ships it yet |

2026-07-28 also drops `initialize` (every request carries `_meta` protocolVersion,
clientInfo and clientCapabilities; `server/discover` advertises versions), drops sessions and
`Mcp-Session-Id`, and adds the `Mcp-Method` / `Mcp-Name` headers. Most deployed servers still
speak 2025-11-25 (DeepWiki answered `initialize` with 2025-11-25 on 2026-11-08), so a client must
speak both.

"MCP events" therefore means, in order of what exists today: resource subscriptions and
list-changed notifications (both eras), logging notifications, task status notifications, and
the proposed Events extension (SEP-3415).

## 2. Design

The pi-mcp-adapter shape (the model adds servers itself through one proxy tool, lazy connect,
cache) with Cloudflare/Anthropic code mode (typed TS API, scripts run sandboxed and call back to
the host), owned by the Chief host so results and events wake the Chief.

### 2a. One fixed tool

`mcp {action, ...}` is on the Chief's turn and on every subagent (host-only: the cloud engine
spec drops it, like `watch`). Adding a server never changes the tool list, so the turn's tool
list stays byte-identical (prompt cache) and no schema sits in the prompt until asked for.

| action | does |
|---|---|
| `add {target, name?, headers?, env?, cwd?, replace?}` | resolve (registry name, https URL, or command) with `cmux-mcp-connect` rules; save; connect; list tools and prompts; answer the tool names and how to call them. A 401 starts OAuth (2d) |
| `list`, `remove {server}`, `signin {server}` | |
| `search {query, server?}` | rank cached tools (name x3, description x1) and prompts; one line each with a compact signature |
| `describe {server, tool?}` | TypeScript declarations (also written to `<mcp>/api/<server>.d.ts`) |
| `run {code, timeout_seconds?}` | code mode (2b) |
| `call {server, tool, args, task?, note?}` | one direct call; `task: true` starts a task (2c) |
| `tasks`, `task {id, op: status\|wait\|cancel}` | |
| `subscribe {server, uri? \| event?, note}`, `unsubscribe {id\|all}`, `events` | events (2e) |
| `resources`, `read`, `prompts`, `prompt {server, name, args}` | |

### 2b. Code mode

`run` writes the script into a prelude that defines `mcp` as a Proxy: `mcp.<server>.<tool>(args)`
writes one marked line on stdout; the hub makes the real MCP call (with the server's secrets) and
writes the answer back on stdin. A result is `structuredContent`, else the text (parsed when it
is JSON); an error result throws. `console.log` is captured; the return value is printed.
`mcp.$search`, `mcp.$describe`, `mcp.$servers` reach the hub too.

Runtime: Deno with no permissions (no network, files, env, subprocess: the `mcp` object is the only
way out), else Node 26 `--permission` (no fs write, no child processes, read only the script),
else Bun (no sandbox). The environment is cleared to PATH/HOME/TMPDIR/LANG. Caps: 500 calls, 900 s,
20 000 characters of output.

### 2c. Tasks

`call` with `task: true`:

1. Server has tasks (2025 `tasks.requests.tools.call` or the 2026 extension) and the tool is not
   `forbidden` (2025): `tools/call` with `task: {ttl}` (2025) or plain (2026, the server decides).
   A task handle is recorded (`t<N>`, saved, so it is polled again after a host restart); a poller
   follows `pollInterval`/`pollIntervalMs` with `tasks/get`; a terminal state gets its result from
   `tasks/get` (2026) or `tasks/result` (2025). `input_required` is told to the Chief once.
2. No server tasks: the hub holds the call on its own thread (1 h) as a local task.

Either way the end queues one note, the same wake path as a subagent report or a watch:
`[mcp task t3] deepwiki.ask_wiki_question completed after 42s (started by you): <note>\nResult:\n...`.
A tool with `taskSupport: required` called through `call`/`run` is waited for inline.

### 2d. Sign-in

A 401 on connect starts OAuth 2.1 (`oauth.rs`, rules from `cmux-mcp-connect::discovery`): RFC 9728
resource metadata (from `WWW-Authenticate`, else the well-known URL; a pre-2025-06 server falls
back to its origin), RFC 8414 or OpenID metadata, S256 required, dynamic client registration as a
native public client, PKCE, the `resource` parameter, `state` and `iss` checks, a one-shot
loopback listener on 127.0.0.1 (20 min). `add` answers `outcome: waiting` with the authorize URL;
the Chief opens it for the person (its auth-escalation skill: a cmux browser tab where they are
signed in). When they approve, the tokens go to `secrets/<name>.json` (0600), the server connects,
and the Chief wakes with `[mcp linear] signed in and connected ...`. Tokens refresh before expiry on
the request path. A key-based server is added with `headers`.

### 2e. Events

`subscribe {uri}` or `{event: <notification method> | *}`. Session era: `resources/subscribe`
(+ `logging/setLevel` for log events) and, over HTTP, a GET SSE stream kept open with backoff.
Stateless era: one `subscriptions/listen` per subscription (stdio: on the shared channel; HTTP: a
long-lived POST stream). Matching notifications wake the Chief: events within 3 s are one note,
and one subscription wakes at most every 20 s. `tools/list_changed` and `prompts/list_changed`
always refresh the cache, the declarations and the prompt skills. Subscriptions are saved and
re-armed after a restart. SEP-3415 events are not implemented (not merged; no server).

### 2f. Skills

Chief skills already exist (`$MUX_HOME/skills`, the shared `~/.cmux/chief/skills`, `/` in every
composer). Each MCP prompt becomes a skill `mcp-<server>-<prompt>/SKILL.md` in the Chief's own
folder (marked `cmux-managed: true` and `mcp-server: <name>`), whose body says how to fetch the
prompt with `mcp prompt`; so `/`, the Chief's skill list and its subagents see MCP prompts with no
new UI. Removing the server removes them.

### 2g. Safety (what "just works" keeps)

The person asked for no card: the Chief's own turn adds a server at once. What remains:

- `cmux-mcp-connect` rules before anything runs: https only (http only to loopback), no userinfo,
  no private/link-local/metadata IPs (checked again after DNS), no shell as a "server", no shell
  operators in argv.
- Tool and prompt text is screened (instructions to the model, secret paths, hidden characters);
  a flagged description is withheld from search, describe, `.d.ts` and skills, and named in `add`.
- Secrets never in `servers.json`, the declarations, a script's environment, or a reply.
- Subagents may use servers but not add or remove them (`Caller::Subagent`).
- A turn another person started (TURN_GATED, `internal_allowed_input`) may only `list`, `search`,
  `describe`, `tasks`, `events`, `prompts`.

The card flow of mcp-connect-DESIGN.md stays the design for agents other than the Chief.

## 3. Verification

`tests/mcp_hub.rs` against `fake_mcp.py` (stdio both eras, Streamable HTTP with a GET stream, HTTP
with OAuth): add + call in one turn; describe/search; persistence and lazy reconnect; code mode
(parallel calls, thrown errors, no env); tasks in both eras and cancel; resource events in both
eras with coalescing; prompts as skills and their removal; subagent limits; refused targets; OAuth
end to end (401 -> DCR -> authorize -> loopback -> token -> connect -> wake note, token only in a
0600 file); the tool on the host socket; one `mcp` tool for Chief and subagents.

Live: DeepWiki (`https://mcp.deepwiki.com/mcp`, no auth, 2025-11-25) added by name and called.

## 4. Not done

- 2026 `tasks/update` (answering `input_required`) and elicitation/sampling: the hub tells the
  Chief and the task waits.
- SEP-3415 Events extension and webhooks.
- The Cloud Chief (pi-durable engine) has no hub: `mcp` is host-only.
- Client ID Metadata Documents (the 2026 preferred registration) need a hosted metadata URL; the
  hub uses DCR, which 2026-07-28 keeps for compatibility.
