# One session, many carriers

The target design for reaching a Cloud machine, and the slices that get there. It extends
`design/cloud-carrier.md` (on the `lane/cloud-carrier` branch), which describes the single carrier that ships
today: `cmux carrier dial/serve`, a cmux-remote Noise session over one `relay+do` slot.

Leo asked, 2026-11-08: "btw all this \"we're just doing one way\" stuff how good/reliable are our designs? what
can be improved". The answer here: "one way" is right for the session protocol and the connection state
machine, and wrong if it means one path. Collapse duplicated logic; never collapse redundancy.

## Where we are

Since cmux#37210 the NEXT app reaches a Cloud machine only through the carrier. Behind that path the connection
is good: a pinned daemon key, one deadline, full-jitter backoff, and a session that resumes from sequence
cursors. But it has no second route. When the relay Worker, the slot's Durable Object or the platform's ticket
mint is down, the machine can't be reached, and nothing tries anything else.

Most of the multi-carrier machinery already exists in `cmux-remote`:

- a carrier trait (`TransportProvider` and `LinkGroup`, `cmux-remote/src/provider/mod.rs`) with providers for
  relay, `relay+do`, ssh, WebSocket, unix, iroh and the WireGuard overlay;
- a reconnect loop that asks a `ReconnectGroupSource` for the next route and resumes the same session on it by
  replaying unacked frames (`cmux-remote/src/connection.rs`);
- a daemon that serves unix, direct WebSocket, several relays and iroh at once, all into one session
  (`cmux-tui/src/remote_runtime.rs`).

`cmux remote connect` (paired and SSH machines) runs that loop over a list of routes. The Cloud dial calls
`ClientConnection::connect` with no reconnect source (`carrier/client.rs`), so it can only resume on the
same relay.

### Duplicate logic (collapse it)

1. Two Rust client runners for cmux-remote: `carrier/client.rs` (one relay, its own attempt loop and backoff)
   and the `remote_runtime.rs` route runner (route list, initial pick, rotating reconnect, ssh bootstrap).
   The Cloud one is the one without failover.
2. Three session protocols for reaching a machine's daemon: cmux-remote Noise (`remote connect`,
   `carrier dial`), WireGuard overlay plus `ServiceHello` (`cmux link dial`), and tailnet TCP plus a preface
   (`cmux host dial`). Each has its own auth and reconnect story; only Noise resumes a session.
3. Relay chat (`MachineRelay`) next to the carrier for a Cloud first reply. Both run on the same provider, so
   relay chat was never redundancy: it fails when the carrier fails, and it's plaintext at the Worker.
4. Swift reconnect layers (`DaemonConnection`, `RetryPacer`, the late-reply resend, three per-route state
   machines) over a Rust session that already reconnects. On SSH, retry is stacked three deep.
5. `carrier serve` dialed a whole new session (platform ticket and grant, relay, Noise) for every accepted
   socket connection, although one session multiplexes any number of service streams. Slice 2 removes this.

### Redundancy (keep it, and make one state machine reach it)

- The daemon's listeners: unix, direct WebSocket, N relays and iroh, all into one session.
- The overlay's underlay paths (direct UDP, VPC tunnel, DO relay) inside one WireGuard session.
- ssh as a carrier, independent of Cloudflare and of the platform.
- The mesh/VPC path to a Cloud VM: today the only inbound path to a VM that doesn't go through Cloudflare.
- Two relay services with one wire: the Durable Object relay (`cmux-tui/relays/cloudflare-do`) and the native
  `cmux-relay`. This is the basis of a second relay on other infrastructure.

### Single points of failure today

