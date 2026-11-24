# acpmux under duress: host150 before and after

The duress bench's `baseline` and `host150` legs (`cmux-tui/crates/acpmux/tests/duress_daemon.rs`,
`support/duress_host150.rs`) at two commits of `feat-cmux-next`:

- before: `feat-cmux-next` at `c716d6bc` with #52921 and #52644 reverted (a peer link awaits the
  shared hub notice queue);
- after: `feat-cmux-next` at `c716d6bc` (a link hands notices to its own backlog and never waits on
  the hub: #52644 plus its fix #52921).

Run on the fleet Linux pool:

```
cmux-ci test --route fleet --setup rust --timeout 7200 --at SHA -- bash -c \
  "cd cmux-tui && ACPMUX_DURESS=1 cargo test -p acpmux --release --test duress_daemon -- \
   --ignored --nocapture duress_bench legs=baseline,host150"
```

GitHub Actions runner, 8 cores, one run each, 2026-11-24: before
[45301733366](https://github.com/manaflow-ai/cmux/actions/runs/45301733366), after
[45304103547](https://github.com/manaflow-ai/cmux/actions/runs/45304103547).

| host150 (40 peers, load 80 target) | before | after |
|---|---|---|
| load reached | 81.1 | 82.5 |
| deepest hub notice queue | 11 | 4 |
| longest notice apply | 2.85 ms | 0.95 ms |
| link drops, per peer (40 peers) | 0 | 0 |
| peers stopped answering / redials | 0 / 0 | 0 / 0 |
| presence gap, worst | 0 ms | 0 ms |
| send p50/p95, local | 35 / 79 ms | 35 / 119 ms |
| send p50/p95, to a peer | 30 / 61 ms | 32 / 86 ms |
| `ls` p99 (CLI) | 285 ms | 283 ms |
| false dead | 0 of 219 | 0 of 219 |

The `baseline` leg (2 peers, no load) is the same in both: notice queue 2, send p95 under 15 ms.

What this shows: at this load the hub's queue never filled, so no link stalled before either; the
change halves the queue's depth and the longest apply, and moves nothing else beyond one run's
noise (send p95 stays far under 500 ms both ways). The leg applied only 5 notices, so it does not
reproduce the laptop's stall (a hub behind by thousands); `peer::hub_behind_tests` is the proof
for that case. Not measured here: the drain time of 20 sends after one refused window (the mesh
gate's batching, #52683).
