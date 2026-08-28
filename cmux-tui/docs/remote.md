# Remote daemon and clients

One remote daemon represents one operating-system user and one cmux instance. A connected device can access every workspace and can run arbitrary commands as that user. Workspace IDs organize work; they do not isolate clients. Use separate microVMs when clients need different trust boundaries.

The daemon supports multiple simultaneous humans, TUIs, GUIs, and coding agents. Each enrolled network client has its own device key and revocation record. SSH and owner-only Unix sockets may instead use their carrier identity. Removing SSH or operating-system access blocks new carrier sessions but does not terminate an existing session; the owner can disconnect it through the admin socket. WebSocket, relay, and Iroh connections always use cmux device authentication inside an end-to-end Noise session.

## Start a daemon

Build and start a named headless session:

```sh
cargo build -p cmux-tui
target/debug/cmux-tui server start --session dev --iroh --remote-ws 127.0.0.1:8443
```

The daemon prints its owner-only admin socket and every usable route. Runtime metadata and its stable identity live under the remote state directory. `--remote-state-dir`, `--remote-link-socket`, and `--remote-admin-socket` override those locations.

For local automation or an SSH/TLS-forwarded caller, enable the plain HTTP workspace API on loopback:

```sh
cmux-tui server start --session dev --remote-http 127.0.0.1:8765
```

Startup prints the HTTP address and its persistent owner-only bearer-token file. Every HTTP route requires `Authorization: Bearer <token>`. Plain HTTP refuses non-loopback binds so the token cannot cross an untrusted network without encryption. Use SSH port forwarding or a TLS reverse proxy for a remote caller. The bearer token grants the same full daemon authority as an enrolled device.

For a public direct WebSocket, keep the plaintext listener on loopback, terminate TLS in a reverse proxy, and advertise the externally reachable URL:

```sh
cmux-tui server start --session dev \
  --remote-ws 127.0.0.1:8443 \
  --advertise wss://cmux.example/v1/link
```

Configure the reverse proxy to send `wss://cmux.example/v1/link` to `ws://127.0.0.1:8443/v1/link`. Preserve the native client's lack of an `Origin` header because cmux rejects browser-origin upgrades. The advertised URL becomes an enrollment route hint. Binding plaintext directly to a non-loopback address requires `--remote-ws-insecure-bind` and should be limited to a trusted network.

`npx cmux` exposes the same commands when using the npm distribution:

```sh
npx cmux server start --session dev --iroh
```

Use `cmux server stop --session dev` to stop the local owner, its workspaces,
and the authenticated remote listeners embedded by `server start`. `cmux
remote stop --session dev` stops only a replaceable SSH sidecar; it refuses to
stop an embedded listener because that action would also terminate the local
owner and its workspaces. Use `cmux server status|reload-config|stop` for the
local owner. An absent local stop succeeds, but an absent local status fails.

Bare `cmux-tui` keeps normal tmux-style local behavior. Outbound remote-client
behavior begins only with `remote connect`, `remote ssh`, `remote forward`, or
`remote rpc`.

## Enroll and revoke devices

Create a single-device, five-minute invitation:

```sh
cmux-tui remote enroll create --session dev
```

The returned `cmux://enroll/...` URI contains a random 256-bit secret, the daemon public key, expiry, and route hints. It can be opened as a deep link or encoded as a QR code. Store a copied URI in an owner-only file and pass the filename so the secret does not appear in process arguments:

```sh
chmod 600 invitation.txt
cmux-tui remote connect --invite-file invitation.txt --device-name macbook
cmux-tui remote enroll pending --session dev
cmux-tui remote enroll approve <invitation-id> --session dev
```

`--invite-file -` reads exactly one line from stdin. This leaves subsequent stdin lines available to `rpc`. Inline `--invite` and positional invitation URIs are rejected because shells and process inspection can expose those forms.

Invitation startup stays alive through the invitation's remaining lifetime and the five-minute approval window. `--connect-timeout-seconds` can impose a different bound, and canceling the client also cancels connection setup.

Approval binds the invitation to the first device key that claimed it. That same device may retry failed secondary lane setup for 60 seconds without another approval. A different key cannot reuse the invitation.