| What fails | Effect | Gap |
|---|---|---|
| The relay Worker (one per environment) | No new connect and no resume: every Cloud machine is unreachable | No second relay; `/healthz` answers a constant and touches no Durable Object |
| A slot's Durable Object | That machine is unreachable until the object moves or restarts | One object per machine |
| The platform ticket and grant mint | No new connect, and a daemon can't re-register after a relay restart or VM resume (it needs a Register ticket) | Relay availability is chained to platform availability |
| `CMUX_RELAY_TICKET_KEY` (a shared HMAC secret) | Rotating it needs a lockstep deploy; a relay elsewhere would need the secret | Tickets aren't verifiable with a public key |

## Rules

- **One session protocol.** cmux-remote Noise_XX over any ordered byte stream. Relays, ssh and the VPC see
  ciphertext only. Auth stays in Noise (a carrier grant for Cloud, an enrolled device for paired machines),
  never at the carrier.
- **One connection state machine, in Rust.** `Resolving → Racing(candidates) → Up(carrier) ⇄
  Recovering(resume on the next candidate) → Ended`. Swift asks for "a socket for machine X" and shows status;
  it holds no retry or backoff of its own.
- **Carriers are chosen automatically**, and a carrier switch is never a session event: the session sees only
  a generation bump, as it does on resume today.
- **Every path carries traffic (no cold standby).** A fallback that rarely runs is a fallback that fails when
  it's needed. Each machine registers on every relay it's assigned, and clients spread connections over all of
  them, so a failover only moves traffic onto a path already proven live. A path that can't meet this rule
  either becomes one that runs every day, with a probe, or it goes.
- **Every carrier has a probe and a fault test**: kill it mid-turn, and the session resumes on another carrier
  with no lost events.

## Target

```
Swift: "socket for machine X" + status projection (no retry, no phases)
  │  one long-lived `cmux carrier serve` per machine (later in-process through cmux-sdk-ffi)
Rust (cmux-tui carrier → cmux-remote):
  MachineLink: ONE state machine per machine
  ClientConnection + ReliableSession: ONE Noise_XX session, per-lane seq, ack and replay
  CarrierSource (a ReconnectGroupSource):
     relay pair from the machine's shard (relay+do A, relay B)
     direct (the daemon over the VM's mesh/VPC path, when present)
     ssh (paired machines; Cloud only where tcp:22 is reachable)
     unix (same host)
```

### Picking a carrier

- **First connect races.** Start the best class at once and the next 250 ms later (or when the current one
  fails): direct, then the relay pair, then ssh. Race only up to the carrier step (link open, `Allocated`),
  then run Noise and present the grant on the winner, so a race spends one single-use grant.
- **Reconnect starts from the last good carrier, then rotates**, with a 1-2 s cap per candidate inside the
  attempt deadline. A carrier whose probe failed recently moves to the end.
- **Upgrade without loss.** While on a relay, probe direct every 30 s (or on a network change) while the app
  shows that machine, and resume on direct when it answers. Resume replays, so nothing is lost.

### Relay fleet

- Two regions. Each machine gets its own pair of relays by shuffle sharding: a hash of the machine id picks 2
  of N relay instances, so one bad relay or one poison machine reaches only a small share of pairs.
- The pair rides in the bind's carrier section and the carrier answer as a list, `relays: [{relay, slot}]`,
  replacing `relay`. Readers accept the old single field for one release. Until relay B exists the pair is
  `[A, A]`; the list and the shard selection land before relay B does.
- Before a relay drains for a deploy, it sends each connected client and daemon a `move` frame naming the other
  relay of the pair. The peer resumes there first; then the drain closes. Test: deploy a relay during a turn,
  with no lost events and no visible reconnect.
- Health: a synthetic probe per relay instance every minute from two vantage points (register a probe daemon,
  connect, round-trip 1 KiB, record ms); `/healthz?deep=1` touches a probe slot object. Clients feed failures
  into their candidate order, so no central health service sits on the path.
- The daemon touches its slot first, at boot, so the object lands near the VM. Keep that; no per-client
  location hint.

### Credentials: one grant for every carrier

