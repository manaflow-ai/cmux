# The phone link's last-resort relay on cmux's host

The cmux-next phone⇄Mac link is a WireGuard tunnel (boringtun plus smoltcp,
`cmux-next-ios/rust/crates/cmux-mobile-link/src/dial/wireguard.rs`). Its paths
are plain UDP, then Cloudflare TURN over UDP, then TURN over TLS on 443. On a
corporate network that allows only approved domains, or that lets only real
HTTPS through a TLS-inspecting proxy, none of them work: the TURN host is not on
the list, and TURN's stream inside TLS is not HTTP. The app still reaches cmux's
own host there (it signs in and signals through it), so this adds a fourth path
on that host and makes a dial that finds no path say why.

Wire contract: `cmux-next-ios/PROTOCOL.md` "WebSocket relay" and "When no path
works". Security analysis: `cmux-next-ios/SECURITY.md` "Link transport: the
WebSocket relay on cmux's host". What IT must allow: the cmux-next docs page
"Network requirements" (`web/data/next-docs/pages.ts`).

## Why the old relay was retired, and what is different now

Until API 0.9.0 the signaling hub (`TeamHub`) forwarded binary frames
`[16-byte session][16-byte to][datagram]` between a phone and a Mac. It was
retired when TURN over TLS landed (`feat-cnx-ios-turntls`; PROTOCOL.md "Relay
frames (retired in API 0.9.0)"), for three reasons the docs recorded:

- **Latency.** On 2026-10-13 TURN over UDP measured 16 ms RTT against 240 to
  345 ms through the Worker relay. The relay ran in the team's hub, which stays
  where it was first created; free-plan traffic was sometimes received an ocean
  away (a California client served from Paris), and every datagram crossed it.
- **Load on signaling.** Data shared the socket, the object and the rate limits
  of presence and introductions. The hub still keeps a 12000/s binary bucket
  only to answer old clients' frames with `relay_retired` cheaply.
- **Trust.** Route confirmation then used a relay marker that only the backend
  authenticated; it moved into the tunnel (`reach`), where only the peer can
  confirm a route.

The new relay keeps none of those properties: it is its own Durable Object per
link session (never the hub, never the signaling socket), created next to the
first party that joins (`locationHint`, as hubs are since 0.6.0), and route
confirmation stays the in-tunnel `reach`. It is the last path, used only when
the others fail, so its latency matters only where nothing else works.

Two existing relays were considered and not used. The device hub's session relay
(`workers/device-hub`, `test/session-relay.test.ts`) is about TURN entitlements
for Mac-to-Mac screen shares, not a data relay. The host relay
(`backend/apps/api/src/host-relay`, cmux-tui `relay_frame`) is a per-host object
of the cmux-next API Worker, reachable by the team's installs through
`TeamDO` reachability: a different backend, identity system and trust policy
than the phone's Stack-token link. This relay reuses its frame format and golden
vectors (`cmux-tui/crates/cmux-transport/tests/vectors/relay-frames.json`), so
the phone, the Mac and both Workers share one codec, but lives in the mobile
Worker beside the signaling it trusts.

## Design

**Host.** `LinkRelay`, a Durable Object of the mobile Worker
(`cmux-next-ios/backend/src/link-relay.ts`), one per link session, named
`[space|]relay:<owner key>:<session id>`. The join is
`GET wss://mobile-api.cmux.dev/v1/relay/:sessionId?deviceId=` with the Stack
token: a real HTTP/1.1 Upgrade on 443, on the same host as sign-in and
signaling, so a domain allowlist that lets the app sign in lets the relay
through, and an inspecting proxy that passes WebSocket upgrades passes it.

**Auth.** The Worker verifies the token, then asks the caller's own hub
(`TeamHub.relayPeer`) for the other party of that session: the hub bound each
session id to its initiator and responder at its first admitted signal, and
admission already requires the same user (and build space). The joining device
must also present its own relay ticket, a random value the hub stamped
(`relayTicket`) only on the signals it forwarded to that device's own
signaling socket, so another device of the same user cannot pass a party's id.
Only those two devices get a socket; the device ids the object uses come from
the Worker in headers a client cannot set. Each frame goes only to the other
party, with its peer id overwritten with the sender's. The relay sees
ciphertext only. The hub closes the live sockets when the session ends or a
device is removed, and the kill switch closes them at their next frame.

**Per-user budget.** What a socket relays is first granted by the user's
hub from one budget across all of that user's sessions (480 MiB a minute by
default, `LINK_RELAY_USER_MIB_PER_MIN`), so the relay is not a free pipe that
grows with the number of sessions a user opens.

**When it engages.** Both sides offer it in `wg-init` / `wg-resp` (`relay:
"ready"`, or `"now"` when that side has no other path: no plain UDP and no TURN
allocation). A side joins at once on `"now"`; otherwise when nothing from the
peer authenticated 3 s after the tunnel started or the side roamed, raced like
the TLS fallback: the dial already opened TURN over TLS beside UDP from the
start, so by then each earlier path had its chance. The phone also joins when
its live link hears nothing for 16 s in the foreground. A side that joins on
its own asks the peer with a `wg-relay` signal. A dial on a working network
never opens the socket (`a_network_that_passes_udp_never_joins_the_relay`).