`cmux-tui remote enroll create --advertise <route>` replaces the daemon's generated invitation route list. Repeat the flag to supply every desired fallback. Every route named by `--relay-route` must also appear in this explicit `--advertise` list. Prefer server-level `--advertise` when the route should be added to the automatically discovered Iroh, relay, WebSocket, and Unix routes.

Inspect or revoke access without restarting the daemon:

```sh
cmux-tui remote enroll devices --session dev
cmux-tui remote enroll connections --session dev
cmux-tui remote enroll revoke <device-id> --session dev
cmux-tui remote enroll disconnect <device-id> <session-id> --session dev
```

Revocation closes an enrolled device's live sessions and rejects its key in the future. Carrier sessions have synthetic `carrier:*` device IDs and no persistent device record, so use `connections` followed by `disconnect` for a live carrier session. Other devices remain connected. Every enrolled device has full daemon authority, including all workspaces.

## Connect directly or over SSH

Connect through any route printed by the daemon:

```sh
cmux-tui remote connect ws://127.0.0.1:8443/v1/link
cmux-tui remote connect 'iroh://<node-id>?relay_url=<url>&direct_addrs=<addr>'
cmux-tui remote connect unix:///path/to/link.sock
```

An invitation tries its explicit route followed by its ordered route hints. A known enrolled or carrier daemon can reconnect without copying a route by using `cmux-tui remote connect --daemon <fingerprint>`. Run `cmux-tui remote known-daemons` to list names, fingerprints, authorization modes, and routes. A Unix hint is promoted only when its socket exists on the client machine; an unreachable Unix path from a remote host is tried last. cmux Noise authentication, pinned daemon-key, and protocol failures stop fallback. Provider connection failures, including rejected SSH or relay credentials, may try another route.

Iroh defaults to `--iroh-path auto`, which probes direct IP paths and retains relay fallback. `direct-only` disables relay transports and requires `--iroh-address`. `relay-only` disables IP transports and requires `--iroh-relay`. The constrained modes are useful for policy enforcement and path verification; they fail instead of silently using the other path type.

`cmux-tui remote ssh` uses SSH directly, matching the command the user chose. The npm form is `npx cmux remote ssh user@linux-server --session dev`.

```sh
cmux-tui remote ssh user@linux-server --session dev
```

The SSH path probes for `~/.local/bin/cmux-tui`, then carries framed data over SSH stdio. It keeps a durable headless mux owner and a replaceable remote sidecar as separate processes. Existing terminal panes therefore survive sidecar replacement. If the named tmux-style session already has a live mux socket, the sidecar attaches without creating a second session. Otherwise cmux starts the user-scoped mux owner on demand.

If the binary is absent or reports an understood incompatible probe, an npm-backed release or nightly binary runs its exact embedded npm distribution version and installs it under the remote user's home directory. Source builds, raw commit-addressed artifacts, PyPI-only builds, and other binaries without an npm bootstrap stamp fail with an instruction to preinstall the same binary; they never substitute an older npm release. An unrecognized legacy probe fails closed; use explicit `--upgrade` from an npm-backed binary to force the pinned install and replace an SSH-managed sidecar. npm verifies the pinned package integrity, and a post-install probe checks the distribution, npm bootstrap, and protocol versions. Release CI verifies that the packaged binary reports the same distribution and npm bootstrap version. Automatic install requires Node.js 18 or newer, `npx`, registry access, and write access to `--remote-binary`; the published Linux packages use static musl binaries and do not require a glibc runtime. Use `--no-install` to require a preinstalled binary. A running sidecar is never silently replaced or restarted.

`--upgrade` explicitly installs the pinned distribution, stops an SSH-managed sidecar through its owner-only admin socket, waits for complete cleanup, and reconnects through the new binary. Terminal panes survive. Remote clients and forwards disconnect, sidecar-owned RPC processes terminate, and RPC workspace handles and route IDs reset. The durable mux owner continues running its previous binary until the user explicitly restarts the full session. Manually started embedded `cmux-tui server start` processes are refused because stopping one would terminate its mux workspaces. Use `--remote-state-dir` on every SSH command when the remote daemon uses a non-default state directory.

