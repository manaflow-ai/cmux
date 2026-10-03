# cmux next: local identity (package P8)

Implements spec identity-and-permissions.md sections 3, 5 and 6 (decisions D5, D16,
D20) on the local machine: launch credentials, the actor stamp, the localhost
listener rule, tailnet mode and HTTP MCP. Owner: P8 lead. Status: design, slices
below land one at a time.

## 1. Threat model

The local trust boundary stays the OS user (D5 local mode). Every local socket is
0600 in a user-only directory, and every check below assumes that.

| Attacker | Can do today | After P8 |
| --- | --- | --- |
| A web page in any browser on this Mac | open `ws://127.0.0.1:<port>` and `fetch` loopback HTTP (WebSocket has no CORS); DNS-rebind a name to 127.0.0.1 | refused at the handshake: a foreign `Origin` or a non-loopback `Host` is a 403 before any byte of the protocol |
| A process of another OS user | nothing on Unix sockets; TCP listeners rely on a token | unchanged on sockets; every TCP listener requires a token |
| A tailnet peer | nothing unless a listener binds the tailnet address | only peers on the local allow list (section 6) |
| An agent in a cmux terminal or ACP session (same uid) | anything the user can do, attributed as plain CLI | the same reach for now (D20 class rules come later), but every op it makes is attributed to its terminal or ACP session |

Not a goal: protection from same-uid malware. A same-uid process can read another
process's environment and the key file, so the launch credential is attribution,
not a sandbox. It must never be the only gate on an op that is not already open to
the user's processes.

## 2. Launch credential

The session host (cmux-tui daemon) holds one launch key and mints

```
cmuxlc1.<kid>.<claims>.<mac>
claims = base64url(JSON {v:1, host, terminal | acp_session, agent?, iat})
mac    = base64url(HMAC-SHA256(key[kid], "cmuxlc1.<kid>.<claims>"))
```

- `host` is the session public id; exactly one of `terminal` (terminal public id)
  or `acp_session`; `agent` is an optional principal (for example `agent_mux`),
  set only when the local user mints it.
- Terminals: `spawn_prelude` puts it in `CMUX_LAUNCH_CREDENTIAL` next to
  `CMUX_TUI_TERMINAL_ID`, so every child and grandchild has it. It is never
  logged, and the terminal launch spec omits its value like every other env value.
- ACP sessions: acpmux asks the session host `credential.mint {acp_session}` on its
  Unix socket and puts the result in the agent's environment.
- Verification stays in the session host: `credential.verify {credential}` returns
  `{valid, actor}`. It is valid only when the MAC matches a known key, `host` is
  this session, and the terminal or ACP session is still live. Closing a terminal
  revokes its credential.
- `terminal.for_pid {pid}` walks the process ancestry to the terminal whose child
  started it. Owners that see a peer pid but no credential (the CUA host) use it.

Key storage: 32 random bytes in `<state dir>/identity/launch-keys.json` (dir 0700,
file 0600), `{current: kid, keys: {kid: base64}}`. The key never leaves the
daemon process. Keys survive daemon restarts because terminal hosts do.

Rotation: `credential.rotate` (local user only, never an agent, `mcp.expose:
never`) makes a new current key and keeps one previous key for verification. A
second rotation drops the oldest key, which revokes credentials minted under it.
Live terminals get no new environment, so after two rotations their credential
has an unknown `kid` and their calls are attributed by pid ancestry or to the user
(section 3), never refused for that reason.

## 3. The actor stamp

Reviewed with the daemon owner (6 objections, accepted by the coordinator
2026-10-03); the rules below include them.

Shape:

| kind | id | other fields | who sets it |
| --- | --- | --- | --- |
| `user` | `user_local` (local) or the account user id | - | the connection |
| `terminal` | terminal public id | `host`, `agent?` | a verified launch credential, or pid ancestry |
| `acp_session` | acpmux session id | `host`, `agent?` | a verified launch credential |
| `app` | app id (`<publisher>/<name>`) | `host`, `version`, `on_behalf_of` (a `user` actor) | ONLY the app supervisor; never accepted from a caller |
| `frontend` | install id of the native app on THIS machine | `host` | a LOCAL-socket connection proved by the app's install key (below); remote links never count; agents cannot use it |

Rules:
- Every request may carry `credential` (the CLI and `cmux mcp` copy
  `CMUX_LAUNCH_CREDENTIAL` into each request). The dispatcher verifies it per
  request and builds the actor. A caller can never send an actor directly.
