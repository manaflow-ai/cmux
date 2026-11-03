# Long jobs: every slow job that blocks something is visible

Status: in progress (2026-11-02).

## Incident

On 2026-11-02 cmux NIGHTLY started the one-time output cleanup
(`workspace_registry/output_cleanup`, phase B `swap_at_open`) on a 41.6 GB
registry. The swap ran 303 s inside `registry.lock_and_connect`, while the owner
socket parked every connection unread. `server ensure` gave up after its fixed
`RESTORE_DEADLINE` (120 s) with `server.restore_timeout`. The next connect used
the remembered socket, the parked `identify` timed out after 2 s, and the app
classified that as a plain failure: `DaemonStartupState.unavailable`. The menu
then said "cmux could not start its background service. Quit and reopen cmux to
try again." The person quit 5 s before the cleanup ended. Nothing on screen said
that a cleanup ran, how far it was, or that waiting was the fix.

## Root causes

1. The owner had no way to say what it was doing while it restored: parked
   connections get no answer, and `--restore-progress` lines carried only
   `waited_ms`.
2. Every wait was a fixed timer (120 s ensure, 150 s app cap), not "is it still
   making progress".
3. An `identify` timeout against a live, restoring local owner read as
   "unavailable", and the copy for "unavailable" told the person to quit.
4. No general surface existed for slow work. Each subsystem (restore, journal
   maintenance, compaction, cleanup, backup removal, updates, uploads, remote
   connects) was silent or had its own one-off text.

## Rule (applies to the whole app)

Any job that can take longer than about 1 s and that blocks, delays or slows
something the person can do is a **long job**. A long job:

- registers in the one long-jobs registry of its process (daemon: cmux-tui-core
  `long_jobs`; app: CmuxNext `LongJobs`), never a private flag;
- reports progress (`done`/`total` when known, else a heartbeat), so waits are
  bounded by **stalls**, not by fixed timers;
- says what it blocks (`blocks`), so a refused action names the job instead of
  a generic failure;
- shows in the app's Activity surface while it runs, and in the refusal text of
  every action it blocks.

## Contract

### Job object (daemon wire, status file, app model)

```json
{
  "id": "output_cleanup:1793684016",
  "kind": "registry.output_cleanup",
  "title": "Cleaning up stored terminal output",
  "detail": "segment 120 of 900",
  "done": 120,
  "total": 900,
  "unit": "segments",
  "started_ms": 1793683713000,
  "updated_ms": 1793683850000,
  "blocks": ["startup"],
  "cancellable": false
}
```

- `kind` is a stable dotted id; the app localizes by `kind` and falls back to
  `title` (English from the daemon catalog). `detail`, `done`, `total`, `unit`
  are optional. `updated_ms` changes on every progress step or heartbeat
  (at least every 5 s while the job is alive).
- `blocks` values: `startup` (the owner does not accept clients yet),
  `terminals`, `workspaces`, `history`, `quit` (quitting now loses or repeats
  work), `none` (background only, still shown).

### Daemon (cmux-tui)

- `cmux-tui-core::long_jobs`: process-wide registry. `LongJobs::start(kind,
  title, blocks) -> LongJobGuard`; the guard sets progress and ends the job on
  drop. Updates are cheap (atomic store + coalesced publish, at most 4 per
  second).
- Status file `long-jobs.json` in the session state directory, written
  atomically (temp + rename) on change, coalesced to at most once per second,
  removed when no job runs. Shape: `{"version":1,"pid":N,"updated_ms":T,"jobs":[...]}`.
  It is readable while the socket parks connections.
- After attach: socket op `jobs.list` -> `{"jobs":[...]}` and the pushed event
  `jobs.changed` with the same payload, through the existing event
  subscription path. Capability name `long_jobs`.
  **Shipped wire names (daemon, 2026-11-02):** the v12 mux protocol names
  commands and events in kebab-case (its spec checks derive the name from
  the `Command` variant), so the op is the v12 command
  `{"id":N,"cmd":"jobs-list"}` -> `{"id":N,"ok":true,"data":{"jobs":[...]}}`
  and the event on the `subscribe` stream is
  `{"event":"jobs-changed","jobs":[...]}`. `jobs.list` / `jobs.changed` above
  mean these. Capability `long_jobs` in `identify.capabilities`. A job shows
  once it has run 1 s; events are coalesced to 4 per second.
- `server ensure` finds the status file at
  `<state root>/<session dir>/long-jobs.json`, the same session directory as
  `workspace-registry.sqlite3` (state root: `--state` or
  `CMUX_TUI_STATE_DIR`/the platform default). A file whose `pid` is not a live
  process is ignored. Only jobs whose `blocks` contains `startup` move the
  stall bound; background jobs (`blocks: ["none"]`) are listed but never
  extend the wait.
- Progress line shape: `{"progress":"restoring","session":S,"pid":N|null,
  "waited_ms":T,"jobs":[...]}` (`jobs` is `[]` when the owner publishes none).
