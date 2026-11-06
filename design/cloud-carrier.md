# Cloud carrier: one way from the Mac to a Cloud machine

Leo, 2026-11-06, verbatim:

> Wait, but isn't this kind of stupid? Like, still? How do you PROPERLY do this? Do we want the proper way
> yet? Okay, what is the actual, like, end-to-end-to-end-to-end flow? And what? Like, how do the secrets
> actually pass through? Like, how encrypted are they? What is the encryption method? And in general, what
> is our architecture right now? Like, fully? Just I know that we use—we were using, and still for some
> bits are using the WireGuard or whatever. I told you guys to, like, start removing, start deleting the
> code on the branch, or whatever. Or, I mean, we can work on our own branch. That's the thing. We can work
> on our own branch and just delete swaths of the classic code, and, like, we can redo a lot of things from
> scratch to go, like, a nicer greenfield.

This doc answers his questions about today first, then gives the design that replaces it and lists what
gets deleted. The work happens on `lane/cloud-carrier`, branched off `feat-cmux-next`. Classic's deployed
`web/` and `/api` on `main` don't change. The backend half lands in cmux-platform.

The sources are cmux `feat-cmux-next` at `1405ced8` and cmux-platform `main` (2026-11-06). Paths starting
`link/` are under `cmux-tui/crates/cmux-tui/src/link/`. Paths starting `P:` are in cmux-platform.

## Leo's questions, answered

Leo, 2026-11-06, verbatim:

> But is this a good way to do it? Why is there a second? Okay, but how many network hops are we doing
> actually? Like, did we come up with, like, simpler designs or whatever? So that's the single path,
> right? Like we're not testing random other paths, are we?

### Why are there two tunnels?

The outer tunnel is Freestyle's. Its WireGuard gateway is the only way from a Mac into a Freestyle VPC,
and the gateway decrypts what it carries. If we stopped there, Freestyle could read every byte, and
Freestyle firewall rules on our one shared account would be the only lock on the door. The inner
WireGuard session runs from the Mac to the VM, so the gateway only forwards ciphertext, and our own keys
and tokens decide who gets in. leo-workspace `research/freestyle-network-vs-overlay-2026-11-05.md` (§6)
makes that case.

It is a sound reason, but it's the expensive way to get there:

- **Two key systems.** There's a Freestyle tunnel per device and our own WireGuard keys inside it.
- **Two provisioning flows.** Every device needs its own tunnel, plus a firewall rule per device, per
  machine, per port. Each team mesh is capped at 50 devices.
- **An access list that lands late.** The list that admits a device lands 10 to 30 s after create. That
  delay caused the first-dial failures cmux#37155 and cmux#37171 patched. Leo's own failed start-chat
  came from it, and so did the hourly probe that ran out of device slots.

All of that is the cost of joining every device to Freestyle's network. The carrier below gets the same
end-to-end property with one encrypted session and no network membership at all.

### How many hops does a byte take?

These are counts of the processes that forward or decrypt a byte between the Mac and the VM. The
round-trip times are measurements we have; a cell says "not measured" where we don't have one.

| Path | Hops, Mac → VM | Round trip, measured |
|---|---|---|
| Relay chat (today) | Mac → cmux-api Worker → platform Worker → `MachineRelay` DO → the VM's WebSocket, which leaves through Freestyle's egress: **3 Cloudflare hops** | Not measured for this path. The start matrix's rows show replies of 5.6 to 19 s (below), and the network is a small part of that. |
| Native link (today) | Mac → Freestyle gateway (SF) → VM: **1 hop, 2 WireGuard layers** | 2.18 ms p50, 2.51 ms p99 near SF. From Santa Clara, 8-13 ms. Frankfurt is 146 ms and Tokyo 106-112 ms, because there's one gateway for the world. The inner layer adds one round trip (2-8 ms) to the first byte. (Research note §3, from TR 13.1.) |
| Exec and files (today) | Mac → Freestyle API → VM, or Mac → our Worker → Freestyle API → VM: **1 or 2 hops** | Not measured as a hop. A resume's first exec measured 571-590 ms p50 (research note §2). |
| **Carrier (this design)** | Mac → Cloudflare edge Worker → `RelayCircuit` DO → the VM's WebSocket: **2 Cloudflare hops** | 7.8 ms p50 and 14.2 ms p99 when the DO is in the client's colo, and 24.5 ms from a neighboring colo (research note §3, from the same DO relay code). Throughput was 21 MB/s batched. |
| Freestyle tunnel alone, with app tokens | Mac → Freestyle gateway → VM: **1 hop, 1 layer** | About the native link's 2.2 ms, without the inner layer's one round trip. Not measured on its own. |

