# ACP-REMOTE-GUARD: what each acpmux origin may do

Status as of 2026-10-05 on `feat-cmux-next`. Code: `cmux-tui/crates/acpmux/src/server/remote_guard.rs`
(every request from a connection that is not the unix socket passes it before it runs or is forwarded
to a peer), `server/local_app.rs` (the LocalApp origin), `server/redact.rs` (replies).

## Origins

| Origin | How a connection gets it | What it may do |
| --- | --- | --- |
| unix socket (`Origin::Local`) | the daemon's unix socket (same user) | everything; no rule in this document applies |
| LocalApp (`Origin::LocalApp`) | the WebSocket listener, when the listener and the peer are loopback, the `Origin` header is exactly `cmux-agent://pane` or a validated `--allow-dev-origin` value, and the first frame is `initialize` with this launch's LocalApp token (`ACPMUX_HOME/run/localapp.token`, 32 random bytes per launch, 0600, compared in constant time) | drive agents; start any configured preset by its id only; set any policy or mode (the daemon cannot see user gestures; the native relay enforces a fresh gesture for LocalApp); folders are not root-checked by the daemon (the native relay limits them to pane roots) |
| Peer (`Origin::Peer`) | the WebSocket listener, when the upgrade request carries the dashboard token AND exactly one `x-acpmux-peer-token` header equal to this launch's peer token (`ACPMUX_HOME/run/peer.token`); see "Peer origin" | the Web's rights, without the current-mode rule for its own user (a request it forwards for its Web client runs under the Web's rules) |
| Web (`Origin::Web`) | every other WebSocket connection: the dashboard, paired and relayed devices, a peer daemon without the peer token | drive agents, inside every rule below |

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
| codex | none: refused family | `read-only`, `agent` (its default), `agent-full-access` | codex-acp 1.10.0 `dist/index.js` `AgentMode`; see "Codex and opencode are refused" |
| opencode | none: refused family | `build` (its default), `plan`, every primary agent | opencode 1.18.33 `Agent.state`; see "Codex and opencode are refused" |

#### Codex and opencode are refused (D10, 2026-10-06)

Decision (coordinator, 2026-10-06, secure by default): a remote connection never drives Codex or opencode. D10 allows a remote client to edit through a harness only in a mode that asks before EVERY edit and EVERY command, writes inside the workspace included, and the investigation below found no such mode in either harness. The modes accepted before (Codex `read-only`, opencode `plan`) do not ask either, so they were removed too.

Code: `REFUSED_FAMILIES` in `src/web_modes.rs` (`codex`, `opencode`). `ASKING_MODES` has no row for them. The table refuses them whatever config.json says: a `webAskingModes` entry for them is ignored with a warning, and so is an entry for the family of any profile whose command line runs one of them (`derive_family` without the explicit `family`, so `{"argv": ["codex-acp"], "family": "mine"}` makes `mine` refused too). A preset or a default cannot add them back, because the check is on the session's family. For a refused family, `session_asks` is false even when the session reports no mode, and `config_value_asks` is false for every option. Thus a Web `session/new` is ended and refused (`no reviewed asking mode`), and set_mode, set_config_option, fork, load, resume, handoff to a new target, prompts and permission answers are refused (`remote.mode_not_asking`). The cache key includes the refused set, so a profile changed while a Web prompt is queued is seen at dispatch. The daemon logs `web asking modes: claude=[default,plan] refused=[codex,opencode]`; `_acpmux/web_modes` lists `refusedFamilies`. Tests: `tests/remote_guard_refused_families.rs`, `tests/web_mode_current.rs` (an opencode handoff target), `web_modes.rs` unit tests.

Agent pane: on a remote connection (`origin: "remote"` in `initialize`) that shows a Codex or opencode chat, the composer hides Send and says "Not available from here: this agent has no mode that asks before each change" (`composer.remoteUnavailable`). An acpmux that names no origin (older than the origin field) gets the same with "Update acpmux to send from here: it does not say where this connection comes from" (`composer.originUnknown`). `webviews/src/agent-session/acpmux/remoteEditing.ts`.

Exposure: the WebSocket listener binds loopback only by default (`127.0.0.1:47811` for the shared home, else `127.0.0.1:0`). A Web origin is therefore any allowed local web origin (the dashboard, a paired or relayed device through the relay), unless the user set another listen address or a tunnel. The Mac agent pane is LocalApp and keeps full control. One local effect: the native relay asks `_acpmux/web_modes` whether a mode set asks, so a Codex or opencode mode set from the Mac pane (also `read-only`) now shows the native confirmation sheet for a mode that does not ask.

Enable it again only when a harness gives a verifiable ask-every-change mode: a mode whose approval acpmux can read from the session (an ACP field, a fixed adapter mode with a published policy), that asks before every file write and every command, inside the workspace too. Then add its row to `ASKING_MODES`, remove the family from `REFUSED_FAMILIES`, cite the source, and add red tests, after a security review. For Codex this needs an adapter mode with a read-only sandbox and approvals for every escalation, or a granular policy that asks for every patch and every command. For opencode it needs the merged permission rules reported to the client.

Residual: a profile that runs Codex or opencode through a wrapper whose argv basenames name neither, with an explicit other `family`, is not detected. That needs the local user to write both the profile and a `webAskingModes` row for its family.

Evidence, Codex (codex-acp 1.10.0 with codex-cli 0.153.4, the versions acpmux runs; `config/codex_adapter.rs` pins the adapter):
- codex-acp sends the mode's `approvalPolicy`, `approvalsReviewer` and `sandboxPolicy` with every turn (`dist/index.js` `sendPrompt` calls `runTurn`), so config.toml cannot change them, and a Web request cannot set them (`MODE_FIELDS`).
- The three modes (`dist/index.js` `AgentMode`): `read-only` = `on-request`, reviewer `user`, sandbox `workspaceWrite` ("Always ask to edit external files and use the internet"); `agent` = the same with reviewer `auto_review`; `agent-full-access` = `never`, `dangerFullAccess`.
- `on-request` means "The model decides when to ask the user for approval" (`codex --help`, 0.153.4, which offers only `on-request` and `never`). The Codex docs (https://developers.openai.com/codex/agent-approvals-security) say workspace-write with on-request "can read files, make edits, and run commands in the working directory automatically" and "commands allowed by the sandbox can run without approval". `approval_policy = "untrusted"` is retired.
- Result: no codex-acp mode asks before each edit or each command. `read-only` is Codex's Auto preset under another name: it writes files and runs commands inside the workspace without a prompt (`.git` stays read-only).

Evidence, opencode (1.18.33; acpmux runs `opencode acp`):
- ACP modes are opencode's primary agents that are not hidden (`build`, `plan`, and any primary agent the user defines). A mode carries no permission data over ACP. Permissions are opencode rules: the agent's defaults, then the user's `permission` config, merged LAST (last match wins).
- Defaults (the binary's `Agent.state`, and `opencode debug agent <name>` with an empty config): every agent starts from `"*": "allow"`. `build` adds nothing, so edit and bash run without asking. `plan` sets `edit` to `deny`, but allows writes to `.opencode/plans/*.md` without asking, and leaves `bash` at `allow`. The docs (https://opencode.ai/docs/agents/#plan) say plan sets edits and bash to `ask`; the 1.18.33 code does not.
- On Lawrence's Mac, `~/.config/opencode/opencode.json` has `"permission": "allow"`. Because the user's rules come last, `plan` there allows every edit and every command without asking.
- A user config `{"permission": {"edit": "ask", "bash": "ask"}}` makes `build` ask before each edit and each bash command, but MCP tools, plugin tools, webfetch and the `explore` subagent's tools stay `allow`. acpmux cannot see the merged rules: they come from the global config, a project `opencode.json` and `.opencode/` in the workspace, `OPENCODE_CONFIG_CONTENT`, and agent files.
- Result: no opencode mode qualifies.

`webAskingModes` in config.json (written by the local user, never over a WebSocket) adds modes per family. WARNING: a mode added there lets paired devices start that mode without a per-action prompt. If `webAskingModes` ever gets a Settings row, the Settings lead must show the same warning.

### Ignored config entries and mode drift

The table lives in `src/web_modes.rs`, with `NON_ASKING_MODES` (the "Not accepted" column) next to it under the same sources. A `webAskingModes` entry that names a non-asking mode, for any family, is ignored with a warning. The daemon logs the merged table once at start and once on each config reload (`web asking modes: claude=[default,plan] ... refused=[codex,opencode]`).

### Web control follows the current mode

The Web controls a session (`session/prompt`, `_acpmux/permission_respond`, `_acpmux/permission_group_respond`, `session/set_mode`, `session/set_config_option`, and `_acpmux/handoff_start`, which prompts its target) only while the session's CURRENT mode is in its family's row, whatever wrote that mode: a new or loaded session, a resume, a pool claim, an internal `hub.set_mode`, a harness switch, or the harness itself. A session in a mode that does not ask refuses Web control with error data `{"reason": "remote.mode_not_asking", "mode", "harness", "family"}`, so a paired device can say why. A session that reports NO mode (no `modes`, no `mode` config option) counts as asking for the mode rule.

The permission settings must ask too (PERMISSIVE-MODE-NATIVE-CONFIRM amendment, 2026-10-05): the session's effective policy (its own, else the daemon default) must be `ask` or `deny-all`, and its rules may not auto-approve (any `autoApprove` entry, or `default: approve`). Otherwise Web control is refused with `{"reason": "remote.policy_not_asking", "policy", "rules", "harness"}`. This covers a session with no mode, and `approve-all` under any mode. While the daemon default is being written, the check fails closed and asks for a retry. The chat allowance ("allow for this chat", granted by the local user) never answers in a Web turn: each turn records who prompted it (`TurnInfo.control`; a Web steer makes the running turn a Web turn; a turn adopted after a restart counts as Web), and every eligible permission in a Web turn still asks. A Web permission answer allows once or denies once only: an `allow_always` or `reject_always` option and the group decision `allow_chat` are refused with `remote.lasting_grant_refused`, so the Web never creates a lasting grant. The mode, sticky and policy rules are one function, `Hub::web_control_verdict`, used by the guard and again at dispatch under the meta lock, which every policy, rules and mode write also takes. Web reads (attach, watch, events, info) stay allowed; the unix socket and LocalApp keep full control (`hub/web_control.rs`).

Every write of a session's mode state goes through one setter, `Hub::write_mode_state`, under the session's meta lock. A write that takes a session from a known asking mode to one that does not ask (drift) also sets a sticky flag and logs `remote_control_ended`; while it is set the Web is refused with `remote.mode_left_asking_table`, even after the harness returns to an asking mode by itself. Only a set_mode or set_config_option from the unix socket or LocalApp to an asking mode clears it (`remote_control_restored`); so does the daemon's own move of a new Web session to its asking default. The flag is in memory: after a restart the stateless rule alone applies.

The check runs in the remote guard and again where the action happens: when a queued prompt is dispatched (after the turn lock, under the meta lock) and when a permission answer is applied. A refused queued prompt is dropped before the harness sees it; its sender gets the error and the log records `prompt_refused`. A prompt or answer for a key the hub cannot resolve is refused for the Web, unless the key is a configured peer's session: then it is forwarded with `_meta.acpmux.via = "web"` and the owning daemon applies these rules on its own state. A Web `_acpmux/handoff_start` prompts the handoff's target: a target that does not resolve is refused; a NEW target (the handoff is still a draft, the target never prompted and never drifted) in its harness's own mode is first moved to its family's asking default by `settle_web_session_mode` (a family with none ends the target and refuses); any other target must pass the check.

Accepted residuals (2026-10-05): (1) the drift flag lives in memory only, so after a daemon restart only the stateless current-mode rule applies; (2) a harness mode change that arrives after the dispatch check, while the prompt is being sent, is not caught; the harness itself is the boundary there.

Residual (2026-10-05, prompt block `_meta`): a prompt content block's own `_meta` (and a nested resource's) reaches the harness from unix and LocalApp connections, which the guard does not check. Today's adapters (claude-agent-acp 0.74.0, codex-acp 1.10.0) read none of it, and the agent pane's relay strips it at any depth inside `session/prompt` blocks. A future adapter version must be checked for block `_meta` it reads before it is allowed.

### Peer origin

A peer daemon connects to `ws://127.0.0.1:<port>` through `ssh -W` (`peer.rs`), or straight to a `ws://`/`wss://` URL. Before, it sent only the dashboard token, read over ssh from the remote `~/.acpmux/config.json`. Every Web client has that token, so the token alone cannot prove a peer.

Design: each daemon start makes a peer token, 32 random bytes, in `ACPMUX_HOME/run/peer.token` (mode 0600, created with `O_EXCL` and `O_NOFOLLOW` in a private directory, removed at stop), the same way as the LocalApp token (`local_app::create_secret`). No RPC returns it. A connecting daemon reads it over the same ssh access, at each connect, in the same fixed command as the config (`cat ~/.acpmux/config.json; printf '\0'; cat ~/.acpmux/run/peer.token`), or for a `ws://` peer takes it from its local config (`peers.<name>.peerToken`, set by `_acpmux/peer_add` over the unix socket only). It sends the token in the `x-acpmux-peer-token` upgrade header next to `Authorization: Bearer <dashboard token>`. The listener makes the connection `Origin::Peer` only when both hold: the handshake checks the dashboard token, then exactly one header equal to the peer token, compared in constant time. Anything else stays `Origin::Web`: no header, an empty or wrong value, two headers, the token in the first frame or the query. The peer's own `_acpmux/peers` listing shows `servedAs: "peer"` or `"remote"`. An older remote daemon without a peer token serves a new daemon as Web, as before.

The peer path does not use the remote unix socket over ssh; it stays on the WebSocket listener.

PEER-ORIGIN-TRANSPORT (2026-10-05). The token must never cross a network in clear, so both sides check the transport. Server: a connection is `Origin::Peer` only when, besides the two tokens, its peer address is loopback (`127.0.0.0/8`, `::1`, or a v4-mapped loopback): the end of an `ssh -W` tunnel, or of a TLS terminator on the same machine. The acpmux listener has no TLS of its own, so a plain `ws://` connection from any other address stays `Origin::Web` even with a valid peer token. Client: a daemon sends the peer token only to an `ssh://` peer (through its tunnel), a `wss://` peer, or a `ws://` peer on a loopback host (`127.0.0.0/8`, `::1`, `localhost`); for any other `ws://` peer it connects without the header, is served as Web, logs once that the peer runs as remote because the transport is not loopback or TLS, and its `_acpmux/peers` entry shows `peerTokenWithheld: true`.

Control levels: `Control::Peer` (a proven peer, no `via: web`) gets local-level control here: no mode rule, the same as the unix socket for prompts, permission answers and mode sets. Every other remote rule in this document (refused methods, allow lists, roots, redaction) still applies to it as to the Web.

Threat note. Who can become Peer: whoever can read `ACPMUX_HOME/run/peer.token`, which is the same user (or root) on that machine, or anyone with that user's ssh access. They can already reach the unix socket, so Peer adds no power they lack. What a Web client cannot do: it gets no RPC that returns the token (tested over status, sessions, peers, harnesses, defaults, presets, schema, import), cannot import it (imports come only from the bundle directory), and gains nothing from the dashboard token. Residual risks: (1) a Web client that drives an agent in an asking mode could ask that agent to read the file; the agent's own permission prompt is the boundary, as for the dashboard and LocalApp tokens. (2) Closed by PEER-ORIGIN-TRANSPORT: the peer token is never sent over plain `ws://` to a non-loopback host, and the server never accepts one from a non-loopback address. (3) A peer forwards its own Web clients' requests with `via: web`; a peer daemon that drops the marker would bypass the current-mode rule, but such a daemon is the same user's code.

Peer and the current-mode rule: a peer acting for its own user (its unix socket) has no mode rule today. A peer is the same user on another machine, so the risk is lower than a paired device's, but it is not zero: whoever controls the other machine's unix socket can prompt every auto-approving session here. Decision: keep no mode rule for Peer now; revisit when peers can belong to different users or machines are shared.

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
- 2026-10-05: `Origin::Peer` with a per-launch peer token; Web control follows the current mode (`remote.mode_not_asking`); one setter for mode writes; the check repeats at dispatch; Peer keeps no mode rule.
- 2026-10-05: Web loads of peer sessions stay refused; `webAskingModes` stays, local user only; Web Codex `read-only` and Web opencode `plan` are accepted for now.
- 2026-10-06 (D10): no Codex or opencode mode asks before every edit and command; Codex `read-only` and opencode `plan` do not ask either. Both families are refused for the Web in code (`REFUSED_FAMILIES`), whatever config.json says; the agent pane hides Send for them on a remote or origin-unknown connection.

## Follow-ups

- (a) A per-action prompt that the Web user answers, so paired devices can run Codex and opencode. This is the long-term target; until a harness also has a verifiable ask-every-change mode, Codex and opencode stay refused (D10).
- (b) Check the source on the owning daemon for peer loads, so a Web load of a peer's session can be served.
- (d) Closed 2026-10-05: Web control follows the current mode, and peers keep theirs through `Origin::Peer`.
- (e) Closed 2026-10-05: `session_pool.rs` claims a pooled fake session (the non-Claude claim path, `absorb_session_response`) in a mode that does not ask, and a Web prompt is refused. The Claude-state claim path (`claude_state`) is driven too: `tests/fake_claude.py` reports the `--permission-mode` its profile pins, as Claude Code does, and a pooled Claude session claimed in `bypassPermissions` refuses a Web prompt.
- (f) Closed 2026-10-05: Web control requires an asking policy and no auto-approving rule (`remote.policy_not_asking`).
- (g) Closed 2026-10-06: the Codex `read-only` and opencode `plan` rows are removed, and both families are refused (D10).
- (c) `$/cancel_request` does nothing over a socket: requests run as spawned tasks, so a cancelled `session/new` still completes (the in-process case is covered by the pool's ClaimGuard).
