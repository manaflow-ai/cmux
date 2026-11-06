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
2. **The machine's keys travel in its signed bind record.** At bind, the VM generates its daemon's Noise
   static key and sends the public half. The platform signs it into the machine record (the existing
   Ed25519 keyset). The Mac pins it before its first handshake. The person's device key goes the other
   way: the platform-signed grant names it, and the daemon checks it locally against the keyset it
   already has.
3. **The Mac's Cloud connection is a cmux-remote client** in the cmux-tui process the app already runs.
   It's Rust. The Swift side only shows its state.

### One readiness event, pushed

The machine's own `Register` on its slot is the readiness event. No one polls for it.

- The Mac opens its `Connect` as soon as the create call returns. The relay slot holds it, hibernated,
  until the VM registers, and then pairs the two at once (`Allocated`/`Incoming`). The time from the VM's
  register to the Mac's first frame is one WebSocket hop.
- The same event goes out on the machine state socket the app already has (`CloudMachineStatePush.swift`),
  so UI that shows "starting" flips without its own wait.
- These go away: `ConnectWait.ts`'s 250 ms and 500 ms polls, the 180 s link wait and its 1-10 s redial,
  the receiver's policy reads on a timer, and the gap where the mesh ACL hasn't landed yet. The carrier
  doesn't use the Freestyle mesh at all.

### One deadline

A connect has one deadline, measured from the moment the person sends: 90 s, the longest wait any one
hop has today, so nothing that works now gets cut off. It covers create, boot, register and the Noise
handshake together.

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
- **SSH and desktop:** `TcpTunnel` to `127.0.0.1:22` and to the desktop socket, the same targets the
  native receiver uses today (`link/host_inbound.rs:227`).
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
`CMUX_NEXT_CLOUD_CARRIER=1` until slice 6 makes it the only path.

1. **This doc.**
2. **The relay waits for the daemon.** `cloudflare-do`'s slot parks a Connect until Register, with a test
   showing a client that connects before the daemon gets paired, with no retry.
3. **Platform:** deploy the relay, mint Register and Connect tickets from the install and person tokens,
   and push readiness on the state socket.
4. **Guest:** the session host registers its relay route at boot, and the bind carries the daemon key.
5. **Mac:** the app's Cloud connection runs as a cmux-remote client with one deadline. Chat goes over
   `MuxControl`. This is the first start-matrix carrier row.
6. **Files and secrets:** folder copy, seed, login copy and `secrets-v1` move onto the session. The flag
   flips to on.
7. **Deletion:** the list above, in two or three PRs, one per repo, with the Swift deletions split out.

The work is done when the carrier is the only path in NEXT and the start matrix is green on it.
