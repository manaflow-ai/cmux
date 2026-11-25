# Route race: first connect with a black-holed first route, 2026-11-24

Ask (lane remote-route-race): "Measure it on a REAL network ... route 0 black-holed, route 1 shaped to
50 ms RTT / 2 % loss. Time from launching the client to the first attach, first launch (no last-good
memory), race on vs `CMUX_REMOTE_ROUTE_RACE=0`, N>=10 each, p50/p95. Target: <= 1 s (before ~15 s)."

Command (Linux, root; creates and removes two network namespaces, touches nothing else):

```sh
cargo build --release -p cmux-tui --bin cmux-tui
sudo cmux-tui/scripts/remote-route-race-bench.sh cmux-tui/target/release/cmux-tui 20
```

Build under test: lane/remote-route-race head d02efe937d0 (the script's own commit sits on top).
Real kernel TCP over a veth pair between two namespaces; route 0 is dropped by netem (loss 100 %,
no RST or ICMP, a true black hole); route 1 has netem delay 25 ms and 2 % loss on each end's egress.
One real `cmux daemon start --remote` serves both addresses; the client is paired once, then each
trial deletes `route-last-good.json` and times `cmux remote connect --headless` from spawn to its
first output line (printed once the session is connected). Arms alternate run by run.

| Arm | N | ok | min | p50 | p95 | max |
| --- | --- | --- | --- | --- | --- | --- |
| race on (default) | 20 | 20 | 716 ms | 1002 ms | 1424 ms | 1873 ms |
| `CMUX_REMOTE_ROUTE_RACE=0` | 20 | 20 | 12454 ms | 12725 ms | 12982 ms | 13103 ms |

The race cuts the first connect from about 12.7 s to about 1.0 s at p50 (12x), but the 1 s target is
met only at about p50: p95 is 1.4 s.

Caveats:
- The machine was heavily loaded during the run (load average 55-80 on 16 cores), which inflates
  both arms; the client process and the daemon share those cores. Rerun on a quiet host before
  quoting the p95.
- The race arm's floor is the 250 ms stagger plus a connect over 50 ms RTT (TCP, WebSocket, Noise,
  lane setup are several round trips) plus SYN or handshake retransmits from the 2 % loss; the
  remaining spread is that loss and load, not the race.
- The off arm finishes in about 12.7 s, not 15 s: the budget is shared with startup.
- Linux only (netns, netem); both "hosts" are namespaces on one kernel, so CPU is shared.

## Three arms with a floor and a phase split (same day, load below 16)

Ask (coordinator): "add a third arm floor (route 0 healthy, race on) so we know connect cost alone at
50 ms / 2 %, and a per-phase split ... rerun all three arms N=20 when the load average is below 16."

```sh
sudo cmux-tui/scripts/remote-route-race-bench.sh cmux-tui/target/release/cmux-tui 20
```

Load average (1/5/15 min) was 13.9/24.0/36.3 at the start and 8.5/15.1/28.9 at the end. The floor arm
shapes route 0 exactly like route 1 (50 ms RTT, 2 % loss). Arm order rotates each run.

| Arm | N | ok | min | p50 | p95 | max | p50 spawn to first SYN | p50 SYN to SYN-ACK | p50 SYN-ACK to connected |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| race on, route 0 black-holed | 20 | 20 | 661 | 666 | 1090 | 1183 | 282 | 25 | 577 |
| `CMUX_REMOTE_ROUTE_RACE=0`, route 0 black-holed | 20 | 19 | 12412 | 12479 | 13185 | 13379 | 12032 | 25 | 421 |
| floor: route 0 healthy, race on | 20 | 19 | 418 | 664 | 836 | 1065 | 31 | 25 | 608 |

All times in ms. One trial each in the off and floor arms printed nothing within the 40 s trial
timeout (not counted above; cause not investigated).

The client logs no phase timings, so the split comes from tcpdump in the client namespace. A SYN that
netem drops is never seen by the tap (it sits after the qdisc), so on the black-holed arms "spawn to
first SYN" contains the wait on route 0; the floor arm's 31 ms is the real process-start-to-first-dial.
"SYN to SYN-ACK" is only the return leg (the tap sits after the egress delay).

Where the time goes:
- The race costs about the stagger: 282 ms to the first visible SYN is the 250 ms stagger plus about
  30 ms of startup. With route 0 black-holed the race arm lands at p50 666 ms, the same as the floor
  p50 of 664 ms, because the floor's own p50 already contains the 2 % loss tail (min 418 ms).
- Connect cost itself is about 8 to 9 round trips of 50 ms: TCP (1), WebSocket upgrade (1), Noise
  handshake (2 to 3 flights), then the extra lanes, which each open a TCP connection, upgrade and
  Noise again in parallel (3 to 4). That is about 420 to 450 ms on a clean path.
- The rest, up to p95 about 1.1 s, is loss: a lost packet on a 50 ms path costs a retransmit timeout
  (about 200 ms or more), and the connect has about 20 packets in flight sequences.
- So the 1 s target is met at p50 (666 ms) but not p95 (1090 ms); what remains is round-trip count and loss, not the race.
