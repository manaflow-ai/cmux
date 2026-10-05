# ACP-REMOTE-GUARD: what each acpmux origin may do

Status as of 2026-10-05 on `feat-cmux-next`. Code: `cmux-tui/crates/acpmux/src/server/remote_guard.rs`
(every request from a connection that is not the unix socket passes it before it runs or is forwarded
to a peer), `server/local_app.rs` (the LocalApp origin), `server/redact.rs` (replies).

## Origins

| Origin | How a connection gets it | What it may do |
| --- | --- | --- |
| unix socket (`Origin::Local`) | the daemon's unix socket (same user) | everything; no rule in this document applies |
| LocalApp (`Origin::LocalApp`) | the WebSocket listener, when the listener and the peer are loopback, the `Origin` header is exactly `cmux-agent://pane` or a validated `--allow-dev-origin` value, and the first frame is `initialize` with this launch's LocalApp token (`ACPMUX_HOME/run/localapp.token`, 32 random bytes per launch, 0600, compared in constant time) | drive agents; start any configured preset by its id only; set any policy or mode (the daemon cannot see user gestures; the native relay enforces a fresh gesture for LocalApp); folders are not root-checked by the daemon (the native relay limits them to pane roots) |
| Web (`Origin::Web`) | every other WebSocket connection: the dashboard, paired and relayed devices, peer daemons | drive agents, inside every rule below |

`--allow-dev-origin` is honored only in a debug build or with `--dev`, which release launchers never pass.

## Refused for Web and LocalApp

