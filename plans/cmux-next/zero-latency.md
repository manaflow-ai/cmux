# Zero-latency pages: every user action paints in the next frame

Owner: lawrence/cmuxterm-hq-48 (lane hq48-zero-latency). 2026-10-04. Companion to
[pane-protocol.md](pane-protocol.md) (decision 31, `opid`) and the cmux-tui working doc
`plans/cmux-tui-zero-wait-interaction.md` in cmuxterm-hq (its frame law, accept-first law and
order law are the same contract for the daemon and the TUI; this file is the contract for
webview pages).

## The claim

"Every action is 0 ms" cannot mean the backend answers in 0 ms. It means: **the visible
response to an input is painted in the same frame as the input, or the next one, and no await
sits between the input handler and the state change that paints.** Network, disk and process
work still take as long as they take; they become named state on a resource (pending, refused
with a reason), never an absence of response.

Measured as input-to-paint: the input event's `timeStamp` to the first `requestAnimationFrame`
after the DOM shows the response, plus every long task (over 50 ms) and the longest frame
interval in that window. The frame is 16.7 ms at 60 Hz (8.3 ms at 120 Hz). An action passes when
its response paints in the input's frame or the next one (paint within 2 frames), no frame is
dropped on the way (no frame interval over 1.5 frames) and no long task sits on the input path.

## First principles

(a) **Local-first state.** Every user intent applies at once, synchronously, to a local store the
UI renders from. The handler returns before any I/O starts.

(b) **Operation ids.** The intent is then sent to the backend with a client-generated operation id
(`opid`, decision 31). The id makes the operation idempotent: a provider that sees an `opid` it
already applied for the same caller (the page instance, across connections) answers with the
earlier result and applies nothing. A retry after a reconnect
reuses the id, so it never applies twice.

(c) **Ordering.** Intents on one resource (one file's viewed mark, one document, one preference
key) are sent one at a time, in input order, and acknowledged in that order. A later intent is
applied optimistically on top of the earlier ones, so it builds on the state the user sees, not on
the last confirmed state. Intents on different resources run in parallel, which is correct
because a resource is, by definition, the unit that does not commute.

(d) **Reconciliation.** The store keeps two layers: the confirmed base (what the backend said) and
the pending intents. What renders is the base with the pending intents folded over it. An `ok`
folds its intent into the base; an event that echoes an `opid` replaces the base and retires that
intent. Neither path shows the pre-intent state in between, so there is no flicker. A base that
arrives late (a load started before an intent) replaces the base and the pending intents still
apply on top, so a slow read can never undo a newer input.

(e) **Rollback.** A refused intent leaves the pending layer; the visible state is recomputed from
the base and the remaining intents, so the revert is exact. The refusal is recorded as a specific,
visible error (op, resource, code, message). Later intents on the same resource are rebased
(re-applied on the new base and still sent) or cancelled with their own error, per intent kind.

