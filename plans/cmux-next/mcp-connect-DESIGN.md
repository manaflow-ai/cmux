# Connect an MCP server by asking

Status: design, 2026-11-03 (a974). Branch `feat-cmux-next`.
Asks: Lawrence, 2026-11-03: "ask you/chief to connect to a MCP server, and for the flow to Just
work, like have it open a card/button etc, think from first principles how to make this amazing",
then "think how to make it secure as well too tho".

Related: [chief-toolpacks-DESIGN.md](chief-toolpacks-DESIGN.md) (packs: CLIs, skills, MCP servers
as data), [mcp.md](mcp.md) (`cmux mcp serve`), acpmux `hub/secrets.rs` (the secret card) and
`hub/person.rs` (the person proof), [OWNERSHIP-PRINCIPLES.md](OWNERSHIP-PRINCIPLES.md).

## 1. The experience

The person types one sentence to Chief, or to any agent in cmux:

> connect to Linear

1. The agent calls `mcp_connect {server: "linear", scope: "chief", reason}`. The call waits.
2. A card appears in that chat, above the composer, and nowhere else:

   ```
   ┌──────────────────────────────────────────────────────────────┐
   │ [Linear logo]  Connect Linear?                     Verified  │
   │ Chief asks: "to read and file the issues you mention"         │
   │                                                              │
   │ Server   https://mcp.linear.app/mcp                          │
   │ By       Linear (linear.app)                                 │
   │ Access   read, write            Sign in with Linear          │
   │ For      This Chief ▾                                        │
   │                                                              │
   │                        [Cancel]   [Connect ⏎]                 │
   └──────────────────────────────────────────────────────────────┘
   ```

3. Connect opens Linear's sign-in in a cmux browser tab (the person's own session, so most
   times it is one click on "Authorize"). cmux sees the sign-in complete on its own.
4. The card turns into a result: `Linear connected · 23 tools · 9 can change data` with a
   disclosure of the tools. The agent's call returns `{status: "connected", tools: [...]}`, and the
   agent goes on with the task it was asked ("now file that bug").

A key-based server has a private field in the card instead of the sign-in button. A local
(stdio) server shows the exact command, the resolved binary and its SHA-256, and runs sandboxed.

Nothing to edit, no config file, no restart, no copy of a URL into another app, and the same
connection serves every harness in the chosen scope (Claude Code, Codex, OpenCode, the Chief).

### What others do, and where cmux goes further

| | Claude Code | Codex | ChatGPT | Claude.ai | cmux |
|---|---|---|---|---|---|
| Add by asking in chat | no (`claude mcp add`, then `/mcp`) | no (`codex mcp add`, config.toml) | no (Settings, Developer mode) | no (Settings, Connectors) | yes: one sentence, one card |
| Who approves an add | the person typed the command; project `.mcp.json` asks once | the person edited config | the person, in Settings | the person, in Settings | the person, in the card; the daemon refuses an agent's own answer |
| Shows exact URL/command before trust | URL yes; command yes | in the file | URL | URL | URL, publisher, verified badge, command + binary hash, scopes |
| Sign-in | browser OAuth from `/mcp` | `codex mcp login` | OAuth | OAuth | OAuth 2.1 + PKCE in a cmux tab, done detected, no step to return |
| Per-tool control | allow lists in settings | `enabled_tools` | write actions confirm | per tool: always / ask / never | per tool: always / ask / never, defaults from annotations; changed tools re-ask |
| Tool rug pull (descriptions change) | no | no | no | no | pinned hash; a change re-asks before use |
| Prompt-injection screen of tool text | no | no | partial | partial | yes, at connect and on every change |
| One connection, all harnesses | no | no | n/a | n/a | yes, by scope |
| Secrets out of agent reach | keychain, but the agent's shell can read it | file | server side | server side | keychain item only the broker reads; agents get a proxy, never a token |
| Teleport to cloud | n/a | n/a | n/a | n/a | the connection moves, the secret does not: re-auth or broker grant |
| Audit | no | no | no | partial | hash-chained log of adds, auths, grants and tool calls |

## 2. Model

