# Journal operations: reading `daemon stats`

The daemon reports where its own time goes. Ask it before sampling the
process:

```bash
cmux daemon stats --json            # exact object, spec/commands.md "server-stats"
cmux daemon stats                   # nested key: value lines
```

Counters accumulate since daemon start and reading them costs a few atomic
loads, so polling is safe. Everything below names a field of that object.

## The write path in one paragraph

Every durable write goes through SQLite in WAL mode with `synchronous=NORMAL`:
a commit is in the WAL (the page cache, which a daemon crash keeps) when it
returns, in well under a millisecond. One syncer thread
(`workspace_registry/wal_durability.rs`) runs the WAL checkpoints off every
request (SQLite syncs the WAL before each one) and flushes the drive cache
once at close, so no request waits for the disk but for the restart rule
below, and no holder of the mux state lock ever does. The syncer checkpoints
once the commits wrote 4 MiB of frames since its last checkpoint of the whole
WAL (it does not decide by the WAL file's size, which stays at 64 MiB after a
cut);
`write_path.wal_commits` and `wal_synced_commits` show how many commits are
known on disk, and `registry_wal_frame_bytes` how many bytes their WAL frames
took (two reads around one change give that change's bytes). A PASSIVE
checkpoint never shrinks the WAL file, so each connection sets
`journal_size_limit` to 64 MiB: the WAL restarts from its first frame, and the
file shrinks to that size, at the first commit after a PASSIVE checkpoint
copied the whole WAL and the last reader of the old WAL ended. A checkpoint
that runs beside commits never copies the whole WAL, so under commits with no
pause (a session build, a restore) the file once grew without a bound. The
restart rule: the commit that takes the WAL past 64 MiB asks the syncer for
one more PASSIVE checkpoint and waits for its end, at most 250 ms. That thread
owns the writing connection, so no commit lands meanwhile; the checkpoint
copies the whole WAL and the next commit restarts it. The WAL file thus stays
at or under 64 MiB plus one commit, for one short wait per 64 MiB of WAL,
while each of those checkpoints ends in its 250 ms and copies the whole WAL.
Three cases take that bound away for a time; in none does a commit wait
longer. A read transaction open at that moment stops the checkpoint at its
snapshot; the checkpoint ends at once and the commit does not wait for the
reader; the rule then tries again after each further 4 MiB, and the file
grows by what commits write until that read ends. A checkpoint slower than
250 ms (a slow disk) lets the commit go on; the next tries come 4, 12, 28, 60
and 124 MiB past the limit, then once per 64 MiB, and the file grows until
one try ends. A commit of a thread that holds the mux state lock makes no try
(every reader of the state would wait behind it); the next commit of a thread
without that lock makes it, and the journal writer, which makes most commits,
never holds that lock. The thread that waits holds its connection lock (a
request thread also the registry lock) for the wait. A WAL that a previous
run left over 4 MiB is checkpointed by the syncer when the registry opens
(on the syncer's thread: the open itself runs no checkpoint and, at the
current schema, commits 2 frames whatever the session's size), and a clean
stop ends with one PASSIVE checkpoint; cmux never deletes the WAL
file (SQLite removes it when the last connection closes cleanly). A fully idle
registry keeps its WAL at its size until its next commit. The syncer runs no
TRUNCATE or RESTART checkpoint, which would hold the writer lock while it
waited for readers and fail a transaction's read-to-write upgrade with
SQLITE_BUSY. `registry_wal_file_bytes` and
`registry_wal_file_high_water_bytes` show the file's size now and at its
largest.
A sync after each reply was measured and rejected: the next
request waited for it. A power loss or kernel panic can take back the tail of
commits since the last checkpoint that the kernel had not yet written, and it
also ends every terminal the tail described. Producers (agent
hooks, frontends) enqueue into bounded lanes; one writer thread drains both
lanes into a single transaction, commits, and hands each producer a receipt.
The writer takes the workspace registry mutex for the commit. Request threads
take the same mutex for their own commits, so it is the one lock whose
contention shapes latency under load. `spec/session-journal.md` "Retention and
storage" describes the intended single-writer shape; the plan to finish it is
the cmuxterm-hq journal write path plan.

## Reading `registry_lock`

- `holder` names the `file:line` that holds the registry mutex right now and
  for how long. Under a healthy daemon this is usually `null`; commits no
  longer fsync under the lock, so a holder older than a few milliseconds is
  a bug to report.
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
blocking hook helper) and read `daemon stats` before and after. Numbers on the
2026-09-02 main with 16 terminals, dev build, Apple M-series laptop: 16 clients
p50 185 ms at 75 events/s; 48 clients p50 621 ms at 59 events/s; the remaining
ceiling is the per-event projection commit under the registry lock.