(f) **Prefetch and prewarm.** Anything an action needs next (catalogs, branch lists, the picker's
recents, the next file's text, worker code, grammar chunks) is fetched or loaded ahead and
cached. No network call and no lazy chunk sits on the input path.

(g) **Work off the input path.** Heavy work (parsing, highlighting, fuzzy matching big lists,
re-layout of thousands of rows) runs in workers, idle callbacks, transitions or chunks, so the
input frame stays under budget. The input frame does only the state change that paints.

(h) **Bugs eliminated by construction.**
- No ad-hoc loading flags: "saving", "pending" and "failed" are derived from the intent queue.
- No lost updates: the base is replaced, intents are re-folded, nothing is overwritten.
- No race between a slow response and a newer intent: responses settle their own `opid` only, and
  base replacement keeps newer intents.
- Superseded work is cancelled: a newer load aborts the older one's `AbortSignal`; a queued intent
  that a newer one supersedes is dropped before it is sent.
- One path for every action: a shortcut, a button and a menu item dispatch the same intent.

## Strongest objections and mitigations

- **"Optimistic UI lies when the backend refuses."** It shows the user's intent before the backend
  agrees. Mitigation: the refusal reverts exactly (the base never contained the intent) and leaves
  a specific error in the same place the change was shown. Intents whose refusal would be
  dangerous to hide (a destructive write, a payment) are not optimistic: they are sent as
  `pending` state the UI shows as such (still within one frame; the response to the input is the
  pending state, not the result). The rule is per intent kind, not global.
- **"Caches cost memory."** Prefetch is bounded: a fixed number of entries per cache with LRU
  eviction, keyed by what the next action can reach (the visible list, the adjacent file), never
  "everything". The intent queue is bounded by in-flight intents; settled intents leave it, and
  the trace ring buffer has a fixed size.
- **"Two layers of state are complex."** The complexity already exists in every page as ad-hoc
  flags, `latestRef`s and "ignore if stale" checks. One store with one rule set and one test suite
  replaces them. The page's own reducer stays a pure function; the store owns ordering, ids,
  reconciliation and rollback.
- **"Idempotency needs provider work."** Yes: providers must keep the last N `opid`s per connection
  (or per resource) with their results. Until a provider does, the client still gets ordering,
  rollback and supersede; a resend after a reconnect is the only case that needs the provider, and
  the store resends only intents that never got an answer.

## The generic layer

`webviews/src/protocol/intents/`:

- `IntentStore<S>`: a typed reducer over local state, a per-resource FIFO queue, an `opid` per
  intent, send through any `IntentSender` (a protocol `Session` or a page bridge `PageClient`),
  reconcile from events by `opid`, rollback on `err`, supersede and cancel, a trace ring buffer.
- `react.ts`: `useIntentState(store, select)` (a `useSyncExternalStore` subscription) and
  `useIntent(store, name)` (a dispatcher). Both are plain hooks the React Compiler memoizes.
- The latency harness (`bun run latency`): `webviews/scripts/latency/run.ts` builds the harness
  pages (`webviews/test/latency/*.html`) with the shipped production settings
  (`vite.config.latency.ts`), serves them, and measures each page's named actions
  (`test/latency/actions.ts`) in headless Chromium and WebKit with the in-page probe
  (`test/latency/probe.ts`) and the test helper `measureAction` (`test/latency/measure.ts`). The pages
  run the real page modules on in-page mock hosts that answer after 40 ms, so an await on an input
  path fails. `--ci` writes JSON and a GitHub step summary and never fails; `--dev` measures the dev
  server; `--cpu-throttle N` slows Chromium to find the heavy actions. The CI job
  (`latency-scoreboard` in `.github/workflows/cmux-next-web-bundles.yml`) is a non-blocking
  scoreboard; it becomes required after 3 days without a flake. `test/latency-harness.test.ts`
  checks the probe itself (a synchronous response passes, an awaited one fails, a busy handler is a
  long task).
- Verdicts: the gate is the 60 Hz verdict. Headless Chromium ticks near 120 Hz, so its 120 Hz verdict
  is measured; WebKit ticks at 60 Hz, so its 120 Hz verdict adds "input-to-response work within
  8.3 ms" to the 60 Hz rules (an estimate).

## Adoption (first pass)

- Diff viewer: viewed marks and viewer preferences go through an intent outbox (`src/diff-writes.ts`):
  one write in flight per file or preference keys, in input order, a newer value replacing a queued
  one, an opid on each page-host write. Before, every change was a fire-and-forget call, so quick
  toggles raced. The files filter defers the diff column (`useDeferredValue`): the field and the
  files tree answer the keystroke in its frame. Page data attributes on `<html>` and `<body>` are
  written only when they change (each write invalidated the whole page's style after every state
  change).
- Markdown editor: a followed link (and back/forward) names its file in the toolbar and dims the
  document in the click's frame (`navigating`); a file that does not open says so in the status
  (`navigationFailed`). The link target is not prefetched: `cmux.markdown.open` records recents and
  moves the watcher, so it is not a read. A side-effect-free `cmux.markdown.read` host op would allow it.
- Picker (`PathPicker`): listings are prefetched (the parent and the highlighted folder) into a
  bounded `PrefetchCache`; entering a folder and going up show the next level in the input's frame,
  and an uncached level moves the location at once while its rows load.
- Empty states and the other diff toolbar actions were already local-first; the harness confirms
  them.

- Diff files panel (coordinator decision, 2026-10-04): the toggle no longer lays out the diff in
  its frame. The panel slides at once (a composited transform, the same spring keyframes, so WebKit
  still runs it at the display rate), and the diff column changes width once, when the slide ends.
  Opening, the diff stays full width under the panel; closing, a curtain (the panel's resting box
  in the panel's background, scaled from its left edge on the compositor with the slide) covers
  the strip the panel uncovers. A toggle mid-slide reverses from the panel's position and keeps
  the diff's width. `test/files-panel-coverage.test.ts` checks every animation frame of a close,
  an open and both mid-slide reverses for an uncovered strip, in Chromium and WebKit; the harness
  has a "sidebar reverse" case. WebKit sidebar toggle: frame gap 27 to 34 ms before, 16 ms after.

## Known limits

- WebKit, diff viewer: jump to file sits at the 2-frame limit on a loaded machine. It waits for
  CodeView's next-frame render of the target; laying the target out in the input frame instead
  dropped a frame in WebKit, so it stays.
- While a closing panel slides, the strip it uncovers shows the panel's background (the curtain),
  not diff text: the diff widens only when the slide ends (131 ms).

## Follow-ups (for their owners)

- Rust and Go providers: carry `opid` on `call`, echo it on every `ev` the call causes, and
  apply each opid once per caller (decision 31; `OpidLedger` is the TS reference).
- A side-effect-free `cmux.markdown.read` host op, so a followed link's file can be prefetched.

## Native actions: the budget contract (PL-instant, 2026-10-24)

Lawrence (2026-10-23): "every single action the user can take and resulting animations and actions etc
are <10ms, for literally everything. we need to systemically make the codebase such that this is easy
to do." The webview rules above (local-first state, operation ids, reconciliation, rollback) hold for
every native action too. This section is how the native app makes them the default.

### The budget

Every `ActionRegistry` run, from every entrypoint (key, menu, palette, context menu, toolbar and tab-bar
clicks, drag and drop, sidebar, Home, Settings, CLI, socket, MCP), reaches the end of the Core Animation
commit after it in under 10 ms (p95; p99 and max are reported too), with 0 dropped frames at 120 Hz, in
the light session and in STRESS (`scripts/cmux-next/perf-stress-session.py`), on macOS 26 and 27. The
time is `action.commit` (`CmuxNextSignposts`): the registry starting the run to the end of the commit
(`CommitBoundary`). Work deferred to a later turn commits later and is not inside that time: the rules
below keep the visible change inside it.

### 1. The handler returns its change (`ActionEffect`)

A handler is `registry.bindEffect(id, effect: { invocation in ... })` and returns an `ActionEffect`:

| Effect | When | What the registry does |
|---|---|---|
| `.done` | the whole change happened on this turn (a selection, a focus move, a view toggle) | nothing |
| `daemon.intentEffect(label, intent) { body }` | a daemon change the store can show first (an `Intent`) | the intent is in the store before the handler returns; after the handler's turn the registry sends `body`; the reply settles the intent, a failure takes it out of the store exactly and shows "<action> did not apply: <reason>" in the refusal HUD |
| `daemon.commandEffect(label, rollback:) { body }` / `.applied(ActionConfirmation(...))` | the change is shown outside the store (a sidebar row, a view) | sends after the turn; on failure runs `rollback` and shows the notice |
| `.waiting(reason, work)` / `daemon.waitingEffect` | nothing can show before the reply (`ActionWait`: `daemonEcho` is debt, `network`, `externalProcess`) | sends after the turn, counts the run (`ActionRegistry.waitingRuns`, by action and reason) |
| `.refused(reason)` | the action cannot act on this invocation | `refuse(reason)` |

The handler never awaits and never starts the remote work itself: the registry starts it after the
handler returned, inside the run's `ActionRunScope` and the App's machine routing, tracks it for a caller
that waits for the effect (`capturingWork`, the control socket's `action.run`), and reports a failure
once: to a capturing caller, else to `remoteFailureObserver`. One mutation path for every entrypoint.

Untyped binds (`invoke:`, `run:`, `handler:`, a trailing closure) stay for old code; their waits are
invisible in the type. `ActionRegistry.effectBoundCount` / `legacyBoundCount` count both kinds.

### 2. The pre-push ratchet refuses new waiting code

`scripts/cmux-next/guardrails.py` rule `action-wait` refuses, in lines a push adds under `Sources/`: an
untyped bind (`.bind(... invoke:` / `run:` / `handler:` or `.bind(...) { x in`), a `.waiting(.` effect and
`waitingEffect(`. Escape: `// action-wait-allow: <why nothing can show before the reply>`. Base debt is a
count per file (editing an old bind adds none), fail open, part of the < 1 s guardrails pass. Known gap:
a bind whose `invoke:` label is on the line after `.bind(` is not seen (one-line rule); review catches it.

### 3. The always-on monitor (`ActionBudgetMonitor`)

`SignpostActionRunTiming(monitor:)` reads `CLOCK_UPTIME_RAW` at the run's start and at the end of its
commit, begins and ends the run's board span (atomics), and writes one fixed-size slot (`ActionRunSlot`: the action's interned index, entrypoint, outcome,
times; no string, no reference) into a ring preallocated at launch, on the main actor. No allocation, no
lock, no I/O, no formatting on the action's path; the action is interned when it is bound. Measured by
`ActionBudgetMonitorBench` (Release, ns per run and per batch; numbers in perf-lead.md section 5).

Everything else runs after the commit and off the main actor:
- Every 128 runs (half the ring) the monitor hands the filled half to `ActionBudgetReporter` as one batch;
  `ActionBudgetLedger` folds it into a latency histogram per report id and entrypoint (fixed bucket edges
  2, 4, 6, 8, 10, 12, 16, 24, 33, 50, 100, 250 ms, then over). The opt-in nightly report fields:
  `action_budget_ms`, `action_latency_bucket_edges_ms`, `action_runs_total`, `action_runs_excluded`
  (missed commits, nested run loops: not the run's work), `action_runs_dropped` (the reporter fell
  behind; never blocks, never grows), `action_over_budget_total`, `action_latency[]` = `{id, entrypoint,
  count, buckets, max_ms}`. Ids are catalog ids only: cmux.json commands report as `custom`, any other
  id outside the catalog as `extension` (`ActionReportNaming`; their ids carry user text).
- Each run is published on the main-thread task board (`MainTaskBoard.beginSpan`, PL-main's scheduler) from
  its start to its commit with the 10 ms budget: the watchdog (the one sampler) samples a run that passes it
  and writes an `over_budget` record named by the action id. An over-budget run goes to the reporter at once;
  a Debug build writes one line to the app log (category `action.budget`) with the action, entrypoint, times
  and that record's stack.
- `debug.action_budget` (DEV): the counters, the waiting-effect counts and the newest runs.
- Debug menu > Toggle Action Latency HUD (DEV and NIGHTLY, closed by default): the newest 16 runs with
  their times, over-budget runs in the danger color. Closed, it holds no reader: zero cost.

### 4. Main-thread rules for an action's synchronous part

No synchronous daemon read, no disk I/O, no lock that waits, no O(session) rebuild (all workspaces, all
tabs, all rows) on the input's turn. Read from the store's mirror and the indexes (`StoreIndex`); move
I/O to an actor or the daemon; rebuild only what the change touched.

### 5. Every action is benched, derived

`scripts/cmux-next/every-action-sweep.py` (owner: PL-instant) runs every id of the live catalog
(`action.list`) through its real entrypoint in the light session and STRESS on the fleet, timed by the
same signposts. A new action needs no list entry; one the sweep cannot set up shows as a skipped row with
its reason, and the fixture belongs in the sweep's precondition table in the same push.

### Adding an action that is fast by design

1. Catalog descriptor (`CmuxNextActions/Catalog`), strings in every locale.
2. `registry.bindEffect(id, effect:)`: change what the person sees, return the rest as an effect. A daemon
   change is an `Intent` (add a case to `Intent` and `IntentOverlay` if none fits: apply, undo, and a red
   test in `CmuxNextDaemonTests` that it shows in the turn, survives an older snapshot and rolls back).
3. Nothing in the handler awaits, reads a file, takes a lock or walks the whole session.
4. Run the sweep for the id on the fleet (`--only id`), light and STRESS, and look at the HUD while you
   dogfood.
