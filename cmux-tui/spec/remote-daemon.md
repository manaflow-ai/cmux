# Remote daemon protocol

Status: implementation contract for protocol 1.

## Authority boundary

One daemon represents one operating-system user and grants access to every cmux workspace it owns. An enrolled client can run arbitrary commands as that user, so workspace filtering is navigation, not a security boundary. Stronger isolation belongs in a separately managed microVM. Container or cgroup membership does not reduce daemon authority.

The daemon supports multiple concurrent human and agent clients. Each enrolled device has an independent application key and revocation record. Relay tickets, discovery records, and route hints never become daemon authorization. A trusted owner-only Unix socket or SSH carrier may authorize a carrier-mode session without enrollment. Removing operating-system or SSH access prevents new carrier sessions; the owner admin channel terminates an already connected carrier session by device and session ID.

## Layers

Remote access has four boundaries:

1. A provider produces ordered, bounded binary links. Providers include direct WebSocket, the Rust relay, the Cloudflare Durable Object relay, and Iroh.
2. The secure session authenticates devices, encrypts frames end to end, assigns logical streams, applies flow control, acknowledges mutations, and reconnects.
3. Services expose mux compatibility, workspace RPC, process streams, and TCP routes.
4. Frontends use services without inspecting provider routes or credentials.

Unix sockets and SSH stdio may use carrier authentication because the operating system or SSH server already authenticated the user. Hosted and direct network providers require application device authentication. Relay providers additionally require a short-lived provider ticket for abuse control.

## Lanes and latency

Each frame declares one lane:

- `interactive`: keystrokes, PTY input, resize, focus, interactive action RPCs, and acknowledgements.
- `control`: metadata and lifecycle RPCs, service setup, cancellation, and heartbeats.
- `bulk`: file contents, diffs, terminal replay, browser frames, and computer-use media.
- `tunnel`: forwarded TCP bytes.

Lane policy is configurable as `single`, `isolated`, or `auto`. `single` multiplexes all lanes on one link. `isolated` opens an independent link per lane. On a parallel-link provider, `auto` maps interactive and control to independent links and maps tunnel plus bulk to a third link. A provider without useful parallel links uses one prioritized link. Bulk backpressure must never consume the interactive queue reserve. The current TUI records a private input-to-write latency histogram and backpressure failures for tests; a public telemetry surface with queue depth and provider labels is not implemented in protocol 1.

A service declares every lane one logical stream may use. A multi-lane stream acknowledges setup on each declared lane before exposing buffered application data, and closes only after a terminal marker has arrived in order on every declared lane. This per-lane barrier prevents an isolated fast carrier from overtaking setup or teardown on another carrier. A failed terminal send retries under a bound, then closes the logical session so the peer cannot retain an unreachable stream.

## Authentication and enrollment

The daemon owns a stable Noise static key. Each client generates a stable device key. Persistent secrets are stored in an owner-only directory and files use owner-only permissions.

An invitation contains the daemon public key, a random 256-bit secret, an identifier, an expiry of at most five minutes, and non-authoritative route hints. It may contain at most two relay bootstrap records, each with a normalized relay route, opaque slot, and short-lived Connect ticket. A connecting client proves the invitation secret in a PSK-authenticated Noise handshake. The daemon records a pending request containing the device name, device key fingerprint, and requested full-control authority. The owner approves it through the owner-only admin socket. Approval binds the invitation to the claiming device key and adds that key. The same key may retry failed secondary lane setup during a 60-second grace period; another key cannot reuse it. A six-digit manually entered code is insufficient by itself and must use a PAKE before this flow is exposed.

Clients preserve invitation route order and may try more than one carrier. A reachable same-host Unix socket is promoted, while a remote or missing Unix path is demoted. Provider connection and provider-credential failures may fall through to the next hint. cmux Noise or device authentication failure, a pinned daemon-key mismatch, protocol incompatibility, generation exhaustion, or an explicitly closed session stops fallback.

Enrolled sessions use a mutually authenticated Noise handshake. The daemon checks the device key and revocation generation before accepting application frames. Reconnect performs a fresh handshake and resumes application sequence numbers. Revocation closes live connections and invalidates cached grants.

Relays only see slot identifiers, opaque circuit identifiers, timing, lane count, endpoint addresses, and ciphertext sizes. They cannot decrypt service names, workspace identifiers, commands, paths, or stream contents.

## Reliability

Every reliable frame carries a session identifier, lane, monotonically increasing sequence number, cumulative acknowledgement, logical stream identifier, flags, and payload. Senders keep bounded per-lane replay buffers. Reconnect resends unacknowledged reliable frames after the receiver reports its last contiguous sequence, and the receiver suppresses duplicate frames before service delivery. Concurrent reuse of an active request identifier is rejected. Repeated process-input `write_id` values return the original result without writing twice. File and patch retries use explicit content preconditions.

Interactive input, RPC mutations, process lifecycle, and file mutations are reliable. Newly committed frames schedule cumulative acknowledgements asynchronously, so application delivery does not wait on the reverse carrier write. Duplicate frames are acknowledged before suppression. Telemetry and superseded screen snapshots may be lossy. TCP tunnel streams bind to their connection generation. A generation change resets both endpoints, discards tunnel replay state, and closes each affected local connection so the application can reconnect. Resumable workspace and mux services remain open across the same carrier reconnect.

Clients send an authenticated logical-close frame during graceful shutdown. An abrupt carrier loss retains the logical session and its replay state for a finite, configurable lease, 120 seconds by default. A successful reconnect atomically publishes the new generation, then closes the prior physical link outside lifecycle locks so blocked old-generation readers wake and move to the replacement.