Every command that selects SSH as its initial route performs the same probe and automatic install before starting its authenticated connection. This includes a raw `ssh://` route passed to `connect`, `forward`, or `rpc`. The bootstrap runs outside the short carrier-reattachment deadline, so installation can finish without making later keystroke-path reconnects wait on package setup. A later SSH fallback is expected to use the binary installed by an earlier SSH connection or by the server owner. These commands accept `--session`, `--ssh-binary`, `--remote-binary`, `--remote-state-dir`, repeated `--ssh-arg` values, `--upgrade`, and `--no-install`. Repeat `--session dev` on later connections to a non-main SSH session; the known-daemon record stores routes and keys, not the remote session name.

## Client option reference

`connect`, `ssh`, `forward`, and `rpc` share these connection options:

| Option | Effect and default |
| --- | --- |
| positional route | `ws`, `wss`, `unix`, `ssh`, `iroh`, or relay URL; invitation URIs must use `--invite-file` |
| `--invite-file <path>` | Read one invitation from an owner-only file, or one stdin line when the path is `-`, without putting the secret in process arguments |
| `--daemon <fingerprint>` | Select one known enrolled or carrier daemon when no route is supplied or several match |
| `--lanes <policy>` | `auto`, `single`, or `isolated`; default `auto`; only the `cmux-tui remote ssh` shorthand defaults to `single` |
| `--connect-timeout-seconds <n>` | Bound initial setup; ordinary connections default to 90 seconds and invitations include their approval window |
| `--device-name <name>` | Label a new enrollment; default is the local host name when available |
| `--state-dir <path>` | Override client identity and known-daemon storage |
| `--remote-state-dir <path>` | Select a non-default state directory on an SSH server |
| `--local-socket <path>` | Override the local mux-compatible socket created by the remote client runtime |
| `--headless` | For `connect` or `ssh`, print the local socket and keep the connection alive without starting the TUI; `forward` and `rpc` are already headless |
| `--headless --json` | Emit a credential-free JSON snapshot at startup and whenever the generation, state, lane bindings, provider, route, or selected Iroh path changes |
| `--iroh-relay <url>` | Override the Iroh relay routing hint |
| `--iroh-address <addr>` | Add an Iroh direct address; repeat for several addresses |
| `--iroh-path <mode>` | `auto`, `direct-only`, or `relay-only`; default `auto` |

Reconnect defaults are unlimited attempts, 100 ms initial delay, 5 s maximum delay, a 15 s timeout per attempt, full jitter, a 5 s heartbeat interval, and a 15 s heartbeat timeout. Override them with `--reconnect-attempts <n|unlimited>`, `--reconnect-initial-ms`, `--reconnect-max-ms`, `--reconnect-attempt-timeout-ms`, `--reconnect-jitter <full|none>`, `--heartbeat-interval-ms`, and `--heartbeat-timeout-ms`. The per-attempt timeout also deadlines each link's initial handshake on every dial, invitation dials included, so an endpoint that accepts the connection but never completes the cmux handshake is a terminal failure within that budget instead of holding the connection open; an invitation's enrollment-approval wait happens after the handshake and keeps its own longer window.

A single relay route needs `--relay-slot` and exactly one of `--relay-ticket-file` or `--relay-ticket-command`. For independent relay fallbacks, repeat groups of `--relay-route`, `--relay-slot`, and one credential source in occurrence order. A client or daemon accepts at most four relay registrations. Route-scoped credentials override an invitation credential for the same normalized route, and invitation credentials fill only routes without an explicit credential. Repeat `--relay-ticket-command-arg` immediately after its command to construct argv without a shell.

File, command, and Rust callback credential sources are queried for Register or Connect sockets and on provider-authentication retry. Relay-minted Join tickets authenticate circuit sockets. A credential is limited to 4096 visible ASCII bytes, and a credential command has a ten-second default deadline. Sources remain in memory for reconnects within that client process. They are not persisted in known-daemon state, so pass them again on each later `remote connect` invocation.