**On the tunnel.** The relay is one more carrier of the session's
`HybridUnderlay`, a path of the shared path selector like each TURN route
(`PathKind::DoRelay`): ranked below every direct path, and by round trip below a
TURN path that answers. Datagrams queue by class (`class_queue.rs`, the TURN
carrier's queue) and the writer packs every ready datagram into one frame of up
to 16 KiB, which cuts per-message cost and the object's per-message work.

**Roaming off it.** While the session rides the relay, plain UDP and TURN keep
being probed (upgrade probes every 750 ms while data flows, the direct spray
every 5 s). Once another route has been a side's confirmed one for 60 s, it
closes its relay socket. Reachability can be one-way, so a side that still
needs the relay (its route is the relay, or it hears nothing from the peer)
and is told the peer left asks it back (`wg-relay`), and a rejoin within 5
minutes sticks. A roam resets the 3 s clock, so moving onto a blocking network
joins again. A socket that dies while needed is joined again at once, then
after 1, 3, 10 and 30 s.

**Debug.** Settings → Developer → "Relay via cmux (HTTPS) only" (and simulator
`SIMCTL_CHILD_CMUX_MOBILE_DEV_FORCE_RELAY=1`): no plain UDP, no TURN allocation,
the relay at once, never left. `LINK_RELAY_MODE=off` in the Worker is the kill
switch (`503 relay_off`).

## Cost

Cloudflare's published prices (Workers Paid, checked 2026-11):

- Durable Object requests: $0.15 per million; WebSocket messages *to* an object
  count as one request per 20; messages the object sends are free.
- Durable Object duration: $12.50 per million GB-s at 128 MB per active object,
  billed while the object is awake (a hibernating socket costs nothing).
- Cloudflare Realtime TURN: $0.05 per GB of egress after 1,000 free GB a month.

For one relayed session:

| Traffic | TURN | This relay |
| --- | --- | --- |
| Idle link (keepalives every 10 s each way, about 150 B each) | ≈ $0 | about 0.2 messages a second, about 0.01 requests a second; the object may never hibernate between keepalives, so duration dominates: ≈ $0.0056 an hour awake (0.125 GB × 3600 s × $12.50/M), ≈ $4 a month for a link relayed all day, every day |
| 1 GB of terminal or video (≈ 800k WireGuard datagrams, 2–10 per frame when busy) | $0.05 | ≈ 80k–400k messages → 4k–20k requests → $0.0006–$0.003, plus duration while busy |

So per byte the relay is cheaper than TURN; per hour of an idle but relayed
link it costs more, because the object stays awake. That is acceptable for the
networks that need it (TURN cannot serve them at any price), and the 60 s leave
rule keeps every link that can use TURN or UDP off it. The Worker answers the
application `ping` without waking the object, so a relayed idle link's cost is
its WireGuard keepalives alone. If relayed sessions grow, the lever is a longer
keepalive on the relay path, not a cheaper relay.

## Limits

- **Latency.** Two legs through one object: about the RTT of each party to the
  object's colo plus the object's handling, so expect tens to a few hundred ms
  more than TURN. It is the last resort for that reason.
- **Throughput.** About 4,000 incoming messages a second per object (measured
  2026-10-02 for the host relay), so a frame packs every ready datagram. The
  relay limits each socket to 1500 frames and 8 MiB a second; a screen share at
  5 Mbit/s needs well under that.
- **One TCP stream.** Like TURN over TLS, everything rides one ordered stream:
  a loss stalls what follows it, which is why the class queue puts control and
  input first and drops stale media.
- **Proxies.** A proxy that refuses WebSocket upgrades, or re-signs TLS with a
  certificate the device does not trust, still blocks it. The app then says so
  (`refused` with the status, `tls_rejected`), and the docs page tells IT what
  to allow. Trusting the device's own trust store (an MDM-installed proxy CA)
  for TURN over TLS and adding HTTP CONNECT proxy support are separate work
  (branch `cnx-link-corp-net`).
- **Older builds.** A peer without the relay never offers it, so neither side
  joins; a phone that needs it tells the person to update the Mac
  (`peer_cannot`).

## When no path works

Each dial records what every path did (`dial/diagnosis.rs`): UDP, TURN with its
host, and the relay with its host, HTTP status or TLS error. A dial that never
heard the Mac and whose relay failed too ends with that record
(`DialError::Blocked`, FFI `Refused { code: "network_blocked" }`) instead of
waiting out its timeout, and the app shows one sentence the person can act on,
with the hosts named, instead of an endless "Reconnecting…". It keeps retrying
on its own, quietly, as for any failed dial.

## Tests

- Worker: `cmux-next-ios/backend/test/link-relay.test.ts` (who may join, what
  crosses, kill switch, build spaces, shared frame vectors).
- Link: `cmux-next-ios/rust/crates/cmux-mobile-link/tests/https_relay.rs`
  against the fake backend's relay (`testing.rs`): the link rides the relay with
  UDP and the TURN host blocked; the debug option forces it; a working network
  never joins; a dead socket is joined again; roaming back to UDP leaves it;
  every path blocked, an unreachable relay host and a Mac without the relay each
  end the dial with the right record.