None of these numbers is a carrier measurement on production yet. The Mac slice adds the carrier mode
to the start matrix, which then measures the carrier's real rows, and every slice reports them.

### Which single path, of the simpler designs?

Three designs can each be the only path.

| | (A) Freestyle tunnel as the underlay, our WireGuard and tokens on top (what ships today; the research note's pick) | (B) The Freestyle tunnel alone, with app-layer tokens | **(C) A Noise session over our DO relay (this design)** |
|---|---|---|---|
| Hops, Mac → VM | 1 hop, 2 layers | 1 hop, 1 layer | 2 Cloudflare hops, 1 layer |
| Round trip near SF | 2.2 ms | about 2.2 ms | 7.8-14 ms; 24.5 ms from a neighboring colo |
| Far away (Tokyo, Frankfurt) | 106-146 ms, all through one SF gateway | same | The nearest Cloudflare edge, then the DO's colo. Not measured from far away. |
| First reply today | 5.6-19 s on the rows that answer. Five of the twelve rows listed fail on the link: two never connect and three fail fast with `login_unverified`. | Same machinery minus our receiver | Not measured yet. The network adds about 5-20 ms per round trip over (A), against replies of seconds. What it removes is the access-list wait and the policy reads, which are the failures. |
| Who can read plaintext | The Mac and the VM. Freestyle sees ciphertext. | **Freestyle**: the gateway decrypts, and the VPC carries plaintext. | The Mac and the VM. Cloudflare and our relay see ciphertext and routing metadata. |
| Who decides access | Our token, the receiver's policy, and Freestyle's access list, all three of which must agree | Freestyle's access list plus our token | Our grant, checked on the VM. The relay ticket only routes. |
| A phone | Needs its own enrolled tunnel, an access-list entry per machine, and in-app userspace WireGuard. It counts against the 50-device mesh cap. | Same | A `wss` connection plus a grant. `cmux-remote` already speaks `relay+do`, so no device enrollment is needed. |
| A locked Mac | Works while the screen is locked: keys use `AfterFirstUnlockThisDeviceOnly` (`AcpmuxMacApprover.swift:184`). Fails after a reboot until the first unlock. | Same | Same. The carrier's Noise key uses the same Keychain class. |
| A paused machine | Tunnel traffic wakes it: 1.72 s p50, 6.79 s p95 | Same | The Connect route starts it, the way `/chat` does today: resume 0.42-0.44 s p50 after a short pause, 3.6-7.9 s after longer ones. The VM registers again on resume. |
| Machines that aren't Freestyle VMs | No. Freestyle doesn't forward tunnel to tunnel. | No | Yes: any machine that can open a `wss` connection |

**The pick is (C).**

- **It's the only option that's one path for every device.** A Mac, a phone and a fleet box all
  connect the same way, without joining Freestyle's network and without an access list that lands late.
- **No server can read the traffic.** (B) gives that up, so (B) is out.
- **(A) is today's design.** Its failures are the per-device network membership: the late access list,
  the device cap, and Worker machines the fallback can't reach. Keeping it means keeping all of that.
- **The cost** is 5 to 20 ms more per round trip near SF, against replies that take seconds. If the bulk
  file rows of the start matrix show the relay throughput costs real time, the session's `Bulk` lane can
  move to a direct route later, under the same keys and the same session. That would be an upgrade
  inside the carrier, not a second path to test.

The research note picked (A) when the question was Freestyle's network against our overlay, and the
overlay was the code that shipped. Its own numbers say the 12 s start isn't network time (about 0.3 s
is). Since then, the failures have come from the per-device membership that (A) needs.