`remote enroll` actions are `status`, `create`, `pending`, `approve <invitation-id>`, `deny <invitation-id>`, `devices`, `connections`, `revoke <device-id>`, and `disconnect <device-id> <session-id>`. `remote enroll connect` is a compatibility alias for `remote connect`. Shared owner options are `--session`, `--state-dir`, `--admin-socket`, and `--json`. `connections --json` reports each daemon-observed generation, connected or reconnecting state, remaining resume lease, and lane-to-physical-link bindings. `create` accepts `--ttl <seconds>` (capped at five minutes), repeated `--advertise`, and up to two relay bootstrap records. Repeat `--relay-route`, `--relay-slot`, and `--relay-ticket-file`; values pair by occurrence order.

## Transport and lane policy

All providers implement the same ordered binary-link contract. Provider credentials only permit routing; Noise authenticates cmux devices and encrypts service data.

| Route | Carrier identity | cmux device auth | Typical use |
| --- | --- | --- | --- |
| `unix://` | Owner UID | Carrier allowed | Local clients and SSH proxy target |
| `ssh://` | SSH account | Carrier allowed | Explicit direct SSH |
| `ws://`, `wss://` | None or TLS server | Required | Direct server or TLS reverse proxy |
| `iroh://` | Iroh endpoint | Required | Mobile, NAT traversal, relay fallback |
| `relay+ws://`, `relay+wss://`, `relay+https://` | Relay ticket | Required | Native central relay |
| `relay+do://` | Relay ticket | Required | Cloudflare Durable Object relay |

Use `--lanes auto`, `--lanes single`, or `--lanes isolated` on any client command. `auto` is the default. On providers with cheap parallel links it uses one physical path for interactive traffic, one for control, and one shared by tunnel and bulk traffic. `single` minimizes connections. `isolated` creates one physical link per lane. `cmux-tui remote ssh` defaults to `single` because explicitly choosing SSH implies one direct SSH path; an explicit `--lanes` overrides it.

Reconnect retries forever by default and resumes reliable sequence numbers. Bound or tune it per command:

```sh
cmux-tui remote connect <route> \
  --reconnect-attempts 8 \
  --reconnect-initial-ms 50 \
  --reconnect-max-ms 2000 \
  --reconnect-attempt-timeout-ms 15000 \
  --reconnect-jitter full \
  --heartbeat-interval-ms 5000 \
  --heartbeat-timeout-ms 15000
```

Set `--heartbeat-interval-ms 0` to disable active liveness checks. Reconnect cycles through all known route candidates, including a different provider type, while the pinned daemon Noise key and logical session stay unchanged. The daemon retains disconnected replay state for 120 seconds by default; `--remote-resume-lease-seconds` accepts 1 through 86400.

Interactive process input, control RPCs, cancellation, and bulk file, search, patch, diff, and replay operations use separate persistent service streams. Requests execute concurrently under per-lane admission limits, so a process wait or large diff cannot serialize unrelated control work. Non-cancelable mutations preserve receive order within their traffic class. Calls started concurrently across traffic classes are intentionally unordered; dependent operations await the earlier response. Interactive input is ordered but does not wait for an unrelated command response. Bulk backpressure cannot occupy the interactive queue.

Directory sorting, search scanning, patch parsing/application, and diff formatting run through a bounded blocking pool whose concurrency budget leaves one logical CPU available when the host has more than one. Large RPC JSON uses a separate two-worker codec pool, while the cancellation stream stays inline and rejects oversized messages. Workspace shutdown closes both pools, waits for admitted work, and returns an explicit residual count for any job that exceeds the bounded drain window, so an aborted request cannot make a continuing patch invisible to lifecycle cleanup.

## Forward a remote development server

The daemon resolves routes inside an opened workspace, and the client exposes only a loopback listener by default:

```sh
cmux-tui remote forward <route> \
  --workspace-root /srv/project \
  --host 127.0.0.1 \
  --port 3000 \
  --listen 127.0.0.1:0 \
  --scheme http
```

The command prints a local URL such as `http://127.0.0.1:53142`. A cmux WebView can load that URL without knowing whether the underlying path is SSH, Iroh, direct WebSocket, or a relay. Each accepted local TCP connection becomes a separate `tcp-tunnel` stream. Tunnel bytes are not replayed after carrier failure, so the local browser reconnects the affected HTTP connection while the cmux session resumes.

## Coding-agent RPC

`workspace-rpc` exposes the primitives needed by a coding-agent frontend. A CLI caller can send one request or JSON Lines:

