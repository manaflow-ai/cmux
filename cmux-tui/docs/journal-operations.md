# Journal operations: reading `server stats`

The daemon reports where its own time goes. Ask it before sampling the
process:

```bash
cmux server stats --json            # exact object, spec/commands.md "server-stats"
cmux server stats                   # nested key: value lines
```

Counters accumulate since daemon start and reading them costs a few atomic
loads, so polling is safe. Everything below names a field of that object.

## The write path in one paragraph

Every durable write goes through SQLite in WAL mode with `synchronous=FULL`
and `fullfsync`, about 20 ms per commit on an Apple SSD. Producers (agent
hooks, frontends) enqueue into bounded lanes; one writer thread drains both
lanes into a single transaction, commits, and hands each producer a receipt.
The writer takes the workspace registry mutex for the commit. Request threads
take the same mutex for their own commits, so it is the one lock whose
contention shapes latency under load. `spec/session-journal.md` "Retention and
storage" describes the intended single-writer shape; the plan to finish it is
the cmuxterm-hq journal write path plan.

## Reading `registry_lock`

- `holder` names the `file:line` that holds the registry mutex right now and
  for how long. Under a healthy daemon this is usually `null`; a holder older
  than a few milliseconds is in an fsync.
- `hold_us` is the hold-time histogram. Its p50 near 20,000 means most holds
  are one fsync. `top_sites` says which code holds it longest in total; that is
  the list to shorten.
- `wait_us` is how long acquirers waited. A p90 far above `hold_us.p50` means a
  convoy: many threads queue behind each hold. `contended_acquisitions` (waits
  of 1 ms or more) and `stalls` (100 ms or more) count it, and `last_stall`
  names the waiter and the site that held the lock when the wait began.

## Reading `journal_writer`

- `batch_size.mean` is the group-commit ratio. Under many concurrent producers
  it should climb well above 1. A mean near 1 under load means producers are
  throttled before they reach the queue, which was the symptom of the resolver
  convoy fixed in cmux PR 11630.
- `commit_us` is transaction time including the fsync, without lock wait.
  `commit_lock_wait_us` is the writer waiting for the registry mutex; if it
  rivals `commit_us`, request threads are starving the writer.
- `receipt_wait_us` is what a producer such as `cmux-tui-hook` waited from
  enqueue to receipt. It bounds the hook's detached child lifetime.
- `terminal_queued` and `durable_queued` are live lane depths.
  `deadline_expiries` and `commit_failures` should stay at zero; either one
  rising means the writer is being interrupted or refused.
- `phase` and `phase_for_us` say what the writer is doing now; a long
  `waiting_lock` phase points at `registry_lock.holder`.

## Reading `connections`

`limit` is the control-socket cap. `refused` counts sockets dropped at the cap;
each refused hook connection is a lost agent event, so any non-zero value is a
capacity incident, not a statistic. `peak` shows how close normal operation
comes to the cap.

## Benchmarking

Until the in-binary load generator lands, use the Python scripts recorded in
the cmuxterm-hq plan (`bench4.py`: N clients over K live terminals through a
blocking hook helper) and read `server stats` before and after. Numbers on the
2026-09-02 main with 16 terminals, dev build, Apple M-series laptop: 16 clients
p50 185 ms at 75 events/s; 48 clients p50 621 ms at 59 events/s; the remaining
ceiling is the per-event projection commit under the registry lock.