One owner: the acpmux daemon of the machine (the `Hub`). It already owns the agent sessions,
writes each session's MCP config (`agent_tools.rs`), holds the person proof (`hub/person.rs`) and
the secret card (`hub/secrets.rs`). A connection is a record there:

```
Connection {
  id: "mcp_<16 hex>",
  name: "linear",                      # [a-z0-9-], unique per scope
  title: "Linear", publisher: "linear.app", verified: true,
  transport: Remote { url } | Stdio { command, args, env_names, binary_sha256 },
  auth: None | OAuth { issuer, client_id, scopes } | Key { header | env },
  scope: Chat(session) | Chief(home_id) | AllChiefs | Agents | Everything,
  tool_pin: { sha256 of the canonical tool list, per-tool sha256 },
  tool_policy: { tool -> Always | Ask | Never },
  state: Pending | NeedsSignIn | Connected | NeedsReapproval | Failed(reason) | Revoked,
  added_by: { person_connection, at }, asked_by: { session, agent }
}
```

The secret is not in the record. It is in the store keyed by `id` (section 5).

The pure part (resolve, validate, pin, diff, screen, classify, PKCE, discovery parsing, redaction)
is the crate `cmux-tui/crates/cmux-mcp-connect`, with no I/O, so every rule has a unit test.

### 2a. Resolve

`resolve(input)` takes what the person said, as the agent passes it:

1. A name in the registry (`registry.json` in the crate: name, aliases, title, publisher domain,
   URL, auth kind, default scopes, docs URL, logo): `linear`, `Linear`, `linear.app` all hit.
   Registry entries were probed live on 2026-11-03 (each returns 401 with RFC 9728
   `resource_metadata`, or 200 for an open server).
2. An `https://` URL: a custom remote server. Publisher = the registrable domain of the host,
   shown as unverified unless it equals a registry entry's URL exactly.
3. A command (`npx -y @x/mcp`, `uvx x-mcp`, `/path/bin`): a local stdio server. Resolved to the
   absolute binary on PATH; the card shows argv exactly and the binary's SHA-256.
4. Anything else: `{status: "unknown"}` with the near registry names, and no card.

Refused before any card (the agent gets the reason):

- `http://` except `http://127.0.0.1`, `http://[::1]`, `http://localhost` (a local dev server);
- a URL with userinfo (`https://linear.app@evil.example/`), a fragment, or a non-default port on a
  registry host;
- a host that is an IP literal in private, link-local or metadata ranges (169.254.169.254,
  10/8, 172.16/12, 192.168/16, fc00::/7, fe80::/10) unless loopback; a host name that
  resolves there is refused at connect time (DNS rebinding);
- an IDN host is shown in punycode next to its Unicode form when they differ, and is never
  verified;
- a command with shell metacharacters as one string (argv is a list; no `sh -c`).

### 2b. Scope