```sh
cmux-tui remote rpc <route> --request \
  '{"type":"open-workspace","root":"/srv/project"}'

printf '%s\n' \
  '{"type":"capabilities"}' \
  '{"type":"list-workspaces"}' |
  cmux-tui remote rpc <route>
```

The CLI accepts a bare workspace request and prints a bare workspace response. A direct service client uses the request ID and result envelopes documented in the [remote RPC contract](../spec/remote-rpc.md).

The authenticated HTTP listener exposes that same handler at `POST /v1/workspace-rpc`. Send the normal request-ID envelope as JSON. It also exposes a text-oriented patch action for Codex-compatible callers:

```sh
TOKEN="$(tr -d '\r\n' < /path/printed/by/daemon/workspace-http.token)"
curl --fail-with-body \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: text/plain' \
  --data-binary @change.patch \
  'http://127.0.0.1:8765/v1/workspaces/w:abc/apply-patch?dry_run=false'
```

The direct action accepts the native Codex `*** Begin Patch` body or a unified diff. Use `/v1/workspace-rpc` when file preconditions or another workspace action is needed. HTTP and authenticated remote sessions share one `WorkspaceService`; patch parsing, limits, snapshotting, commit, and rollback are not transport-specific.

The protocol includes:

- bounded stat, read, atomic write, directory, and search operations with opaque pagination cursors;
- patch application with per-path content-digest preconditions, dry runs, rollback details, and old/new digest results;
- Git status, bounded unified diff, and typed structured diff files and hunks;
- explicit pipe processes for ordinary tool calls, plus explicit PTYs with daemon-wide discovery, bounded styled terminal snapshots, resize, signal, input, EOF policy, wait, deadlines, output retention, and replay cursors;
- operation, workspace, and detached process lifetimes, including operation-wide finish and explicit workspace close;
- opaque UUID request IDs, idempotent input write IDs, safe cancellation for read/wait operations, and typed replay-gap errors;
- workspace-scoped TCP routes and one tunnel stream per forwarded connection;
- versioned computer-use capability, invocation, result, and cancellation types.

Computer-use execution reports unavailable until a platform provider is wired. Clients can negotiate typed screenshot, accessibility-tree, pointer, keyboard, text-input, and scroll capabilities without changing the transport. A future executor uses the dedicated `computer-use` service, including its own cancellation and bulk-media flow, so a screenshot or long action cannot block PTY input.

Process input uses monotonically increasing `write_id` values and at most 32 KiB per request. Larger stdin producers chunk their data; the bound gives the interactive scheduler a fairness point between writes while duplicate `write_id` values remain idempotent.

Omitting process `io` selects writable pipes. Use `"io":{"type":"pipes","stdin":false}` for a noninteractive command that should start with stdin closed, or an explicit `pty` object for a terminal program.

Coding-agent clients allocate an opaque process UUID before awaiting network work, reserve its event stream, then send `spawn-process-with-handle`. This prevents immediate output from racing subscription and leaves the UUID available for reconnect if the client future is canceled. Duplicate active, completed, or reserved UUIDs are rejected. Metadata, lookup, cursor, duplicate-reservation, and capacity failures reject a process stream before it opens with the original stable error. Replay gaps open successfully and remain structured terminal events. Completed replay records are bounded independently from the 64 active-process slots.

`list-processes` lets a new frontend rediscover handles without prior UUID state. The catalog is daemon-wide because every authenticated client already has authority over every daemon workspace and explicit process handle. It contains active records plus the 64 most recently completed records. Each descriptor includes workspace, a bounded display-only command and argv preview, cwd, lifetime and operation, PID, pipe or PTY kind, current PTY size, running or exited state, and replay range. Environment values are never included.

`snapshot-process-terminal` returns a bounded Ghostty-rendered PTY viewport with styled runs, cursor, default colors, scrollback count, and the exact process-output sequence applied to it. A reconnecting GUI subscribes after `through_sequence`. If retention advances before that subscription and reports a replay gap, the GUI requests another snapshot and retries. Pipes return `not-a-pty`. Snapshots above 65,536 cells or 4 MiB of encoded JSON are rejected.