- One rule for stale credentials: a bad MAC, a foreign `host`, or a closed terminal
  or ACP session is refused with `credential_invalid`. An unknown `kid` (dropped by
  rotation) is not an error: the request falls back to pid ancestry (slice 4) or to
  the user, as if no credential was sent.
- `credential.verify` and the per-request check read liveness from mux state
  BEFORE `commit_state` takes the registry and state locks, so verification never
  runs under those locks.
- Durable records carry the actor explicitly, never through ambient state:
  `WorkspaceMutation` gets `actor: Option<Actor>`, set by the dispatcher.
  `resource_mutations` gets an `actor` column and the resource journal record gets
  an `actor` field next to `origin` and `idempotency_key` (beside them, not in the
  payload). Projections never depend on the caller. Every durable write path must
  set it; a test fails when a mutation path leaves it empty.
- The actor is NOT part of the idempotency fingerprint. The same key sent again
  with a different credential is a replay and keeps the FIRST actor (tested).
- Thread-local scope is allowed only for non-durable reads (logs, diagnostics).
  Note: server.rs spawns `handle_message` on its own thread, so such a scope must
  be set again on that thread.
- Respawn and restart: `tab-split-respawn-v1` leaves a fresh tab with a new
  terminal public id, so its child gets a new credential; the moved tab keeps its
  id and credential. A restart that keeps the terminal public id keeps the old
  credential valid, because it still names the same terminal (checked in slice 3;
  if restart changes the id, the old credential is refused as closed).
- Frontend proof (daemon owner review, accepted 2026-10-03). `DaemonLauncher`
  passes the app's install key id to the daemon over an inherited pipe fd at
  spawn (never argv or env). After an app restart the app proves itself with
  `client.hello {install_id, proof}`, proof = HMAC-SHA256(Keychain install key,
  daemon nonce). A daemon the app did not start has no frontend until the app
  pairs again. Known gap: DEV builds are ad-hoc signed, so their Keychain item
  ACL does not keep other same-uid processes out; only signed builds give a real
  frontend proof.
- Precedence on one request: request credential > connection identity
  (`frontend`) > pid ancestry (slice 4) > `user`. Requests the app forwards for
  someone else (for example `action.run` for a CLI call) carry `forwarded: true`
  and are not the app's own.
