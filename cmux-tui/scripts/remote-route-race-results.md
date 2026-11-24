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
