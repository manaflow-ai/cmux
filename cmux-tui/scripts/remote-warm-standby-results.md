# Warm standby reconnect bench (iroh direct, netns)

Command: `sudo cmux-tui/scripts/remote-warm-standby-bench.sh "" 20` (binary built with
`--features iroh-transport` from lane/remote-warm-standby 27d81816608, which contains the route-race
commits). Two routes at 50 ms RTT / 2 % loss, route 0 black-holed mid-session, N=20 per arm.
Load average 24-38 during the run (21 of 40 trials never connected at launch under that load and
are excluded; "ok" counts the rest).

| arm | N | ok | min | p50 | p95 | max |
|---|---|---|---|---|---|---|
| warm standby (default) | 20 | 11 | 32660 | 32939 | 33254 | 33334 |
| CMUX_REMOTE_WARM_STANDBY=0 | 20 | 8 | 34187 | 34416 | 35705 | 35825 |

Milliseconds from the black hole to the link reporting route 1. The standby saves about 1.5 s of
about 33 s: it does not do what it is for.

Phase split (one traced trial, `CMUX_BENCH_TRACE=1`, default arm, total 32.8 s):
- 0 to 4.1 s: heartbeat detects the dead link ("reconnecting" at +4.1 s).
- attempt 1, 15.0 s: redial on the dead route 0 group, ends in "secure link handshake timed out
  after 15000ms" (the full attempt_timeout; nothing abandons it when a fresh standby is waiting).
- `next_warm_route` takes the fresh standby (route 1, armed in 51 ms at link-up).
- attempt 2, 13.0 s: on the standby group, ends "link is closed": the held QUIC connection was
  already dead, so the standby bought nothing.
- `next_warm_route`: no standby; attempt 3 cold dial on route 1: 204 ms, Ok.

Root cause of the 33 s: 4 s detection + 15 s attempt 1 (serial retry of the dead group, the standby
is only consulted after it fails) + 13 s on a standby whose connection is closed (likely idle-closed
or superseded; a fresh standby is trusted for MAX_AGE 30 s without a liveness check) + 0.2 s.
Fixes to try in lane/remote-warm-standby: switch to the standby as soon as the heartbeat declares the
link dead instead of after the attempt timeout; probe the standby connection (is_closed / a ping)
before taking it; bound the attempt on a standby group much lower than 15 s.
Caveat: one traced trial only; the trace lines are env-gated eprintln in connection.rs and
warm_standby.rs.