### Are we testing one path?

Not yet. Today a start-chat sends the prompt over the relay, and it sends the folder copy, the seed and
the secrets over the link. When Native fails, the app falls back to the plain link. So one matrix row
exercises two or three paths.

With the carrier:

- **No fallback.** A build with `CMUX_NEXT_CLOUD_CARRIER=1` has no fallback. If the carrier fails, the
  start fails and names the step it didn't get past.
- **Each row proves its route.** Each start-matrix row records the route it used, and a row whose route
  isn't `carrier` fails.
- **Then only the carrier.** When the flag turns on in slice 7, the matrix runs only the carrier, and
  the same series deletes the other paths.

## Today

### The architecture, fully

There are four ways to reach a Cloud machine. Each has its own auth and its own timers.

| Path | Who connects to what | Auth | Encryption | What uses it |
|---|---|---|---|---|
| **Relay** | The VM's `cmux-host` holds a WebSocket to the `MachineRelay` Durable Object (`cmux-host/src/cloud/relay.rs:365`). The Mac holds no socket. It POSTs each prompt to `/v1/cloud/machines/:id/chat` and reads NDJSON back (`CloudRelayChat.swift:162`). | VM: a 600 s ES256 token, minted by signing a challenge with the install key (`P:cloud/CloudAuth.ts:243`). Mac: the person's login token. | TLS only. The DO sees prompts and replies in plaintext. It stores and logs none of them (`P:cloud/MachineRelay.ts:18`). | Chat from `cmux cloud start-chat` and `cloud relay-chat` |
| **Native link** | The Mac's `cmux-wg` (userspace boringtun WireGuard) opens a tunnel to the Freestyle gateway with the device key (`link/mesh_cloud.rs:85`). Inside it, a second WireGuard session goes to the VM's VPC address on UDP 4101 (`link/native_route.rs:144`). Inside that, one TCP stream per dial starts with a `ServiceHello` line (`link/dial.rs:112`). | An Ed25519 link token (`P:cloud/LinkToken.ts`, at most 300 s). The VM's receiver checks it against a policy it re-reads from the platform every 120 s at most (`cmux-link/src/native_token.rs:51`, `P:cloud/receiver/Policy.ts`). The Freestyle mesh ACL must list the device (`P:cloud/vmapi/Network.ts:59`). | WireGuard (Noise IKpsk2: X25519, ChaCha20-Poly1305, BLAKE2s), twice | Folders, git seed, start-chat, machine update, SSH, desktop, Cloud Secrets |
| **Plain `cmux link`** | The same link code with a route from `connect_info` (`link/mesh_cloud.rs:37`). Worker machines get no route there, so it fails for them (`CloudNativeRouteHolder.swift:68`). | Same tokens | WireGuard | Fallback when Native fails to start |
| **Exec and files** | `cmux cloud machine-io` calls Freestyle `exec-await` with a client session, or falls back to the Worker, which calls the provider (`cli/cloud_machine_io.rs:1`). The app still calls classic `cmux.com/api/vm` for tunnel enrollment, resize, snapshot, fork, firewall and domains (`CloudTunnelHub.swift:203`, `CloudHandlers+Machine.swift`, `CloudHandlers+Network.swift`). | Person token; Freestyle client session | TLS | Login copy, receiver scripts, file browse |

### The end-to-end flow of a start-chat