Output drain has separate idle and absolute deadlines. Actual output resets the idle deadline; reader completion does not. A read failure, reader-task failure, idle deadline, or total deadline emits typed `output-truncated` metadata before `exit`. Unix PTY slave closure is normal EOF. PTYs are explicitly unavailable on non-Unix daemons.

Unix pipe and PTY processes terminated by a signal report a null exit code and the numeric POSIX signal in wait responses and terminal events.

## Native relay

Build the central Rust relay and set its signing secret:

```sh
export CMUX_RELAY_HMAC_SECRET="$(openssl rand -base64 48)"
SLOT="$(openssl rand -hex 16)"
cargo build -p cmux-relay
```

Mint separate daemon and client provider tickets into owner-only files for one opaque slot:

```sh
RELAY_STATE="${XDG_RUNTIME_DIR:-$HOME/.cache}/cmux-relay-dev"
install -d -m 700 "$RELAY_STATE"
install -m 600 /dev/null "$RELAY_STATE/register.ticket"
install -m 600 /dev/null "$RELAY_STATE/connect.ticket"
target/debug/cmux-relay ticket --permission register --slot "$SLOT" \
  > "$RELAY_STATE/register.ticket"
target/debug/cmux-relay ticket --permission connect --slot "$SLOT" \
  > "$RELAY_STATE/connect.ticket"
```

Run ticket commands in a shell that has the same `CMUX_RELAY_HMAC_SECRET`. Then start the foreground relay in a dedicated terminal with that secret:

```sh
target/debug/cmux-relay serve --bind 127.0.0.1:8787
```

A public TLS proxy must forward `/v1/relay`, the WebSocket Upgrade headers, and the `Authorization` header to the loopback relay without injecting an `Origin` header.

Register the daemon:

```sh
cmux-tui server start --session dev \
  --relay relay+wss://relay.example \
  --relay-slot "$SLOT" \
  --relay-ticket-file "$RELAY_STATE/register.ticket"
```

Production deployments can refresh short-lived tickets from an owner-readable file or an argv-based credential command. The source is queried for each Register or Connect WebSocket and provider-authentication retry:

```sh
cmux-tui server start --session dev \
  --relay relay+wss://relay.example \
  --relay-slot <slot> \
  --relay-ticket-file "$XDG_RUNTIME_DIR/cmux-relay-register.ticket"

cmux-tui remote connect relay+wss://relay.example \
  --relay-slot <slot> \
  --relay-ticket-command cmux-relay-token \
  --relay-ticket-command-arg connect
```

The Rust API also accepts an asynchronous callback for a broker-backed credential source. Credential values, command output, authorization headers, and relay protocol ticket fields are redacted from debug output and errors.

Deliver the owner-only Connect ticket file to the client, then connect with `relay+wss://relay.example` and the same slot:

```sh
cmux-tui remote connect relay+wss://relay.example \
  --relay-slot "$SLOT" \
  --relay-ticket-file "$RELAY_STATE/connect.ticket"
```

Provider tickets are short-lived abuse-control capabilities. They never grant workspace authority and cannot decrypt tunneled traffic.

For first-time mobile or off-network enrollment, embed a short-lived Connect ticket and relay route in the invitation:

```sh
cmux-tui remote enroll create --session dev \
  --relay-route relay+wss://relay.example \
  --relay-slot "$SLOT" \
  --relay-ticket-file "$RELAY_STATE/connect.ticket"
```

The ticket is sensitive and exists only to reach the daemon for enrollment. The invitation still requires the Noise secret, daemon-key pin, and owner approval. After enrollment, pass a fresh file, command, or callback credential on each new client invocation for long-lived relay access instead of reusing the invitation ticket. The same invitation format accepts `relay+do://` routes.

A daemon can register with native and Durable Object relays at the same time. Groups pair by occurrence order:

```sh
cmux-tui server start --session dev \
  --relay relay+wss://relay.example \
  --relay-slot <native-slot> \
  --relay-ticket-file /run/user/1000/native-register.ticket \
  --relay relay+do://relay-worker.example \
  --relay-slot <do-slot> \
  --relay-ticket-command relay-token \
  --relay-ticket-command-arg do-register
```