- The carrier grant, checked by the daemon inside Noise, is the end-to-end authority on every carrier. Direct
  and ssh need nothing else for the session (ssh still needs an ssh credential: a short team-CA cert).
- Relay tickets move to Ed25519 with the grants' keyset (`aud = relay`), so any relay verifies with a public
  key and one ticket admits the slot on every relay of the pair. A ticket then lives as long as the person's
  right to the machine (for example 15 min, renewed in the background); the grant stays short and single use,
  and only a new session needs one.
- The daemon's Register ticket becomes long-lived (24 h or more) and renews in the background, so a relay
  restart or VM resume doesn't need the platform.
- Open question before tickets stop being per connect: `CloudDO.relayScope` also wakes a paused machine on each
  ticket. That wake would move to an explicit "resume machine" ask.

### Config as full versioned snapshots

- Policy, the relay list and edge rules are pushed as one full signed snapshot
  `{version, issued_at, relays, policy, edge}` (the tickets' Ed25519 key family), refreshed on a timer, never
  sent as deltas.
- Rollout goes dogfood (our team), then canary (a share of machines by hash), then all, each stage gated on the
  production probes (cloud-chat-replies-production and the cloud-start-matrix-production carrier row).
- Readers accept the current and the previous version. A reader that misses a push converges on the next tick.
- This replaces today's per-field reads (the bind's carrier section, the keyset fetch, the edge host variable).

### Failover mid-session without losing events

- `ReliableSession` keeps unacked frames per lane (up to 4096 frames or 16 MiB) and both sides replay what the
  other didn't ack on resume. A carrier switch is a resume on another `LinkGroup`: the Cloud dial needs a
  `ReconnectGroupSource` with more than one candidate, and no session change.
- The daemon keeps a session for its resume lease (2 min by default). A relay outage longer than that makes the
  next connect a new session. The Cloud daemon's lease should grow to about 10 min, with the memory bound stated.
