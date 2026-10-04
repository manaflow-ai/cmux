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
after the DOM shows the response, plus every long task (over 50 ms) that overlaps that window.
The budget is one frame of the display: 16.7 ms at 60 Hz, 8.3 ms at 120 Hz.

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
- The latency harness (`webviews/scripts/latency/`, `bun run latency`): per page, a named list of
  actions, each measured in headless Chromium and WebKit; it fails when an action's response takes
  more than one 60 Hz frame or has a long task on the input path. It starts as a non-required
  scoreboard job and becomes required after 3 days without a flake.

## Decision 31 (wire)

`call` may carry `"opid":"<string>"` (1 to 128 characters of `[A-Za-z0-9._:-]`), a client-generated operation id for one user intent. A provider that applies the call echoes the id on every event the call caused: `{"t":"ev","sub":…,"seq":…,"data":…,"opid":"<id>"}` (envelope field, outside the IR-validated `data`). A provider applies an opid once per caller identity (the token's `sub`, the page instance, so a resend on a new connection after a reconnect is covered): a repeated opid is answered with the first run's `ok` or `err` and runs nothing. Remember at least the last 1024 opids per caller for 10 minutes. `ok` and `err` are matched by `id` and carry no opid. A malformed opid is a bad message (`cmux.protocol.bad_message`). TS: `CallOptions.opid`, `HandlerContext.opid`, `emit(data, {opid})`, `onEvent(data, seq, {opid})`, `OpidLedger` for providers, and the page bridge carries it (`PageClient.call(op, params, {opid})`). Rust and Go providers follow; no Rust change in this slot.