An invitation may carry at most two short-lived relay bootstrap records. When `enroll create` also uses explicit `--advertise` flags, include both relay routes in that list.

## Cloudflare Durable Object relay

The Worker under `relays/cloudflare-do` implements the same relay v2 control messages. Use a URL-safe 128-bit-or-larger slot and the same Register or Connect ticket claims as the native relay:

```sh
cmux-tui server start --session dev \
  --relay relay+do://relay-worker.example \
  --relay-slot <base64url-slot> \
  --relay-ticket-file /path/to/register.ticket

cmux-tui remote connect relay+do://relay-worker.example \
  --relay-slot <base64url-slot> \
  --relay-ticket-file /path/to/connect.ticket
```

The provider derives `/v1/slots/<slot>/control`, `/v1/slots/<slot>/connect`, and `/v1/circuits/<circuit>`. It sends the provider or Join ticket in the WebSocket `Authorization` header and repeats it in the relay control protocol for defense in depth. Durable Objects supply slot-to-circuit indirection and hibernation. They remain a relay provider under the WebSocket carrier contract, rather than becoming a separate session transport.

See [`../relays/cloudflare-do/README.md`](../relays/cloudflare-do/README.md) for deployment, ticket, quota, and alarm details.

## Reliability and security limits

Reliable frames carry a session ID, generation, lane, sequence, acknowledgement, stream ID, flags, and bounded payload. Reconnect performs a fresh Noise handshake, verifies the pinned daemon key, fences old generations, exchanges receive cursors, and replays unacknowledged mutations once. TCP tunnel streams bind to one generation and close both sockets when that generation changes; tunnel bytes and ambiguous writes are never replayed. Graceful clients send an authenticated close frame, while crashed sessions expire after the configured resume lease.

Per-lane replay buffers and queues are bounded. A client is limited to 256 open logical streams, 32 MiB of aggregate unread stream data, 64 active service handlers, and 128 active workspace requests. The daemon limits sessions, handshakes, and approvals. Workspace resources cap roots, processes, PTYs, routes, file sizes, patch size, diff size, search work, and retained process output. A local forward accepts at most 128 connections by default and enables TCP low-latency mode on both ends.

Services that use more than one lane place setup and terminal markers on every declared lane. The receiver buffers early data until every setup marker arrives and reports closure only after every terminal marker arrives, so isolated carriers cannot reorder stream setup or teardown. If a terminal frame cannot enter a saturated queue before its deadline, cmux closes that logical connection to release the peer's resources.

Each authenticated client session has its own request-ID and lifecycle namespace. Disconnect cleanup cancels its requests and removes its non-detached processes, route registrations, and workspace leases. Workspace roots remain in the daemon-global catalog after every client disconnects, and a later authorized client can list and attach to them; the last explicit `close-workspace` removes a root. This ownership is cleanup bookkeeping, not authorization: any connected client can list all workspaces and address known workspace, process, or route IDs.

Headless clients, port forwards, and headless daemons exit with the terminal runtime error if their authenticated session or service bridge stops. They do not remain alive after losing the remote runtime.

Transport diagnostics have two perspectives. The client snapshot owns its selected outbound provider and Iroh's live direct or relay path. The daemon snapshot owns generation, resume state, and authenticated lane bindings. The daemon does not infer the outbound provider because SSH reaches it through a Unix sidecar and a TLS proxy can deliver WSS as plaintext WebSocket ingress. Snapshotting is opt-in and takes no locks on the normal keystroke scheduling path.

Direct plaintext WebSocket binds are loopback-only unless explicitly enabled. Prefer a TLS reverse proxy for a public endpoint. The direct listener bounds raw HTTP sockets and requires an upgrade within ten seconds. Native and Cloudflare relays enforce global and per-slot admission, short-lived scoped tickets, join deadlines, circuit idle expiry, and bounded queues.

## Terms

- Carrier: the byte transport, such as SSH, WebSocket, QUIC, or a Unix socket.
- Lane: a priority and flow-control class for interactive, control, bulk, or tunnel traffic.
- Noise: the end-to-end authenticated encryption handshake above every carrier.
- Relay ticket: a short-lived capability to use relay infrastructure, not permission to use cmux.
- Resume cursor: the highest contiguous reliable sequence received on one lane.