1. **Create.** The create call returns. A pending create retries at 1, 2, 4 and 8 s (`CloudMachineCreateFlow.swift:82`).
2. **Boot and bind.** The VM boots, and `cmux-host` binds with its install key. `connect_info` polls every
   250 ms for up to 60 s for the bind (`P:cloud/ConnectWait.ts:9`). `link_token` polls every 500 ms for up
   to 30 s for a ready receiver (`:47`).
3. **Mesh ACL.** The ACL that admits the Mac's device lands 10 to 30 s or more after create, off the create
   path (`P:cloud/vmapi/Network.ts`). Until it lands, Freestyle drops UDP 4101.
4. **The receiver's first policy read.** It takes 5 to 8 s and retries from 1 s, doubling to 30 s
   (`link/native_process.rs:160`). With no peers yet, the next try was about 60 s away. cmux#37171 shortens
   that.
5. **The Mac's link.** The Mac waits for the link for up to 180 s, redialing every 1 to 10 s
   (`CloudStartSession.swift:424`, `CloudWait.swift:34`). Each dial gets 5 s (`link/dial.rs:28`). Before
   cmux#37155, boringtun sent one handshake initiation per 5 s dial, so a dropped first initiation failed
   both dials.
6. **Login copy, then the folder copy.** The login copy goes over exec. Its guest check retries every 3 s,
   up to 30 times (`CloudCredentialTransfer.swift:59`). The folder copy goes over the link.
7. **Prompt.** On the relay path, the Mac first brings up the link and copies the login, capped at 15 s,
   and only then POSTs the prompt (`CloudStartSession+RelayChat.swift:58-65`). That's the "relay send waits
   on the link". The DO waits up to 90 s for the host socket (`P:cloud/MachineRelay.ts:36`).