| Scope | Who gets the server | Default for |
|---|---|---|
| This chat | one session | an agent's ask from a chat that is not a Chief |
| This Chief | one Chief home and its turns | an ask from Chief |
| All my Chiefs | every Chief home of the person | |
| All my agents | every acpmux session of this Mac | |
| Everywhere | all of the above + agent harnesses the person runs by hand (writes `~/.claude.json`, `~/.codex/config.toml`, opencode's config, each pointing at the cmux proxy) | |

The agent proposes a scope; only the person's choice in the card counts. An agent can never
widen a scope: a widen is a new add, with a new card.

## 3. Flow and wire

New acpmux stdio MCP server `cmux-connect` (beside `cmux-secrets`; `secret_mcp::serve`), on in
every session whose app shows cards (same `ACPMUX_SECRET_TOOLS` gate). Tools:

- `mcp_connect {server, scope?, reason}` waits for the card (15 min, or the turn). Returns
  `{status: connected|declined|cancelled|unknown|refused, name, tools?, reason?}`. Never a token.
- `mcp_list {}`: connections this session can see: name, title, state, tool count. No secrets.
- `mcp_disconnect {name}` opens a card too (removing is the person's choice; it is cheap to confirm,
  and a prompt-injected disconnect is a denial of service).

Daemon methods (`rpc.rs`):

- `_acpmux/mcp_connect_request {sessionId, input, scope, reason}`: resolve and validate; records a
  `mcp_connect_request` card (all shown facts, no secret); waits.
- `_acpmux/mcp_connect_answer {requestId, approve, scope, toolPolicy?}`: accepted only from a
  person-proven connection (`Connection::is_person`). An agent connection gets
  `-32001 only the person can answer this card`. This is the core rule.
- `_acpmux/mcp_auth_begin {connectionId}` (person only): starts OAuth; returns the authorize URL.
- `_acpmux/mcp_key_submit {connectionId, value}` (person only): like `secret_submit`.
- `_acpmux/mcp_list`, `_acpmux/mcp_remove {id}` (person only), `_acpmux/mcp_policy_set` (person
  only), `_acpmux/mcp_reapprove {id}` (person only).

Card record (what the app renders; Swift `McpConnectCard`, webview `McpConnectCard.tsx`):

```json
{"requestId": "...", "agent": "Chief", "reason": "...", "title": "Linear",
 "publisher": "linear.app", "verified": true, "transport": "remote",
 "url": "https://mcp.linear.app/mcp", "command": null, "binarySha256": null,
 "auth": "oauth", "scopes": ["read", "write"], "proposedScope": "chief",
 "allowedScopes": ["chat", "chief", "allChiefs", "agents", "everywhere"],
 "warnings": ["..."], "phase": "ask|signingIn|connecting|connected|failed",
 "tools": [{"name": "create_issue", "kind": "write", "flagged": false}]}
```

Surfaces (cmux-next-feature rule: every capability on every surface):

- CLI: `cmux mcp add NAME|URL|-- CMD...` (opens the same card in Home; `--yes` only from a
  person-proven TTY session is not possible, so the CLI always shows the card), `cmux mcp ls
  [--json]`, `cmux mcp rm NAME`, `cmux mcp auth NAME` (re-sign-in), `cmux mcp tools NAME`,
  `cmux mcp policy NAME TOOL always|ask|never`.
- MCP: the `cmux-connect` tools above.
- Palette: "Connect MCP Server...", "MCP Servers" (opens Settings).
- Settings > MCP Servers: one row per connection: logo, title, URL or command, scope, state
  dot, tool count; Reconnect, Sign in again, Tools (per-tool policy), Remove.
- cmux.json: `mcp.connect.defaultScope`, `mcp.connect.allowLocalCommands` (default true),
  `mcp.connect.toolDefault` (`ask-writes`), `mcp.connect.screen` (`warn`|`block`).

## 4. Threat model

Assets: the person's accounts behind each server (tokens, keys); the person's machine (a stdio
server runs code); the agent's context (tool text steers the model); the record of who did what.

Actors: the person (trusted, proven by the per-launch key); an agent (runs as the same uid,
can be prompt-injected by any web page, issue, file or tool output it reads); a malicious or
compromised MCP server; a network attacker; another Chief or subagent of the same person (less
trusted than the scope owner); a cloud VM (a different machine).

| # | Threat | Defense | Test |
|---|---|---|---|
| T1 | Injected text makes an agent "connect to evil.example" and use it to exfiltrate | Only a person-proven connection answers a card; the card shows the exact URL, publisher and an Unverified badge; no auto-approve exists, not even for registry entries | `answer_from_agent_connection_is_refused`, `no_answer_means_no_connection` |
| T2 | Agent approves its own card through the acpmux socket | `_acpmux/mcp_connect_answer` requires `is_person` (HMAC proof bound to nonce+connection); the CLI cannot answer | same, plus `cli_add_still_needs_card` |
| T3 | Look-alike URL (`linear.app@evil`, `1inear.app`, IDN homograph) | Userinfo refused; publisher = registrable domain; verified only on exact registry URL; IDN shown as punycode | `userinfo_refused`, `lookalike_not_verified`, `idn_shown_as_punycode` |
| T4 | SSRF to cloud metadata / LAN | Private, link-local and metadata IPs refused, checked again after DNS | `metadata_ip_refused`, `private_ranges_refused` |
| T5 | Token theft from config, env, logs, transcripts | Tokens only in the store; harness configs point at `acpmux mcp-proxy ID`; the proxy adds `Authorization` on its own outbound request; redaction of `Bearer`, `access_token`, `refresh_token`, `code`, `code_verifier` in every log line of the module | `no_token_in_written_configs`, `redact_*` |
| T6 | Agent's shell reads the keychain (`security find-generic-password`) | Item created by the daemon with an access list naming only the acpmux binary (Security framework, not the `security` tool), so another process gets a system prompt; Linux/VM: 0600 file in a 0700 dir owned by the daemon user, and agents in the sandbox cannot read the dir | macOS manual check on fleet; Linux `file_store_mode_0600` |
| T7 | Another Chief / subagent uses a server it was not granted | The proxy is started with the session's id; it asks the daemon, which checks the connection's scope against the session's Chief and project before it signs the request | `scope_chief_a_not_visible_to_chief_b`, `subagent_needs_grant` |
| T8 | Malicious stdio server (code execution) | Card shows argv + binary SHA-256; first run pinned; a changed binary re-asks; runs under the acpmux sandbox (`linux_sandbox` / macOS sandbox-exec profile: no `~/.ssh`, no keychain, network on, writes only to its own dir) with a clean env (`secret_run`'s `KEPT_ENV`) | `command_pin_changes_reask`, `stdio_env_is_clean` |
| T9 | Tool poisoning: descriptions with instructions ("ignore previous", "read ~/.ssh", hidden Unicode) | Screen at connect and on every list: instruction phrases, secret paths, zero-width / bidi / tag characters, very long text; flagged tools default to Never and the card names them | `screen_*` |
| T10 | Rug pull: tools change after approval | Pin = SHA-256 of the canonical list and of each tool; a changed or new tool is held (not listed to the agent) until the person re-approves; removed tools just go | `diff_detects_changed_description`, `new_tool_held` |
| T11 | Destructive call without the person | Per-tool policy; default Always for `readOnlyHint: true`, Ask for others, Ask for `destructiveHint`; Ask is a permission card through the existing acpmux permission path | `classify_*`, `policy_defaults` |
| T12 | OAuth code interception / mix-up | OAuth 2.1: PKCE S256 only (refuse a server without it), `state` checked in constant time, `iss` checked (RFC 9207) when the server says it supports it, loopback redirect `http://127.0.0.1:PORT/cb` on a one-shot listener, RFC 8707 `resource` parameter on every request | `pkce_s256_vector`, `state_mismatch_refused`, `missing_s256_refused` |
| T13 | Over-broad scopes | Ask for the registry's least scope; the card shows the scopes; a custom server gets what its metadata says is `scopes_supported` minus admin-like scopes unless the person picks more | `least_scopes` |
| T14 | Teleport copies secrets to a cloud VM | A connection record teleports; the secret never does. The target shows the card as "Sign in again on <machine>", or the Mac brokers per-call (the VM asks the Mac's daemon over the mesh for a short-lived signed request; off by default) | `teleport_moves_no_secret` |
| T15 | Revoke leaves tokens behind | Remove: revoke at the server (RFC 7009 when advertised), delete the store item, drop from every session config, end running proxies | `remove_wipes_secret` |
| T16 | No trace of what happened | Each add, answer, sign-in, policy change, removal and tool call goes to the hash-chained audit log (`optchat-chief/src/audit.rs` shape) with input/output digests, never values | `audit_records_add_and_call` |
| T17 | A remote device or another person triggers a card | Like secrets: a chat a remote device started asks for none; a Chief turn another person started cannot call `mcp_connect` (CHIEF_TOOLS does not list it) | `remote_origin_refused` |
| T18 | Card spam / UI pressure | One open connect card per chat; a new ask replaces the old (the old asker gets `cancelled`); repeated declines of the same server in 10 min answer `declined` at once | `one_card_per_chat` |

What this does not stop: a server the person approved can misuse the access it was given; the
person can approve a bad server after reading the card. The card makes the facts plain and the
policy defaults limit writes, but trust in the server is the person's choice.

## 5. Secrets

- Store: macOS login keychain, generic password, service `cmux.mcp.<connection id>`, written by
  the daemon through Security framework with an access list of the acpmux binary only (T6).
  Elsewhere: `$ACPMUX_STATE/mcp/secrets/<id>.json`, 0600, dir 0700.
- OAuth: access token, refresh token, expiry, client id (DCR or CIMD). Refresh happens in the
  proxy before expiry; a failed refresh sets `NeedsSignIn` and the next tool call returns an
  error that says "the person must sign in again" (no card by an agent's call alone; the
  Settings row and `cmux mcp auth` show it).
- Keys: typed in the card's private field, sent on the person connection, never echoed back.
- Never in: the connection record, `.mcp.json`, config.toml, argv, env of an agent, logs, the
  transcript, the audit log, a crash report, `mcp_list`.

## 6. Runtime: the proxy

Every harness gets `{command: acpmux, args: [mcp-proxy, <connection id>]}` (stdio). The proxy:
asks the daemon for the connection and a scope check for its session; opens the remote
(Streamable HTTP; SSE fallback) or starts the sandboxed stdio server; adds auth; filters
`tools/list` to approved + pinned tools; on `tools/call` applies the tool policy (Never: error;
Ask: permission card; Always: pass); records the call in the audit log; on
`notifications/tools/list_changed` re-lists, diffs against the pin and holds new or changed tools.

This replaces the toolpacks `pack mcp` launcher for connections made this way; packs keep
working, and a later step moves pack servers onto the same proxy.

## 7. Cloud and teleport (a963/a964)

A connection record is part of what a Chief carries (its scope says which Chief). On teleport the
target gets the record with `state: NeedsSignIn` and the pin; the card on the target says "Sign
in again on <machine>" with the same facts. A Mac-brokered mode (the VM asks the Mac's daemon
to sign each request, over the authenticated mesh, for the scopes it was granted) is a later
option, off by default, behind its own card.

## 8. Card variants (Debug > Debug Windows > MCP Connect Card Playground)

Six variants, each in light and dark, each with phases ask / signing in / connected / failed /
unverified-custom / local command:

1. Compact row: one line + Connect; facts in a disclosure.
2. Facts table (the default in section 1).
3. Permission sheet style: big logo, the access as bullets ("Read your issues", "Create and edit
   issues").
4. Two-step: first "Linear wants access", then the facts and Connect.
5. Inline bubble: the card is the agent's message bubble with buttons.
6. Danger-forward: unverified and local servers lead with the risk line in the accent color.

Recommendation: 2 for verified, 6's risk line on top for unverified or local. Lawrence picks.

## 9. Tests (failing first)

- `cmux-mcp-connect` unit tests: every T-row test named above that is pure (resolve, URL rules,
  publisher, verified, IDN, pin, diff, screen, classify, policy defaults, PKCE RFC 7636 vector,
  state check, discovery parse incl. Linear's live metadata as a fixture, redact).
- acpmux hub tests: card answer from an agent connection refused; from the person accepted;
  one card per chat; remote origin refused; no token in written session configs.
- Swift: card view model state machine; playground renders all variants (screenshot on fleet).
- End to end on a tagged build: ask Chief "connect to Linear"; card; Connect; stop at the
  sign-in tab via escalate_auth; then a key server (Context7 with a key).

## 10. Order of work

Status (a974, 2026-11-03):

| Step | State |
|---|---|
| 1. Doc + `cmux-mcp-connect` core (resolve, URL/command rules, pin, screen, classify, PKCE, discovery, redact) with 34 tests | built; fleet-tested |
| 2a. acpmux `mcp_connect_request` / `mcp_connect_answer` (person only), `connect_mcp_server` tool on `cmux-secrets` (listed to every agent since step 3b; it was behind `CMUX_MCP_CONNECT_PREVIEW=1` until then), 5 integration tests | built |
| 2b-i. First connect after approval (`hub/mcp_probe.rs`, `cmux-mcp-connect::wire`): `initialize` + `tools/list` over Streamable HTTP (JSON or event stream, session id kept, redirects off, size and page caps); the tools go to the card and the agent screened and classed, without the server's text; a 401 answers `signInNeeded` with the RFC 9728 metadata URL and scopes; a key comes only with the person's answer and goes only into its header. Live-checked against Context7 (2 read tools) and Linear (401 + metadata), recorded as fixtures | built |
| 2b-ii. Connection store (`hub/mcp_store.rs`: `<home>/mcp/connections.json`, 0600), secrets (`hub/mcp_secrets.rs`: login keychain written by acpmux through Security.framework, so the access list is acpmux; 0600 files off macOS), OAuth 2.1 sign-in (`hub/mcp_oauth.rs`: RFC 9728/8414 discovery, RFC 7591 registration, PKCE S256, one-shot `127.0.0.1` listener, `state` and `iss` checks, RFC 8707 `resource`, refresh a minute before expiry), `acpmux mcp-proxy` (`mcp_proxy.rs`, server `cmux-mcp`: proves its chat with the caller token; the daemon makes each call, so no token leaves it; `tools/list_changed` when the version moves), pin and policy at call time with a person-only `mcp_call_request` card (once or always), hash-chained audit log with digests only (`<home>/mcp/audit.jsonl`), person-only Settings methods (`mcp_connections`, `mcp_policy`, `mcp_set_key`, `mcp_sign_in`, `mcp_remove`, `mcp_audit`) | built |
| 3a. Swift card (model, flow, key that never prints, six styles), Debug > MCP Connect Card Playground, flow tests | built |
| 3b. The card in the chat and in Home. The webview agent pane shows `McpConnectCard.tsx` (scope menu, Connect, Sign in, private key field) and `McpCallCard` beside `SecretCard.tsx`; each answer needs a fresh gesture. acpmux tells watchers `_acpmux/mcp_connect_pending` when a card opens or closes; the Chief host shows a hidden subagent's card in Home as a Connect / Don't connect card (`optchat-chief` `brain/home_mcp_connect.rs`, on the Home approval path) with the agent's scope, and the app answers it with `_acpmux/mcp_connect_answer` on its person-proven line (`ChiefApprovalDecider`). The Chief never answers it and keeps no deadline for it. For an OAuth server the daemon starts the sign-in after the approval and gives the agent `signInUrl`, which it hands to the person with `escalate_auth`. The `CMUX_MCP_CONNECT_PREVIEW` gate is gone | built |
| 3b-sec. Security gaps closed (two-commit red/green). The agent's `signInUrl` is the daemon's own one-use `http://127.0.0.1:PORT/start?t=…` (302 to the authorization page, 410 after), so the agent never sees the OAuth `state` or PKCE challenge (T12, login CSRF by a local agent). The sign-in listener answers only `Host: 127.0.0.1:PORT` or `localhost:PORT` (400 else; DNS rebinding of the loopback listener). Every name a daemon MCP request resolves goes through `hub/mcp_resolver.rs`: each address must pass `check_ip`, loopback only for `localhost` names, one bad address refuses the name (T4). After a key or a sign-in, a new or changed tool is held (not listed, not callable) until the person calls `_acpmux/mcp_approve_tools`; the chat gets `mcp_tools_changed` and the audit log a `toolsChanged` line (T10). Gap: a server whose first list was empty pins its first non-empty list without a question | built |
| 3c. Settings > MCP Servers (`CmuxNextAgentPane/McpServers`: `McpServersModel` over the `McpServersServing` seam, `AcpmuxMcpServersService` on the person line; an internal page tab `mcp-servers`, palette "MCP Servers"): each connection's title, exact URL, publisher and Verified, scope, state, per-tool policy menus, Remove, Sign In (a cmux browser tab), a private key field cleared after the send, the audit log. CLI `cmux mcp ls\|tools NAME\|audit` read, `rm NAME` removes, `auth\|key\|policy NAME` only open the page at that connection (control methods `mcp.servers.list\|audit\|remove\|open`); the CLI never takes a key | built |
| 4. `cmux mcp add|ls|rm|auth|tools|policy` | next |
| 5. Teleport: record moves, secret does not | next |

1. This doc + `cmux-mcp-connect` core with tests (landed first).
2. acpmux: records, person-only answer, `cmux-connect` MCP server, store, proxy.
3. App: card (Swift Home + webview agent pane), playground, Settings pane, palette.
4. CLI `cmux mcp add|ls|rm|auth|tools|policy`.
5. Cloud record sync with teleport.