- The app-level cursor (acpmux's record `seq`) is the backstop: on a new session the app resubscribes from its
  last seen `seq`. The transport promises no loss within the lease; the app promises no loss while acpmux keeps
  the records.
- Tunnel streams (port forwards, the desktop's `local-socket`) close on a switch and reconnect at their own
  layer. A replay buffer overflow is a typed `ReplayGap`, never silent loss.

## Probes and fault tests

Every test asserts the netdrop oracle: every event once and in order, or a typed loss signal.

| Test | What it does |
|---|---|
| `carrier_failover_relay_to_relay_mid_turn` | Daemon on two native relays; kill A mid-stream; resume on B within the attempt timeout, generation +1, no lost or duplicated events |
| `carrier_failover_relay_to_ssh_mid_turn` | Routes `[relay A, ssh://localhost]`; kill A; resume over ssh stdio |
| `carrier_failover_direct_to_relay_mid_turn` | Cut direct with the netdrop proxy; resume on the relay; restore direct and upgrade back with no loss |
| `carrier_failover_outlasting_lease_is_typed` | Every carrier down past the lease: a typed `session_unavailable`, never a hang or a silent new session |
| `netdrop_fuzz_relay_do` | The seeded fault catalog on `relay+do`, not only on direct WebSocket |
| `relay_deploy_during_turn` | A relay drains with a `move` frame mid-turn: no lost events, no visible reconnect |
| `serve_holds_one_session` | Several socket connections make one dial and one mux stream each (slice 2, `tests/carrier_serve.rs`) |
| Staging journey, relay A down | Blackhole A for the run; connect via B and get a turn reply |

Synthetic probes run every 60 s from two vantage points with a 10 s deadline, and each writes the connect log's
line format so one dashboard reads them all: `probe.relay.<instance>`, `probe.carrier.<env>` (a full dial and
identify against a standing probe machine), `probe.mint.<env>` (the ticket mint alone), and `probe.direct.<env>`
if a direct carrier ships.

## Slices, in landing order

| # | Slice | Repo |
|---|---|---|
| 1 | **Measure.** A `carrier.phases` line beside each route line in the connect log: ticket, relay, park, handshake and mux ms, lanes, and `carrier=relay:<i>` | cmux (this design's PR) |
| 2 | **One session per machine in `serve`**: one session, a mux stream per accepted connection, a new dial only when the session is gone, idle close after 2 min | cmux (this design's PR) |
| 3 | **One runner.** The carrier dial goes through the `remote_runtime` route runner with a `CarrierSource`, and `client.rs`'s attempt loop goes. One relay still; behavior unchanged | cmux |
| 4 | **Failover tests** (the table above, relay→relay, relay→ssh, direct→relay, lease) and `netdrop_fuzz_relay_do` | cmux |
| 5 | **Relay list with shard selection**: `relays: [{relay, slot}]` in the answer and the bind (old `relay` kept one release), shuffle-sharded pair per machine | cmux-platform |
| 5b | **Relay `move` frame and drain handoff**, plus the deploy-during-turn test | cmux + relays |
| 6 | **Daemon registers on every listed relay**; the dial gets a candidate list | cmux |
| 7 | **Relay B**: the native `cmux-relay` in a second region on other infrastructure, with its deploy and `probe.relay.*`. After V0; this lane owns it | infra + cmux |
| 8 | **Ed25519 tickets and snapshots** (accepted alongside HMAC during rollout), and a long-lived daemon Register ticket | cmux + cmux-platform |
| 8b | **Versioned config snapshot**: platform mint, daemon and app readers accepting N and N-1, staged rollout | cmux + cmux-platform |
| 9 | **First-connect race**, last-good ordering and probe-informed demotion | cmux |
| 10 | **Swift shrinks**: `CloudCarrierServe` becomes a supervisor (spawn once per machine, token lines in, status lines out); Swift retry for carrier sockets goes | cmux |
| 11 | Deep `healthz` and (optional) ticket mint at the edge, decided on slice 1's numbers | cmux-platform |
| 12 | (Optional) direct VPC carrier for Cloud, only if slice 1's numbers or a provider-wide risk justify keeping the VM's mesh membership | cmux + cmux-platform |
| 13 | Paired machines onto the same runner: several routes to one `remote connect`; `link dial` becomes an overlay provider under Noise instead of a second protocol | cmux, separate design |

Slices 1-4 change no protocol. Slices 5-8 give Cloud a real second carrier. The Swift serve reducer
(cmux#38309) stays as the interim, scoped to lifecycle (spawn, ready, exit, token refresh) with no retry
states; slice 10 deletes what duplicates the Rust state machine.

## Slices 1 and 2 as built

`cmux carrier dial` and `serve` append, beside each route line, one line to `carrier/connect.log` (never to
stderr, whose lines both commands pin):

```
carrier.phases machine=<vm_id> phase=<connect|reconnect|stream> carrier=relay:0 outcome=<ok|error_code> ticket_ms=<n> relay_ms=<n> parked_ms=<n> handshake_ms=<n> mux_ms=<n> lanes=<n> ms=<n>
```

The route line (`cloud.connect route=carrier machine=… phase=… outcome=… ms=…`) is unchanged: cmuxterm-hq's
start matrix fails a row on any `cloud.connect` line of another shape, so the step times ride their own line.
`phase=stream` is a `serve` connection carried on the held session (no ticket, relay or handshake).

`serve` holds one session per machine. The first connection dials it; each later connection opens its own mux
control stream on it. A new dial happens only when the daemon no longer has the session, its reader failed for
good, a credential for another person (a different JWT `sub`) arrived on stdin, or the session carried no
stream for two minutes (`CMUX_CARRIER_SERVE_IDLE_MS` overrides). The stdio contract (stdin token and answer
lines, the ready line, one ok or failure line per connection, exit codes) is unchanged.