- `server ensure --restore-progress` lines add `"jobs":[...]` read from the
  status file of the owner it waits on.
- `server ensure` waits while the owner is alive and its jobs (or the restore
  itself, without jobs) make progress. It fails with `server.restore_timeout`
  only after `RESTORE_STALL` (120 s) without any `updated_ms` change. A pure
  restore without jobs keeps the old 120 s bound.
- Instrumented first: output cleanup phase A (stage) and phase B (swap), removal
  of `.pre-output-cleanup`, registry open steps that can be slow (integrity
  check, migrations, resource invariants), terminal host adoption, journal
  maintenance and compaction, ledger retention, history check. Any other site
  that loops over the whole registry or the disk gets a guard too.

### App (CmuxNext)

- `ensure` with progress has no total cap: only `progressIdle` bounds it.
- Progress lines with jobs move `DaemonStartupState` to
  `.restoring([LongJob])` (new case). An `identify` timeout on the local owner
  while `server status`/the socket says an owner is alive is `.restoring`, not
  `.unavailable`.
- Refusal text while restoring names the job and progress, for example
  "cmux is cleaning up stored terminal output (43%). Wait for it to finish;
  quitting now restarts it." `daemonUnavailable` never tells the person to quit
  while an owner is alive.
- `LongJobs` (one owner, observable) merges daemon jobs (`jobs.changed`, each
  machine) and the app's own long jobs. One Activity surface shows them: the
  window connecting state during startup, and an indicator with a popover list
  after startup. Every app subsystem with slow blocking work registers there.
- Palette, CLI (`cmux jobs` lists them) and MCP read the same list.
- iOS: a row in `cmux-next-ios/verify/parity-mac.md` (the phone shows the same
  daemon jobs).

## App side as built (2026-11-02, branch feat-cmux-next-long-jobs-app)

- Model and registry: `LongJob`, `LongJobList`, `LongJobs` and `LongJobHandle` live in
  CmuxNextWakeups (core), so any package can register work without a new edge. Titles by
  `kind` are localized in CmuxNextDaemonService (`LongJob.displayTitle`, `LongJobs.xcstrings`).
- Launcher: `server ensure --restore-progress` has no total cap (idle bound `ensureTimeout`,
  20 s, per stdout line); each progress line's jobs reach `DaemonLauncher.restoreProgress`.
  An unanswered `identify` (only that reply) on the local owner's socket asks
  `DaemonLauncher.parkedOwner`: a version-1 `long-jobs.json` whose pid is alive and whose
  startup-blocking jobs (`blocks` has `startup`, as the daemon's `startup_progress_mark`) changed
  within the 120 s stall bound makes it `DaemonError.ownerRestoring`; background jobs show but are
  never progress. With no state directory (legacy channel session) the file is looked up under
  `CMUX_TUI_STATE_DIR` of the environment `server ensure` passes. A socket that merely accepts is no proof
  (a wedged owner's listener accepts too), so without a fresh file it stays a timeout.
- Startup: `DaemonStartupState.restoring([LongJob])`; a parked owner and every progress line
  move there, the startup deadline never turns it into `.unavailable`, and the store is not
  marked failed. `server.restore_timeout` (a stall) still shows "still restoring" with
  Retry Now / Restart cmux-tui; after it, only progress past the stall goes back to
  `.restoring`: a report from another owner pid, or one whose startup jobs changed
  (`OwnerRestoreProgress.Stall`). A new attempt, Restart cmux-tui and a connect forget the stall.
  Each report carries a sequence, so a hop queued before a failure never undoes it, and no report
  moves anything after the service stopped. Callers of `DaemonService.endpoint()` keep waiting while it restores (the owner
  will answer), as they wait while connecting.
- Connected: `jobs-list` on every connect (a reconnect after a drop too), `jobs-changed`
  replaces the list (a `jobs-list` reply older than an event is dropped), a drop clears it.
  While a connection that was up is down and its owner restores again (a restart, a crash),
  the reconnect's progress reports show as this machine's jobs. "Restart cmux-tui to update"
  waits for the successor as long as its restore reports keep coming (30 s without one).
- Surfaces: the launch window's connecting state (title, detail, percent bar, and "Don't quit"
  only while a job blocks `quit`), the top-row Activity indicator (setting
  `ui.activityIndicator`: `labeled`, the default since Lawrence's choice on 2026-11-03, or
  `icon`) with a popover whose rows update in place by job id and whose card fits them,
  refusals naming the job (`RefusalStrings.restoring`).
- Phone (issue 13742, allowed read-only): both lane policies forward `jobs-list` with no params;
  the phone asks once after its setup when `identify` lists `long_jobs`, follows
  `jobs-changed`, and shows the first job (title and percent) at the bottom of Workspaces.
- App jobs registered: update download and install (UpdaterService), browser import,
  Cloud uploads.