The client exposes a credential-free connection snapshot containing the published generation, state, lane bindings, selected provider route, and provider path. Iroh reports whether its currently selected path is direct IP or relay. The owner-only daemon admin socket exposes a separate snapshot containing generation, connected or reconnecting state, remaining resume lease, and daemon-observed lane bindings. The daemon does not infer the client's provider from ingress because SSH sidecars and TLS terminators intentionally change the final ingress carrier.

## Provider contract

The Rust relay and Durable Object relay implement the same provider protocol:

1. A daemon keeps one control WebSocket registered for an opaque slot.
2. A client requests an opaque circuit and waits.
3. The relay notifies the daemon over the control socket.
4. The daemon opens the circuit WebSocket.
5. The relay forwards binary frames between the paired sockets without interpreting them.

Each circuit carries one physical lane or a `single` multiplexed link. The Durable Object stores only lease metadata and socket attachments needed after hibernation. Ciphertext and application replay state remain at the endpoints. The Rust relay keeps circuit bytes in memory and may use an external directory only for slot-to-shard routing.

Iroh supplies the same binary-link contract through authenticated QUIC, NAT traversal, and relay fallback. Its endpoint identity is a route credential, not daemon authorization. Clients default to automatic path selection. Direct-only mode disables relay transports and requires an explicit direct address; relay-only mode disables IP transports and requires an explicit relay URL. A constrained mode fails closed when its required route hint is absent. Direct WebSocket terminates the same application handshake even when TLS is present.

## Services

`mux-control` carries the existing JSON-lines attach protocol as a compatibility byte stream.

`workspace-rpc` opens independent interactive, control, cancellation, and bulk streams. Requests execute concurrently under per-lane admission control, and responses return on the request's lane. Cancellation uses its own persistent control-lane stream and remains admissible when normal request slots are full. Non-cancelable mutations preserve receive order within one traffic class. Concurrent requests across traffic classes have no implicit ordering, so a client awaits a response before issuing a dependent operation. The exact service names, envelopes, request fields, response shapes, and examples are defined in [`remote-rpc.md`](remote-rpc.md). It exposes:

- open/list workspace roots and capabilities;
- stat, bounded read, atomic write with content preconditions, directory listing, search, and patch application;
- Git status and structured or unified diff;
- pipe processes and explicit PTY processes, with stdin, resize, signal, wait, output sequence numbers, and operation/workspace/detached lifetime;
- workspace routes that name a remote host and port, plus per-client loopback listeners and per-connection tunnel streams;
- capability discovery for future browser and computer-use input, screenshots, accessibility trees, and media streams.

Pipe I/O is the default and recommended mode for tool calls. Omitting `io` selects writable pipes; an explicit pipes object can start with stdin closed. PTY allocation is explicit and appropriate for interactive programs, terminal emulation, or commands that change behavior when attached to a terminal.

Computer-use RPC variants are negotiation placeholders and report unavailable in protocol 1. A future executor runs on the dedicated `computer-use` service with independent action, cancellation, and bulk-media flow control; it must not share the PTY-input request stream.

Request identifiers, operation identifiers, and cleanup ownership are scoped to one authenticated client session. Session loss cancels that client's active requests, closes its routes, releases its workspace leases, and terminates its non-detached processes. The daemon keeps workspace roots in its global catalog after the last client disconnects, matching tmux-style persistence; an explicit final `close-workspace` removes a root. These scopes do not restrict authority: another authenticated client can list all workspaces and use any explicit workspace, process, or route identifier it learns.

## SSH and lifecycle

`cmux-tui ssh <host>` preserves normal SSH expectations: SSH is the transport and authentication mechanism. It starts or discovers a durable user-scoped mux owner and replaceable remote sidecar on demand, then runs a stdio proxy to the sidecar's Unix socket. An npm-backed release or nightly binary auto-installs its exact verified npm version under the remote user's home directory when needed. Source, raw commit-addressed, and PyPI-only builds require a matching preinstalled remote binary because they have no npm bootstrap stamp. Automatic bootstrap never substitutes a different published version. It never replaces or restarts a running sidecar without explicit `--upgrade`.

The SSH bootstrap probes the exact distribution and remote protocol versions. A live named mux socket gets a remote sidecar, preserving the existing tmux-style session; a missing mux socket creates a durable bare headless mux owner before starting the sidecar. Startup is serialized with an owner-local lock. `--upgrade` force-installs the pinned distribution, stops only an SSH-managed sidecar, waits for its runtime metadata cleanup, and reconnects. It interrupts clients, forwards, and sidecar-owned workspace RPC resources but preserves terminal panes. Embedded daemons are refused, and the mux owner needs an explicit full-session restart to run the new binary. Client cancellation interrupts connection setup, and invitation setup uses a deadline long enough for invitation expiry plus local approval.

Short-lived relay provider credentials are refreshable independently of the authenticated cmux session. Built-in sources include a static ticket, an owner-managed file, an argv-only command with a deadline, and an asynchronous broker callback. Implementations fetch again for each Register or Connect socket and provider-authentication retry. Relay-minted Join tickets authenticate circuit sockets. Credentials are bounded, intermediate values are zeroized, authorization headers are marked sensitive, and ticket-bearing protocol messages are redacted.

Local bare `cmux-tui` retains tmux behavior and attaches to the local session when one exists. Network commands choose their named provider by default. Command-line flags configure lane policy, reconnect limits, install behavior, and relay routes. The current `cmux-tui.json` schema has no remote section.

## Compatibility and exclusions

The existing protocol-9 Unix JSON-lines and opt-in WebSocket text endpoints remain supported while clients migrate. They are compatibility transports and do not define the new provider abstraction.

This protocol does not create, destroy, snapshot, or authorize VMs. A daemon may run inside a VM supplied by another component, but VM lifecycle remains outside cmux-tui.