- Actor-gated secrets (first user: the remote desktop host's per-launch token).
  `secret.register {name, allow: [kinds]}` (the secret's owner; `mcp.expose:
  never`) and `secret.release {name, purpose}`:
  - `allow` takes only positively proven kinds (today: `frontend`). `user` is
    not valid. There is no `app_ids` until app identity has its own proof.
  - `secret.release` refuses any request that carries a credential (valid or
    not, so no unknown-kid fallback), any forwarded request, and (after slice 4)
    any peer pid that descends from a terminal. It refuses an idempotency key: a
    retry asks again.
  - Secrets never go through `commit_state`: no journal payload, no replay
    result. Values live in their own 0600 store or the Keychain. The journal
    gets only an audit record `{op, name, purpose, actor}`.
  - The remote desktop token's allow list is `frontend` only, and it ships only
    after the frontend proof, the secret store and these refusals land.
- The app (`action.run`) receives the credential, verifies it with the session
  host, and records the actor in `ActionInvocation`.
- Local conversations keep `user_local` for unbound connections until their own
  slice (section 8): changing the conversation principal to the terminal or agent
  actor needs a migration rule for existing `user_local` rows and the Home lead's
  agreement.

## 4. Localhost listeners

One shared pure check (`cmux-tui/crates/cmux-local-auth`) runs at every HTTP and
WebSocket handshake, before the protocol starts:

1. `Host` must be a loopback name or address (`127.0.0.1`, `[::1]`, `localhost`,
   with any port) or, in tailnet mode, the node's tailnet names. Otherwise 403.
2. `Origin`: absent is allowed (non-browser clients). Present must equal one of the
   listener's own origins (`http://127.0.0.1:<port>`, `http://localhost:<port>`) or
   an origin the listener names explicitly. `null` is always refused.
3. A token is mandatory, compared in constant time. No listener starts without one.

| Listener | Token | Origin and Host |
| --- | --- | --- |
| cmux-tui daemon `--ws` | `--ws-token` or a pairing credential in the first frame; a pairing request needs the user's approval (both exist) | added; `--ws-allow-origin` / `--ws-allow-host` add a web frontend dev server or a `tailscale serve` name |
| acpmux web and WebSocket (`127.0.0.1:47811`) | made mandatory: a config with no token gets one; header or `?token=` | added; own origin (dashboard), `cmux-agent://pane` (the agent pane, once it loads from that scheme: a `loadFileURL` page sends `Origin: null`, measured on macOS 27), and `websocket.allowed_origins` |
| cmux-remote workspace HTTP | bearer token file (exists) | every `Origin` refused (no browser client); no `Host` rule, because it is meant to sit behind SSH forwarding or a TLS reverse proxy that keeps the public name |
| cmux-remote direct WebSocket `/v1/link` | link handshake (exists) | every `Origin` refused (exists, tested); no `Host` rule, same reason |
| HTTP MCP (new, section 7) | scoped MCP token | built in |

Notes from the slice 2 review:
- Origins are compared after normalization (`parse_origin`: lowercase, no
  trailing slash, no default port). `--ws-allow-origin` and
  `websocket.allowed_origins` refuse or skip values that are not
  `scheme://host[:port]`.
- acpmux reads `websocket.allowed_origins` and `websocket.allowed_hosts` when the
  listener starts; a change needs a daemon restart.
- The Debug agent pane dev server (`CMUX_NEXT_AGENT_PANE_DEV_URL`) sends its own
  origin; add it to `websocket.allowed_origins` in `~/.acpmux/config.json`.
- acpmux peers that connect with no token stop working once the remote side has
  this change; `acpmux peer add ... --token T` or an ssh peer (which reads the
  remote token) is required.
- The acpmux dashboard reads a request head up to 32 KiB (large localhost
  cookies); a larger head is refused.

Out of scope, recorded so nobody adds them by mistake: port forwards that carry the
user's own service (cmux-remote `LocalPortForward`, `loopback_forward`, the app's
`RemoteLocalhostProxy`). They forward a service the user chose to expose and must
not rewrite its auth. The remote browser proxy already has per-launch basic auth and
a WebSocket token.

## 5. Tests that prove it

Each listener has a test that sends a valid token with `Origin: https://evil.example`
and expects a refusal, one with no token and expects a refusal, and one with a
rebinding `Host` and expects a refusal. The launch credential has unit tests for
mint, verify, tamper, wrong host, closed terminal and rotation, and an integration
test that a terminal child sees `CMUX_LAUNCH_CREDENTIAL`, makes a state mutation
through the CLI, and the journal record names its terminal as the actor.

## 6. Tailnet mode

`cmux tailnet allow <login|node>` / `deny` / `list` keep a local allow list in the
daemon state dir. A listener bound to a tailnet address asks the local Tailscale
daemon who the peer is (LocalAPI WhoIs on the peer address) and refuses peers not
on the list, before the token check. No central service. The listener's Host check
accepts the node's MagicDNS name and tailnet addresses.

## 7. HTTP MCP

`cmux mcp serve --http 127.0.0.1:<port>` serves the same tools as stdio over MCP
Streamable HTTP. Tokens: `cmux mcp token create --name N [--scope read|mutate|all]
[--expires D]` prints a token once and stores only its SHA-256 with its scope;
`cmux mcp token list|revoke`. Every request checks Origin/Host (section 4), the
bearer token, its expiry and revocation, and the scope against the tool's catalog
risk class. Token ops are `mcp.expose: never`.

## 8. Slices

1. This design.
2. `cmux-local-auth` crate and the Origin/Host/token check on the daemon `--ws`,
   acpmux and both cmux-remote listeners, with refusal tests.
3. Launch key, `CMUX_LAUNCH_CREDENTIAL`, `credential.verify|mint|rotate`, the CLI
   and MCP send it, `WorkspaceMutation.actor`, the `resource_mutations` column and
   the journal field. Then the `frontend` actor (launcher fd, `client.hello`
   proof, `forwarded`) and `secret.register|release` with its own store and
   audit record (daemon owner review with this slice).
4. `terminal.for_pid` and pid-ancestry stamping; acpmux mints per ACP session.
5. App side: `action.run` verifies the credential and records the actor.
6. Tailnet mode. 7. HTTP MCP with scoped revocable tokens.
8. Conversation principal from the actor, with the `user_local` migration rule
   (needs the Home lead).