- `mcpServers` with any entry, in any request (top level or `_meta.acpmux`). acpmux never passes a caller's MCP servers to a harness and has no daemon-side named servers.
- `env` in `_acpmux/defaults` and `_acpmux/presets` writes (a spawn env runs code).
- `_acpmux/export` with a `dest`; `_acpmux/import` of a path outside acpmux's bundle directory.
- A session method acpmux does not handle itself (the catch-all that passed caller params to the harness).
- `_acpmux/peer_add` and `_acpmux/peer_remove` (they change which machines the daemon reaches with the user's ssh keys and tokens); `peer_reconnect` stays.
- Setting a preset's harness args or system prompt; a LocalApp `session/new` that names a preset refuses args, systemPrompt, env, argv, command, harness and harnessCommand.
- No reply carries a token: `webUrl`, peer URL userinfo, query and fragment, preset args, env and system prompt (`hasArgs`/`hasEnv`/`hasSystemPrompt` instead) are removed (`redact.rs`).
- Folder fields (`cwd`, `additionalDirectories`) of `session/new`, `session/fork`, `session/load`, `session/resume` and `acp.trust.set` must be absolute existing directories; the request goes on with the canonical path.

## Web only

### Policies (allow lists)

- An absent policy at a Web `session/new` means `ask`: never the daemon default, a preset's or a family default's policy.
- A policy from the Web is exactly `ask` or `deny-all` (`session/new` params or `_meta.acpmux`, `_acpmux/set_policy`, `_acpmux/set_default_policy`, defaults and preset writes). Aliases, other policies and unknown values are refused.
- `_acpmux/set_rules` accepts only `autoDeny` and `ask` lists and a `default` of `ask` or `deny`; no `autoApprove` entry, no unknown field.
- Defaults writes accept only model, effort, policy and prefer; preset writes only harness, model, effort, policy and description. `_acpmux/warm` accepts only sessionIds and limit. `_acpmux/prewarm` is refused.

### Modes: the reviewed per-harness table (`ASKING_MODES`)

A Web source (fork, load, resume, handoff) is accepted only with no mode or a mode its family's row lists. `session/set_mode` and `session/set_config_option` (`mode`) from the Web use the same table; other config options are refused except model, effort, reasoning_effort, thought_level and thinking. An unknown family or mode is refused. A new Web session is moved to its row's first mode; a family with no row is ended and refused. Mode fields (modeId, mode, permissionMode, approvalPolicy, sandbox) are refused at `session/new`, fork, load, resume and handoff_prepare.

| Family | Modes that ask | Not accepted | Source |
| --- | --- | --- | --- |
| claude | `default`, `plan` | acceptEdits, dontAsk, auto, bypassPermissions | claude-agent-acp 0.74.0 `dist/permissions/modes.js`; https://docs.anthropic.com/en/docs/claude-code/iam#permission-modes; acpmux `claude_stdio/mod.rs` `MODES` |
| codex | `read-only` | `agent` (its default: "Approve for me", auto-review), `agent-full-access` | codex-acp 1.10.0 `dist/index.js` `_AgentMode` (`DEFAULT_AGENT_MODE = Agent`) |
| opencode | `plan` | `build` (its default; default permissions allow) | https://opencode.ai/docs/agents/#plan, https://opencode.ai/docs/permissions/ |

`webAskingModes` in config.json (written by the local user, never over a WebSocket) adds modes per family. WARNING: a mode added there lets paired devices start that mode without a per-action prompt. If `webAskingModes` ever gets a Settings row, the Settings lead must show the same warning.

### Ignored config entries and mode drift

The table lives in `src/web_modes.rs`, with `NON_ASKING_MODES` (the "Not accepted" column) next to it under the same sources. A `webAskingModes` entry that names a non-asking mode, for any family, is ignored with a warning. The daemon logs the merged table once at start and once on each config reload (`web asking modes: claude=[default,plan] codex=[read-only] ...`).

Default deny on drift: every mode change of a session is checked against the table, whether it comes from `current_mode_update`, a config option update (the harness may change its own mode), or a successful set_mode or set_config_option. When the mode leaves the table, Web control of that session ends at once and the session log records `remote_control_ended`. The Web is then refused `session/prompt`, `_acpmux/permission_respond`, `_acpmux/permission_group_respond`, `session/set_mode` and `session/set_config_option`, with error data `{"reason": "remote.mode_left_asking_table", "mode": ...}`. Web reads (attach, watch, events, info) stay allowed. The unix socket and LocalApp keep full control. A return to the table does not restore Web control by itself. Only a set_mode or set_config_option from the unix socket or LocalApp to an asking mode restores it (`remote_control_restored`). A prompt or permission answer for a peer's session is not checked here: it goes to the peer, whose guard checks that connection.

### Sources and resolution

Web fork, load, resume, handoff_prepare, set_mode and set_config_option resolve their session like the handler (`session_key`: sessionId, session or name; then `hub.resolve`), check a stored session from its stored meta, and refuse a source that cannot be resolved (unknown, ambiguous prefix, a peer's session). A source whose effective policy skips asking or whose mode the table does not list is refused, not downgraded (a downgrade cannot reach a mode held inside the harness, which a fork copies).

### Roots

A Web cwd or `additionalDirectories` entry must be inside a root, compared by path components: `webRoots` in config.json plus the known projects (every local session's cwd). A root that is `/`, the home directory or an ancestor of it is dropped, so one session in `~` never opens `~/.ssh` or `~/Library`. A Web `session/new` without a cwd is refused. Both sides use the filesystem's spelling (realpath, then F_GETPATH on macOS). `_acpmux/directories` answers Method not found to the Web.

## Decisions

- 2026-10-04: the WebSocket token never reaches a Web connection; the saved token rotated once (`283ea0c1d81`).
- 2026-10-04: LocalApp origin approved by the origin lead; LocalApp starts presets by id only, preset writes stay unix-only (`620b3561f70`, `afa40508fb8`).
- 2026-10-04: ssh peer URLs are plain names only; `--` before every ssh/scp destination (`73f2abafe96`).
- 2026-10-04: the remote guard (`d2cd0de282e`); skip-ask policies, peer changes and directory listings (`eb73a743741`); allow lists, `deny-all` stays for Web (`6a8a05c133f`).
- 2026-10-05: absent policy means ask, refuse-not-downgrade, roots (`34648165301`); handler resolution, mode fields, the per-harness table (`7086e1a60d9`).
- 2026-10-05: non-asking `webAskingModes` entries are ignored with a warning; Web control ends on mode drift and only a local set restores it.
- 2026-10-05: Web loads of peer sessions stay refused; `webAskingModes` stays, local user only; Web Codex `read-only` and Web opencode `plan` are accepted for now.

## Follow-ups

- (a) A per-action prompt that the Web user answers, so paired devices can run Codex and opencode with edits. This is the long-term target and replaces the read-only and plan limits.
- (b) Check the source on the owning daemon for peer loads, so a Web load of a peer's session can be served.
- (d) A session created locally in a non-asking mode, which never changes mode, still accepts Web prompts: the drift rule watches changes only. Refusing Web control of every session whose current mode does not ask closes this gap, but it also blocks peers from prompting such sessions.
- (c) `$/cancel_request` does nothing over a socket: requests run as spawned tasks, so a cancelled `session/new` still completes (the in-process case is covered by the pool's ClaimGuard).