Every one of those waits is a guess about when something else will be ready. The resend fix (cmux#37155)
and the peerless re-read (cmux#37171) make the guesses shorter, but they're still guesses. Nothing tells
the Mac "the machine is ready".

### How secrets pass, and how encrypted they are

| Secret | Path | On the wire | Who sees plaintext |
|---|---|---|---|
| Cloud Secrets (`cmux cloud secret set`) | Mac Keychain. The app types the values into a short-lived terminal on the VM over the native link, with echo off (`CloudMachineSecrets.swift:6`). | WireGuard, Mac to VM | The Mac and the VM. No server sees them. They land in a 0600 file, `~/.config/cmux/machine-secrets.env`, which a snapshot can capture. |
| Harness logins (Claude, Codex) | Base64 JSON in a file write, sent over `machine-io` to Freestyle `exec-await`, or through our Worker on fallback (`CloudCredentialTransfer.swift`, `P:cloud/MachineGuest.ts`) | TLS | Freestyle, and our Worker in memory on fallback. They land as a plaintext file on the VM. |
| Env-sheet secrets | The webview sends them to the platform over TLS. The Worker seals each value with AES-256-GCM under a random data key, wrapped by a KEK (`P:environments/SecretSealer.ts`, `P:crypto/Envelope.ts`), and stores it in a DO. | TLS | The Worker, in memory at seal time. They aren't delivered to machines yet (`P:environments/CloudEnvironments.ts:526`). |
| Vault (`cmux machine vault set`) | Mac to Worker. AES-256-GCM at rest under a per-user key wrapped by a master KEK (`P:vault/UserKey.ts`). The Worker decrypts on each read and returns plaintext to a granted VM. | TLS | The Worker, on every read |

So only one secret kind is end to end today, and only because it rides the WireGuard link. The others are
protected only by TLS, and the provider or our Worker holds the plaintext.

## The design

### One carrier

A Cloud machine is reached one way: **a cmux-remote session between the Mac and the machine's session
daemon, carried over a relay slot the platform keeps per machine.** Both sides dial out over `wss`. The
platform pairs the two sockets and forwards opaque frames.

All of this exists and has tests. None of it is new crypto:

- **The session.** `cmux-remote` already runs a Noise session (`Noise_XX_25519_ChaChaPoly_BLAKE2s`, from
  the `snow` library: `cmux-remote/src/crypto.rs:19`) with device keys, reconnect with resume, and lanes
  (`cmux-tui/docs/remote.md`).
- **The services.** The session carries `MuxControl` (agent sessions, so chat), `WorkspaceRpc` (files,
  search, patch, diff), `ProcessStream`, `TcpTunnel` (SSH and desktop sockets) and `TerminalBytes`
  (`cmux-remote-protocol/src/rpc.rs:120`).
- **The carrier.** `relay+do://` is already a supported route
  (`cmux-remote/src/provider/relay.rs:1657`). It speaks the slot protocol in
  `cmux-remote-protocol/src/relay.rs` (`Register`, `Connect`, `Allocated`, `Incoming`, `Join`, `Ready`),
  with batched frames (cmux#21990).
- **The VM side.** The VM's session host already starts that daemon with `--remote-ws`
  (`cmux-host/src/remote_entry.rs`). Adding a relay route to it is a flag.

What's new is small:

1. **One relay slot per machine, on the Durable Object relay we already have.**
   `cmux-tui/relays/cloudflare-do` implements the slot protocol: `RelaySlot` and `RelayCircuit`, with
   hibernation, ticket checks at the edge and in the object, and per-slot abuse limits. It forwards opaque
   binary records it can't read. It replaces `MachineRelay`.
   - cmux-platform deploys it, the same way it took over CloudDO, and mints its HMAC tickets from auth
     we already have:
     - a `Register` ticket for the VM's install token (the `vm` claim, `P:cloud/CloudAuth.ts`);
     - a `Connect` ticket for the person's token on a machine they may use, which is the same check as
       today's `/chat` route.
   - It needs one change. Today a `Connect` that arrives before the daemon is answered `daemon-offline`
     (`slot.rs:357`), which makes the client retry. The slot will instead park the Connect, within its
     existing pending-allocation limit, and allocate it the moment the daemon registers.
2. **The machine's keys travel in its signed bind record.** At bind, the VM sends its daemon's Noise
   static public key. The platform stores it in the machine record and hands it to the Mac, which pins it
   (`ClientHandshake.expected_daemon`) before its first handshake.
3. **The Mac proves who it is with a carrier grant.** This is a new cmux-remote client auth mode,
   beside `Enrolled`, `Invitation` and `Carrier` (`cmux-remote/src/crypto.rs:78`).
   - The grant is a compact JWS signed with the same Ed25519 keyset as today's link tokens
     (`P:cloud/LinkToken.ts`), typed `cmux-carrier+jwt`.
   - It names the machine, the team, the person, the services, an expiry of at most 300 s, a `jti`, and
     the SHA-256 of the Mac's Noise static public key.
   - The Mac sends it in the handshake payload. The daemon verifies it locally against the keyset
     `cmux-link` already fetches and caches (`cmux-link/src/keyset.rs`), refuses it on replay, and checks
     that the key it names is the one that just finished the Noise handshake. Its services become the
     session's `ServiceAuthority`.
   - The grant only admits a session. An established session outlives it, so a slow platform read can't
     drop a session, and revocation is a pushed retire.
4. **The Mac's Cloud connection is a cmux-remote client** in the cmux-tui process the app already runs.
   It's Rust. The Swift side only shows its state.

### One readiness event, pushed

The machine's own `Register` on its slot is the readiness event. No one polls for it.

- The Mac opens its `Connect` as soon as the create call returns. The relay slot holds it, hibernated,
  until the VM registers, and then pairs the two at once (`Allocated`/`Incoming`). The time from the VM's
  register to the Mac's first frame is one WebSocket hop.
- The client has to wait as long as the slot does. Today cmux-remote's relay client gives up on an
  allocation after 15 s (`cmux-remote/src/provider/relay.rs:989-1013`, set at
  `cmux-tui/src/remote_runtime.rs:445-450`). The Cloud connection sets that wait to the time left on the
  connect deadline, and the slot sends a `Parked` control frame when it holds a Connect, so the client
  can tell a parked request from a dead relay. A client that doesn't know `Parked` ignores it and keeps
  today's behavior.
- The same event goes out on the machine state socket the app already has (`CloudMachineStatePush.swift`),
  so UI that shows "starting" flips without its own wait.
- These go away: `ConnectWait.ts`'s 250 ms and 500 ms polls, the 180 s link wait and its 1-10 s redial,
  the receiver's policy reads on a timer, and the gap where the mesh ACL hasn't landed yet. The carrier
  doesn't use the Freestyle mesh at all.

### One deadline

A connect has one deadline, measured from the moment the person sends: 180 s, the same window today's
successful starts get (`CloudStartSession.swift:424`), so a machine that's slow but works today still
works. It covers create, boot, register and the Noise handshake together. Each slice reports the
start matrix's p95 and max connect times. Once the carrier's max is well under the window, the deadline
comes down to fit what was measured, in its own PR.

- A dropped socket inside that window reconnects with exponential backoff from 50 ms up to 2 s, with full
  jitter. cmux-remote's `ReconnectPolicy` already does this.
- When the deadline passes, the Mac shows one error that names the step it didn't get past: the create,
  the register or the handshake.
- After the session is up, its resume lease (120 s by default) carries it across a network change or a
  machine pause without dropping the agent session.

### Chat, files and secrets on the same channel

- **Chat:** an acpmux session over `MuxControl`, the same as a local cmux session. The relay `/chat` POST
  and its separate NDJSON stream go away, and so does the link-then-POST order that made chat wait on the
  link.
- **Files:** folder copy and git seed run over `WorkspaceRpc` or a `Bulk`-lane stream. A big copy can't
  starve chat, because `Interactive` and `Bulk` are separate lanes.
- **SSH:** `TcpTunnel` to `127.0.0.1:22`, the target the native receiver uses today
  (`link/host_inbound.rs:227`).
- **Desktop:** `TcpTunnel` resolves only TCP host and port routes (`cmux-remote/src/services.rs:657-670`,
  `workspace/route.rs:18-24`), and the desktop is a Unix socket, `/run/cmux-rd/desktop.sock`. The route
  type gains a Unix-socket target that the daemon allows only for paths in a fixed allowlist (just the
  desktop socket), and only for the machine's owner, the rule the native receiver applies today. The
  native desktop path isn't deleted until this lands.
- **Secrets:** a `secrets-v1` request inside the session writes the named values to the 0600 file, and it
  carries harness logins too. Every byte crosses the platform inside the Noise session, so the Worker and
  Freestyle only see ciphertext. Nothing runs through exec, argv, a terminal or the file API. Secrets
  never appear in logs, PRs or fixtures, and the tests use generated values.

### What stays trusted

- The platform is still the key directory: it signs which daemon key belongs to which machine. If the
  platform were compromised, it could vouch for a wrong key. Today's link tokens trust the same keyset, so
  this is no weaker than now.
- The Mac pins a machine's key on first use, and a change after that refuses the handshake instead of
  trusting the new key.
- At rest on the VM, secrets are a 0600 file as today. Keeping them out of snapshots is a separate change.

### What it costs

- **A hop on every frame.** Every frame goes through a Cloudflare DO instead of straight to the VPC
  address. The batch e2e test (`cmux-remote/tests/relay_do_batch_e2e.rs`) gives keystroke echo latency.
  Each slice reports start-matrix numbers, and the folder-copy rows show any throughput cost.
- **A later direct path.** If the bulk rows regress, the session can move its `Bulk` lane to a direct
  route without changing the session, its keys or its auth. cmux-remote already cycles route candidates
  under one pinned key. That would be an upgrade inside this carrier, not a second path.
- **DO cost.** The relay bills Durable Object duration only while a frame is in flight. Idle sockets hibernate.

## What gets deleted

These are deleted on NEXT paths only: `feat-cmux-next` in cmux, and cmux-platform `main`.

cmux:

- `link/native_*` (route, process, receiver, broker, supervision), `link/mesh_cloud.rs`, `link/mesh.rs`'s
  Cloud gateway, `link/cloud.rs`, `link/cloud_broker.rs`, `link/enrollment.rs`, `link/receiver_deadline.rs`,
  and the native half of `link/host_inbound.rs`, with their tests.
- `cmux-link`'s `native_token.rs` and receiver policy, and `cmux-host/src/cloud/receiver.rs` and `relay.rs`
  (the JSON chat relay). The crates `cmux-wg`, `cmux-transport` and `cmux-wg-tun` lose their Cloud callers.
  They're deleted when nothing else imports them, and acpmux's Labs WireGuard is checked first.
- Swift: `NativeDeviceEnrollment.swift`, `CloudNativeRouteHolder.swift` (`CloudNativeFirstLauncher`),
  `NativeCloudLinkChild.swift`, `CloudTunnelHub.swift` (classic `/api/vm/tunnel`), `CloudRelayChat.swift`,
  `CloudStartSession+RelayChat.swift`, `CloudAppLinkRedial.swift`, the terminal-typing receiver in
  `CloudMachineSecrets.swift`, and the login-copy exec path in `CloudCredentialTransfer.swift`.
- `cmux cloud machine-io`'s use for login copy. The file browse moves to `WorkspaceRpc`, and then the
  command goes too.

cmux-platform:

- `cloud/MachineRelay.ts` and `MachineRelayRoute.ts`, replaced by the relay slot.
- `cloud/ConnectWait.ts`, `cloud/receiver/*`, `cloud/LinkTokenNative.ts`, and `connect_info`'s route offer
  in `cloud/Link.ts`.
- The Cloud use of `cloud/vmapi/Network.ts`'s per-device mesh ACL and the device enrollment behind it. That
  also ends the 50-device mesh limit, which broke the hourly probe.

The rough size is 25k lines across both repos, counted with `wc -l`.

## Slices

Each slice is about 800 changed lines and reports before-and-after connect times from the start matrix
(`goals/cloud-start-matrix.md`, owner `cloud-start-matrix`). The carrier runs behind
`CMUX_NEXT_CLOUD_CARRIER=1` until slice 7 makes it the only path.

1. **This doc.**
2. **The relay waits for the daemon.** `cloudflare-do`'s slot parks a Connect until Register and answers `Parked`; the client's allocation wait follows the connect deadline. A test
   showing a client that connects before the daemon gets paired, with no retry.
3. **Platform:** deploy the relay, mint Register and Connect tickets and carrier grants from the install and person tokens,
   and push readiness on the state socket.
4. **Guest:** the session host registers its relay route at boot, the bind carries the daemon key, and the daemon accepts carrier grants.
5. **Mac:** the app's Cloud connection runs as a cmux-remote client with one deadline. Chat goes over
   `MuxControl`. This is the first start-matrix carrier row.
6. **Files and secrets:** folder copy, seed, login copy and `secrets-v1` move onto the session.
7. **Flip and cut, one series.** The flag turns on, and the same series deletes, with no gap between them:
   - the plaintext relay chat (`MachineRelay`, `/chat`, `CloudRelayChat.swift`,
     `CloudStartSession+RelayChat.swift`, `cmux-host/src/cloud/relay.rs`);
   - the login copy over Freestyle exec (`CloudCredentialTransfer.swift`'s exec path, and `machine-io`'s
     use for it);
   - the link fallback (`CloudNativeFirstLauncher` and the plain `cmux link` route).

   Each PR in the series lands only after the one before it, and the flip PR stays held until the cuts are
   reviewed. Then the rest of the list above follows in two or three PRs, one per repo, with the Swift
   deletions split out.

The work is done when the carrier is the only path in NEXT and the start matrix is green on it.
