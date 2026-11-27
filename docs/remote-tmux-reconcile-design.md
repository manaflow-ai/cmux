# Remote-tmux sizing as reconciliation

This document proposes replacing the edge-triggered execution model of the
remote-tmux sizing machinery with a reconciliation pass. It keeps every
invariant and measured fact in `docs/remote-tmux-sizing-design.md` — the
feed-forward claim, tmux as grid authority, the per-window `refresh-client -C`
ceiling, chrome parity from one shared config, correctness as a settled
property. What changes is how the code gets from an event to a settled screen.

## Why the execution model is the problem

Today every event carries its own payload and its own decision. A geometry
callback arrives with a size and must judge it against a window bound sampled
at a different instant (`noteContainerSize` in
`Sources/RemoteTmuxWindowMirror+SizingTransaction.swift`). An imposition is a
send-and-hope: bonsplit applies it on a later turn. So the host grows a parity
checker (`rearmIfOutputMissedPlan`) to notice misses, then a re-arm cap to keep
the checker finite, then a keyed hold (`dividerResizeInFlight`) to keep the
checker from firing during a tmux round trip. And the hold needs a 2-second
grace timer for the reply that never comes. Inside bonsplit the same shape repeats
one layer down: `imposedEpoch` to force a re-apply the dedup would swallow,
`imposedRetryBudget` to bound re-applies AppKit refuses, and
`renudgeImposedDescendants` to fix children a late parent apply moved
(`vendor/bonsplit/Sources/Bonsplit/Internal/Views/SplitContainerView.swift`).

Each of these mechanisms is a correct patch for a real bug, and each one exists
because an edge, once consumed, is gone. If the handler drops the payload,
mis-judges it against torn state, or completes against state that changes a
turn later, no future edge re-delivers the truth. So every such hole needs its
own hand-written re-arm, and every re-arm needs its own bound. The day's bug
ledger (twelve entries, replayed in full below) is the same failure twelve
times over: state that only a lost edge could have corrected.

Reconciliation removes the class. An event stops being a carrier of truth and
becomes a hint that truth may have moved. All truth is read fresh, in one
instant, by one pass; the pass owns every decision; and any early exit either
proves there is nothing to do or leaves the dirty state set so the next pass
retries. Nothing can be lost because nothing is ever in flight inside the app —
only between the app and tmux, and that window is bounded by the protocol
itself, not by time.

## The model

Every mirror (`RemoteTmuxWindowMirror`, one per tmux window) carries a dirty
generation. Events — the SwiftUI geometry callback, `%layout-change`,
calibration samples, visibility flips, drag begin and end, portal
notifications, command replies dequeuing — do exactly two things: update the
durable fact they own (the connection stores the new layout tree, the
calibration fold ingests the sample into
`minNonGridWidthPxByScale`/`minNonGridHeightPxByScale`), and mark dirty. They
carry no geometry into the pass, make no judgments, write no views, and send
nothing. Marking while a pass is already scheduled schedules nothing new, so
N events between passes cost one pass — that is the coalescing invariant, and
it is what keeps work bounded under load.

Dirty is a generation counter, not a flag. Marking increments it; a pass
claims the current generation at entry, before it reads anything; and a
generation past the claim at pass end — including marks raised by the
commit's own ripples — guarantees exactly one follow-up run. Terminal
convergence is an empty diff with the generation unchanged through commit.
Today's code patches this exact failure mode twice over, each site by hand:
`performSizingPassNow` clears `sizingPassScheduled` before doing any work
(`RemoteTmuxWindowMirror+SizingTransaction.swift:212`), and the portal keeps
an explicit in-pass latch for requests arriving mid-sync
(`resyncRequestedDuringPass`, `Sources/TerminalWindowPortal.swift:851`).
Generations state the semantic once. A unit test pins it: a mark during
commit yields exactly one more pass, and a mark on an idle mirror yields
exactly one.

```
 events                        the pass (one main-queue turn,
 ------                        outside all layout callbacks)
 %layout-change  --+           -----------------------------
 geometry cb     --+   mark    +----------+
 calib sample    --+-- dirty ->| snapshot |  read the world, one instant
 drag begin/end  --+  (gen++)  +----------+
 visibility flip --+           | desired  |  pure function of the snapshot
 reply dequeued  --+           +----------+
                               | diff     |  desired vs actual, classified
                               +----------+
                               | commit   |  writes + sends, synchronous
                               +----+-----+
                                    |
                     did the generation move during the pass?
                       yes -> exactly one follow-up pass
                       no  -> converged: empty diff, done
```

The pass runs on the next main-runloop turn, outside every layout and
observation callback, in four phases, all synchronous within the one drain.

First it snapshots the world in one instant. The snapshot holds the probe
view's frame (`MirrorHostProbeView` already backs the whole mirror region,
so its frame *is* the container — the pass reads it directly instead of
trusting a callback-carried SwiftUI proposal), and the hosting window's
content bound through that same probe. It also holds the tmux base and
visible layout trees, the calibration constants, the drag-session state,
the visibility state, the pending user intent (a drag-end waiting to be
sent), and the in-flight send set. The calibration sweep is ordered as an
event, not folded into desired computation. Immediately before the
snapshot, still in the same drain, the sweep polls each pane's current
sample the way `refreshGeometryConstants` does and lets the folds ingest.
After that, the constants are copied once into the snapshot and nothing
downstream may touch a live surface. Today's
code is the anti-pattern this ordering forbids: `updateClientSize()` calls
`refreshGeometryConstants()` from the middle of the sizing pass
(`RemoteTmuxWindowMirror+SizingTransaction.swift:597`), and `ingest` mutates
the folds and schedules another pass from inside the computation consuming
them (lines 150-174). The sweep must run at all because the hidden-window
calibration deadlock has no event to wait for — the claim needs a constant,
the constant needs a surface resize, and tmux resizes only once the window
is claimed, the cycle the reconcile-time sweep in
`RemoteTmuxWindowMirror.reconcile(layout:)` breaks today. Scale changes are
defined, not incidental: padding is a per-scale device constant, which is
why the folds are keyed by backing scale
(`RemoteTmuxWindowMirror.swift:212-221`); a display move is an event that
marks dirty, a snapshot whose scale has no fold entry yet early-outs
re-marking, and the first sample at the new scale is a guaranteed event
because every surface re-renders on a scale change.

Sampling the frame and the bound in the same instant stops readings from
being torn across two moments. It does not stop poisoned readings. A SwiftUI ancestor adopting a content ideal
inflates real NSView frames, and it does so persistently, not transiently —
clamping such a reading banks the window bound plus whatever chrome sits
between window and mirror, which the live fuzz measured running 30-40pt wide
at rest (the drop rationale in `noteContainerSize`,
`RemoteTmuxWindowMirror+SizingTransaction.swift:44-79`). So drop-don't-clamp
survives as a snapshot validity predicate: a probe frame beyond the window
bound is invalid and is never clamped into the world. The mirror keeps the
last valid container as a durable fact; an invalid sample never overwrites
it, and the next pass that observes a valid one refreshes it. Deleting the
parked readings is sound only if the probe supplies the retry edges the
parking supplied, and today it does not: `MirrorHostProbeView`'s
`viewDidMoveToWindow` only updates the weak pointer
(`RemoteTmuxWindowMirrorSplitView.swift:139-152`). Under reconcile the
probe's move-to-window and frame-change notifications become explicit dirty
edges, so a mirror that mounts, reattaches, or gains its first real bound
wakes the pass with nothing parked. The current spec's warning stands —
deferring is safe only when a retry edge exists (the fresh-connect section
of `docs/remote-tmux-sizing-design.md`) — the edges just come from the probe
now. A first-ever reading with no hosting window keeps the display-ceiling
fallback, so a never-hosted mirror still makes its initial claim.

Second it computes desired state as a pure function of that snapshot. The
outputs: the claim grid (`clientGrid`, unchanged — feed-forward, reads no
tmux geometry), the render frame (grid plus chrome, clamped to the
container, as `updateRenderFrameSize` computes today), each split's
first-child extent in points (the planner, unchanged), each pane's outer
frame, the portal host frame, and the tree's hidden bit. The desired
function enforces one hard rule itself, instead of trusting every caller to
remember it: no desired extent may exceed the measured region. That is
plan(w) ≤ w on every axis, applied to the render frame and to every planned
outer. (The current branch already enforces this rule as a clamp on
`renderFrameSize` and on the planned outers. Under reconcile the same rule
is checked once, as an assertion on the desired function's output.) The calibration constants are
the one exception to the rendered-data ban. A sample really is a
measurement of a painted surface. What makes it safe as an input is the
monotone fold: it converges to a device constant, so it cannot oscillate or
feed geometry back. And the constants reach the computation only through
the snapshot.

Desired is also computed under the same feasibility clamps the writes will
meet — and the two must be provably the same function, not two functions
that usually agree. AppKit can refuse an
exact target (`Coordinator.syncPosition` and
`reapplyDividerForThicknessChange` in `SplitContainerView.swift` both branch
on the refused case), so the planner's clamp must be the very function
bonsplit applies at write time — today that math is private to the
coordinator (`clampedDividerPosition`, backed by `effectiveMinimumPaneSize`
and `normalizedDividerBounds`); the contract change below exports it so the
desired function and the write share one implementation. The diff carries an
explicit tolerance no tighter than AppKit's rounding at the backing scale
(the existing comparisons use 0.01pt on divider extents and 1.5pt on pane
outers; the pass adopts shared named constants for both), and equality
everywhere below means within tolerance. A DEBUG assertion after every
commit apply checks that the clamped target equals the post-apply frame
within tolerance; while it holds, desired is reachable by construction and
the diff can reach zero.

The design does not rest on that assertion being forever true. The 32pt
tab-bar floor today's plans clamp to is measured emergent behavior, not an
API guarantee — bonsplit exposes no constant for it, and the value was
fitted from live misses (the `bonsplitMinimumPaneExtent` note in
`RemoteTmuxNativeLayoutMetrics.swift:23`) — so the feasibility model can be
wrong in ways only the frames reveal. The bound for that case is one circuit
breaker, and it is the same policy as the constraint fallback rather than a
second mechanism. When three consecutive passes produce the same write from
the same snapshot with the same miss, the residual is classified infeasible
and reported — DEBUG-loud and counted. No further writes go to that split
until a constraint-relevant edge resets the breaker: a container resize, a
structure change, an appearance config change. Three matches the
cap the parity re-arm spends today (`outputParityRearmsSpent < 3`,
`RemoteTmuxWindowMirror+SizingTransaction.swift:367`). The breaker is
expected to be dead code while the clamp assertion holds; a trip is the
signal that the exported clamp and AppKit's real behavior have diverged,
which is exactly what the floor's discovery looked like.

Desired is never stored across passes; there is no plan to go stale.

Third it diffs desired against ACTUAL. Actual means frames read from views —
`arrangedSubviews[0].frame` for a split, the hosted view's frame for a pane,
the reference view's bounds for the portal host — never a layout engine's
solution, never our own last write, never anything derived from rendered
content (the calibration fold excepted, as above). On the tmux side, actual
means the layout tree the server last published and the acked claim ledger
described in the next section. Each mismatch is classified. If an in-flight
send already asks tmux for exactly this, the mismatch is *awaiting* and the
pass leaves it alone. If the split is user-owned (a live drag session, or an
unsent or unanswered drag intent), the pass excludes it from view writes. If
the breaker holds it, it is infeasible-reported. Otherwise the mismatch is
drift, and the pass emits a write.

```
 for each mismatch between desired and actual:

   an in-flight send already asks for it?  -> AWAITING    leave it alone;
                                                          the reply marks dirty
   the split is user-owned (drag)?         -> USER-OWNED  no view writes
   the circuit breaker holds it?           -> INFEASIBLE  reported, no writes
                                                          until a reset edge
   otherwise                               -> DRIFT       emit the write
```

Fourth it commits: the minimal set of writes, applied top-down from the one
snapshot, still outside all layout callbacks — and applied synchronously.
Today `setImposedFirstExtent` only stores the extent and defers the real
`setPosition` a runloop turn (`syncDividerNow` in
`SplitContainerView.swift:569-585`), and the resize callbacks that apply
provokes return early under the programmatic-depth guard
(`splitViewDidResizeSubviews`, line 1317), so a refused deferred apply is
invisible to everyone: no outcome to read, no notification to mark dirty.
That deferral exists because impositions used to be triggered from inside
layout passes; the commit runs outside them by construction, so the reason
is gone. Bonsplit gains a synchronous apply path for external impositions —
a real contract change, scheduled in migration step one, which also corrects
the earlier claim that step one leaves the vendor API untouched. With the
apply synchronous, the pass reads the outcome frame immediately after each
write, and the clamp-equality assertion runs right there. View writes remain
idempotent instructions with `setImposedFirstExtent` as the primitive; sends
to tmux move the corresponding intent into the in-flight set only when the
transport accepts them. Callbacks the commit provokes from outside the depth
guard run their handlers, which only mark dirty — a commit whose writes
ripple moves the generation and buys exactly one follow-up pass, and a
follow-up whose diff is empty ends the chain.

Every early exit in the pass is one of two kinds — terminal (the diff is
empty and the generation held; nothing to do) or re-marking (a fact the pass
needs is missing or mid-flight, and the event that will supply it marks
again). There is no third kind. That single rule is the design; everything
below is its consequences.

Proposed surface, kept minimal: `markSizingDirty()` replaces both
`setNeedsSizingPass()` and `setNeedsSizingPassIgnoringInputs()` (there are no
inputs to ignore — no input memo exists); `reconcileSizing()` replaces
`performSizingPassNow()` (plain `reconcile()` would collide with the
existing `reconcile(layout:)`); a `WorldSnapshot` value groups the phase-one
reads; an `InFlightSend` entry keys a tracked command to its resolution.
All four are proposed names, not existing APIs.

## The tmux side: what our instructions actually do

This section pins tmux's half of the loop from its source (tmux 3.7, tag
`3.7`, files cited by line), so nobody has to re-learn it by observation.
tmux runs its own reconciliation: we never send it a layout tree. Our
desired layout is decomposed into two instruction kinds, and tmux converges
its own cell tree under them.

The window's outer size travels as a claim: `refresh-client -C 'WxH'` for
the whole client, `refresh-client -C '@id:WxH'` for one window. The
per-window form stores the claim in a per-client record
(cmd-refresh-client.c:82-131) and synchronously recalculates every window
on the server. Each split's position travels as its own `resize-pane -t
@w.%p -x N` — one divider at a time, in cells, where a percentage is of the
whole window, not the pane's container (cmd-resize-pane.c:103).

What tmux does with a claim, in order: it decides which clients count
(`clients_calculate_size`, resize.c:113-264), resizes the window
(`resize_window`, resize.c:25-66), spreads the delta over its tree
(`layout_resize` + `layout_resize_adjust`, layout.c:617-668, 489-536),
recomputes offsets and pane rects (layout.c:244-411), and notifies. Facts
that shape our side, each verified in source:

- A per-window claim is a ceiling in every `window-size` mode, including
  latest and manual (the clamp block at resize.c:217-244). It can shrink a
  window below another client's size; it can never grow one past what
  other participants allow.
- A control client can essentially never be the "latest" client:
  `w->latest` is set by real key input and tty resizes, and the tty-resize
  path skips control clients (server-client.c:2249-2251). Co-attached with
  a regular client under `window-size latest`, our claims act only as
  clamps.
- If a claim cannot fit the tree's minimums (1 cell per pane, +1 row for a
  border-status edge, layout.c:434-483), tmux clamps the WINDOW UP to the
  tree minimum (resize.c:49-52). The claim is silently not honored, and
  claimed == layout can never become true. The pass must read the
  published layout as the feasibility verdict and stop re-claiming — this
  is the infeasible-reported class, straight from tmux's source.
- Window-resize redistribution is equal-absolute, not proportional:
  siblings gain or lose one cell each, round-robin (layout.c:519-535).
  tmux erodes split ratios on every resize, which is why imposing split
  positions after size changes is permanent work, not a transitional
  crutch.
- No-ops still notify. A `resize-pane` that changes nothing — already at
  target, or fully clamped — still emits `%layout-change`
  (layout.c:726-728 notifies unconditionally). A claim echoes one
  `%layout-change` PER WINDOW on the server, changed or not (the immediate
  path skips the size-unchanged check, resize.c:382-388). Identical-string
  layout lines are normal traffic, O(windows) per claim. The one genuinely
  silent case: `resize-pane` along an axis with no container of that
  orientation above the pane (layout.c:686-687).
- A divider move's result can differ from the target: the delta is
  measured against the nearest ancestor cell under a container of the
  right orientation (a subtree, not the pane, layout.c:671-701), and the
  grow/shrink walk stops when neighbors run out of shrinkable space.
- `%layout-change` is ordered after the `%end` of the command that caused
  it, on the same stream as `%output` (notify goes through the global
  queue, notify.c:230; reply guards are written synchronously,
  cmd-queue.c:619-676). But commands pipelined in one write all reply
  before any of their notifications — attribution by position only works
  when one command is in flight per window, which is what the FIFO does.
- The pty resize (SIGWINCH) is deferred and rate-limited: one resize per
  pane per 250ms, intermediate sizes collapsed
  (server-client.c:1592-1661). The layout string updates immediately, so
  the `%output` repaint flood always trails the `%layout-change`, and
  content lag right after a resize is tmux pacing, not us.
- Layout-string rects are cell sizes, exclusive of the border line between
  siblings (sum(child+1)-1 = parent, layout-custom.c:147-155), and they do
  NOT subtract border-status rows — an edge pane's real terminal is one
  row shorter than the string says (layout.c:378-383). The chrome math
  does that subtraction.
- Once a client claims anything, its tty size participates in sizing for
  every window without a per-window entry (the changed flag is
  client-global, resize.c:91-94). Per-window claims must be paired with a
  sane plain claim, which the connection's session-wide envelope is.

The settle round trip, both sides:

```
 our claim ledger                   tmux                   our published model
 ----------------                   ----                   -------------------
 refresh-client -C '@1:184x44' -->  recalc + layout_resize
                                    %end (ack)        -->  FIFO entry resolved
                                    %layout-change @1 -->  stage raw tree, gen++
                                                           list-panes fetch -->
                                    verified rects    -->  publish windowsByID[@1]
                                                           pendingLayouts drains

 settled(@1) :=  claimed size == published layout size
              && no pending layout for @1
              && no @1 claim or fetch in the command FIFO
 (and the fuzz oracle adds: rendered pane grids == assigned spans)
```

One correction this source reading forced. The divider-hold design said "a
no-op resize emits no `%layout-change` at all", and the barrier existed to
prove that case. tmux 3.7 notifies on no-ops too, so the barrier's real
roles are narrower and still necessary: it is the ordering fence that makes
"no pending layout for this window" a complete answer at ack time, and it
catches the one silent case (no container of the requested orientation).
The shipped code is correct under both readings — a no-op's
identical-string layout event stages a pending layout, the verdict defers
to publication, and the reconcile judges the sent span against the
published tree — but the old rationale was unfalsifiable by our tests,
because both hypotheses produce the same observable release. Only reading
the source distinguished them. That is the layer-3 lesson in miniature.

## Authority and the in-flight set

tmux owns cell assignment; that does not change. What changes is how the app
tells "tmux hasn't answered yet" apart from "the views drifted."

The control connection already correlates every command to its reply
positionally: each send appends to the `pendingCommands` FIFO and each
`%begin`/`%end`/`%error` block dequeues exactly one entry
(`handleCommandResult` in
`Sources/RemoteTmuxControlConnection+CommandResults.swift`). Control mode
guarantees a reply block per command, error or not, and `sendTracked`
(`RemoteTmuxControlConnection+Commands.swift:14`) already packages that as
exactly one edge per send — `%end`, `%error`, or stream reset. That
resolution is the ack barrier: a protocol edge, ordered with the server's
other output, that arrives exactly once regardless of load.

For a divider resize the ack alone is not the whole edge. The connection
quarantines `%layout-change` behind a rects fetch — observers see nothing
until the layout publishes or drops
(`RemoteTmuxControlConnection+LayoutPublication.swift`) — so at the moment a
resize's reply dequeues, the layout it caused may still be in flight to
publication, and judging "no-op" on the ack would misread it.
`hasPendingLayout(windowId:)` (+LayoutPublication.swift:100) exists for
exactly this consultation. An in-flight divider send therefore resolves in
two phases: first the tracked command's block resolution — today
`requestResizePane` sends untracked through plain `send`
(`RemoteTmuxWindowMirror+ControlMutations.swift:101`); it becomes a tracked
send — and then, on `%end`, the layout question. No pending layout for the
window means every event the resize could produce is already on our side
(tmux notifies even on no-op resizes — see the tmux section — so the empty
case is either the silent missing-container path or a layout already
published): the split leaves awaiting in that same pass, and its off-plan
divider is now plain drift, written back onto the plan. A pending layout
hands judgment to the publication, whose reconcile is itself a dirty edge
and arrives carrying the verified tree. `%error` and stream
reset resolve the entry immediately. That is the no-reply heal with no
clock: the deadline in `recordDividerResizeAwaitingReply` and its
`dividerResizeReplyGrace` exist only because today's hold is released by
matching layout shapes instead of by the command's own resolution.

The claim has three states, two of which exist today. Requested is what the
mirror last asked for — `lastWindowSizes`, written synchronously before the
debounce; the connection's own comment calls it "the last size any writer
requested" (`RemoteTmuxControlConnection.swift:150`). Sent is what the
transport accepted — `sentWindowSizes`, recorded only after `sendInternal`
returns true (`RemoteTmuxControlConnection+Sizing.swift:184-191`), because
recording an attempted send claims the server holds a size it never
received, and dedup then wedges the claim. Acked is what the server has
answered for, and it does not exist yet: a successful `.perWindowSize` reply
is an empty block the handler deliberately ignores
(`RemoteTmuxControlConnection+CommandResults.swift:333-337`). Reconcile adds
the acked recording on that reply. The diff dedups desired against sent,
classifies sent-but-not-acked as awaiting, and takes acked as the tmux-side
actual. The requested ledgers keep their reconnect role unchanged:
`reseedAfterReconnect` (`RemoteTmuxControlConnection+Commands.swift:219-235`)
replays `lastWindowSizes` and `lastClientSize` into the fresh ssh client
after clearing the sent and acked state.

The set's lifecycle is keyed to the stream. Entries are created on
send-success, resolved by their own reply or publication, and cleared
whenever the control stream resets: `spawnProcess`
(`RemoteTmuxControlConnection.swift:323-346`) empties the FIFO and fails
every pending tracked send (`failPendingTrackedSends`) on every reconnect,
since a reply owed by a dead stream will never dequeue. Every resolution
marks the owning mirror dirty.

User intents get one slot per (split, axis), latest wins. A drag-end
computes its grid-feasible span exactly as today (`requestedTmuxSpan`,
`clampToFeasibleFirstSpan`, and the nested-same-axis routing through
`resizeCommandTargetPaneID` all survive), records the intent, and marks
dirty; the commit sends it. A second drag ending before the first resolution
overwrites the slot; when the commit next runs, it sends the new span, and
the superseded entry's eventual resolution does nothing but mark dirty — its
expected outcome is no longer anyone's excuse for waiting.

The mirror's convergence never depends on a timer. That is the scope of the
claim, and it is deliberately not global. Two connection-level timers
stay, each with a stated reason. The 180ms claim debounce
(`clientSizeDebounceMs`) is a rate limiter whose own comment carries the
argument: the ledger is written synchronously before any deferral, dedup
makes a late or duplicate send idempotent, and reply-gated coalescing would
self-clock to the control channel's round trip and reinstate the SIGWINCH
storm it exists to prevent (`RemoteTmuxControlConnection.swift:173-190`).
The attach redraw kick's gap covers tmux's internal pane-resize coalescing,
which emits nothing observable when it expires, so no event-driven
substitute exists (`RemoteTmuxControlConnection.swift:197-207`). Both live
outside the pass, and neither decides when anything is settled.

## What each mechanism becomes

The named deletions, with what replaces each one.

- `imposedEpoch` (`vendor/bonsplit/.../Internal/Models/SplitState.swift:31`,
  bumped in `BonsplitController.setImposedFirstExtent` and read throughout
  `SplitContainerView.swift`). It exists to force one more apply when the
  imposed number is unchanged but the frames are not. The pass diffs desired
  extents against actual frames, so "same number, drifted divider" is just a
  nonzero diff. Deleted.
- `imposedRetryBudget` and `scheduleImposedRetry`/`retryImposedIfStillShort`
  (`SplitContainerView.swift`, Coordinator). They bound self-healing for an
  apply AppKit refused. With synchronous applies and the shared clamp, a
  refused exact target is a clamp-model bug the commit-time assertion
  catches, and the circuit breaker bounds the writes while it stands; drift
  otherwise gets one write per pass, and the chain ends when frames match
  because a matching diff emits nothing. Deleted.
- `renudgeImposedDescendants` (`SplitContainerView.swift:959`). It repairs
  children a late parent apply resized proportionally. Commits write the
  whole tree top-down from one snapshot, so within a pass a parent's apply
  cannot land after its children's — the ordering the renudge repairs cannot
  occur. Drift AppKit introduces after the pass (a window rescale) is caught
  by the next pass's whole-tree diff. The correction path is that re-diff,
  not callbacks from our own writes — those run under the programmatic-depth
  guard and are deliberately silent. Deleted.
- `lastImposedAvail`, `lastImposedOutcome`, `lastAppliedPosition` memo cases
  in `Coordinator.syncPosition` and the re-arm in
  `splitViewDidResizeSubviews`. They distinguish "container resized" from
  "divider nudged" to choose synchronous versus deferred re-apply, because
  applies could run inside the layout pass that moved the frames. Reconcile
  never writes from inside a layout callback at all — every write is in
  commit — so the distinction has nothing left to decide. Deleted.
- The `isExternalUpdateInProgress` suppression window. Every `fromExternal`
  write arms a 50ms timer (`BonsplitController.swift:1024-1042` and
  `1080-1099`) during which geometry notifications are swallowed (the
  `force` gate at line 1138). It is a timer inside the one primitive the
  design keeps, and it eats exactly the post-commit drift notification the
  model relies on as a dirty edge. Echo suppression is no longer needed:
  notification handlers only mark dirty, and an echo pass is a no-op diff.
  Deleted with the synchronous-apply contract change.
- `pendingOversizedReading` and its one-shot re-judgment
  (`RemoteTmuxWindowMirror.swift:142`, consumed in `performSizingPassNow`).
  It parks a reading whose validating bound was sampled at a different, torn
  instant. The pass samples frame and bound together, so there is no appeal
  process — but the *verdict* survives as the snapshot validity predicate
  and the last-valid-container fact, because content-ideal poison is
  persistent and must still be dropped, never clamped, and the probe's new
  move-to-window and frame dirty edges supply the retry the parking
  supplied. What gets deleted: the parking, the single re-judgment, and
  their special case for passes that arrive without a bound.
- `pendingContainerSizePt`/`pendingContainerScale`
  (`RemoteTmuxWindowMirror.swift:132`). Subsumed by the same predicate: a
  sample with no bound to validate it simply does not update the last valid
  container, and the pass a probe edge wakes reads the frame directly. The
  one-time display-ceiling fallback for a never-hosted mirror's initial
  claim survives inside the desired-claim function. Deleted.
- `dividerResizeInFlight`, `resolveDividerResizeHold`,
  `recordDividerResizeAwaitingReply`, and `dividerResizeReplyGrace`
  (`RemoteTmuxWindowMirror.swift:170-206`,
  `RemoteTmuxWindowMirror+Bonsplit.swift:175`). Replaced by the in-flight
  send set: a tracked command token plus the post-ack publication phase. The
  hold's identity becomes the send itself, so an unrelated layout can
  neither release it nor prolong it, and no grace timer is needed. Deleted
  in migration step two, together with the mechanisms it pairs with (see
  the ordering rule there).
- The output-parity apparatus: `rearmIfOutputMissedPlan`,
  `scheduleOutputParityCheck`, `outputParityMismatch`,
  `outputParityRearmsSpent`, `outputParityRearmInputs`, and
  `lastPlannedOuterSizes` as a stored plan
  (`RemoteTmuxWindowMirror+SizingTransaction.swift:335-402`). Output parity
  *is* the pass's diff; it cannot be skipped by an input memo because there
  is no input memo, and its cap survives only as the unified circuit
  breaker. The planned outers stop being retained state — they are
  recomputed each pass. Deleted. (The DEBUG chrome-parity probe in
  `handleSizingSample` stays; it checks the model against paint, which
  reconciliation does not subsume.)
- `SizingInputs`, `lastCompletedSizingInputs`, `pendingSizingPassIntent`, and
  `setNeedsSizingPassIgnoringInputs`
  (`RemoteTmuxWindowMirror.swift:248-272`). The settled check compares
  actual to desired, not inputs to remembered inputs, so there is no memo to
  bypass and no `.constraintRecovery` intent to thread through. Deleted.
- The two-turn restate (`performSizingPassNow` lines 299-306, the nested
  `DispatchQueue.main.async` pair after a render-frame change) and the
  two-turn parity scheduling. Turn-counting encodes "after AppKit settles"
  as time-shaped knowledge. The rescale's own callbacks mark dirty; the next
  pass reads whatever actually happened. Deleted.
- `lastDividerPositions` baselines and everything that services them:
  `pruneDividerBaselines`, the nil-parking in `applyDividerPositions`, the
  drag-begin reseeding in `seedMissingDividerBaselines`, the
  `sendWithoutBaseline` belt, the imposed-echo filter in
  `syncChangedDividerPositions`, and the non-drag divider sync in
  `splitTabBar(_:didChangeGeometry:)`
  (`RemoteTmuxWindowMirror+DividerSizing.swift`,
  `RemoteTmuxWindowMirror+Bonsplit.swift:593` and `:617`). Baselines exist
  so a geometry callback can guess whether a fraction change was the user or
  our own echo. Under reconcile, geometry callbacks never send to tmux; the
  only divider-to-cells conversion happens at drag end, where the fraction
  is the user's by definition and the cells-versus-assigned comparison is
  the no-op filter. With no mid-stream sender there is nothing to baseline.
  Deleted in step two, in the same step as their replacement.
- Drag sessions stay. The deterministic begin/end from the mouse-tracking
  lifecycle is real user ownership, not a compensating mechanism, and the
  render-ownership rule from the current design doc — mid-drag, the user
  owns the split — carries over as the user-owned classification in the
  diff. The mirror takes its drag edges from the internal controller's
  zero-crossing (`noteDividerDragSession` in
  `vendor/bonsplit/.../Internal/Controllers/SplitViewController.swift:80-101`),
  which is the ownership truth the delegate callback is derived from; the
  `activeDividerDragSessions` counter gets a DEBUG assertion and a clamp on
  tree rebuild so a torn-down split cannot strand ownership. Bonsplit's
  tree-wide mid-drag apply refusal (the `isTreeDragSessionActive` gate in
  `syncPosition`) also stays, as the last-line guard for a commit racing a
  just-started gesture — a refused write there heals at the drag-end pass.
- The ack barrier stays, and the in-flight set is built directly on it:
  `sendTracked` and the FIFO correlation in `handleCommandResult` are the
  protocol truth, not something to duplicate beside. The layout-publication
  quarantine stays as the second phase of resolution. The connection's rate
  limiters stay, scoped as above.
- The feed-forward claim (`updateClientSize`, `clientGrid`), the per-window
  pin and session-max bookkeeping
  (`RemoteTmuxControlConnection+Sizing.swift`), the requested/sent/acked
  claim ledgers and the reconnect reseed built on the requested one, the
  exact-fit render frame, the planner, the calibration folds, and the
  chrome-parity single source all stay. They are the transform; this
  document only changes what executes it.

## The ledger, replayed

Each of the day's twelve bugs, and the specific property that makes it
impossible rather than merely fixed.

1. A divider parked off-target with no re-arm (the `availUnchanged` memo
   family in `Coordinator.syncPosition`: outcome recorded, budget spent,
   target unreached, nothing left to fire). Impossible because there are no
   memos and no budgets: an off-target frame is a nonzero diff, and a
   nonzero diff on a non-awaiting, non-user-owned split emits a write on
   every pass. The only ways to stop being corrected are to match, or to
   trip the circuit breaker — which is loud, counted, and reset by the
   constraint edges, never silent.
2. A same-extent imposition deduped while the divider drifted (the epoch was
   the patch; dedup keyed on the imposed number). Impossible because the
   diff never consults the history of what was written — it compares desired
   against the frame the view holds now. An unchanged desired number over a
   drifted actual is exactly a diff.
3. A container reading dropped against a torn transient bound with no retry
   edge (the oversized-drop path in `noteContainerSize`, patched by
   parking). Impossible because the pass has no delivered reading to judge:
   it samples the probe frame and the window bound in the same instant, an
   invalid pair leaves the last valid container in place, and the probe's
   own move-to-window and frame edges — plus whatever settles the window —
   re-mark. A torn window yields at worst a transient snapshot whose writes
   the next pass corrects.
4. The parity re-arm replaying a stale plan during a tmux round trip (the
   drag-end bounce). Impossible because desired is recomputed every pass and
   the dragged split is classified awaiting while its send is unresolved —
   the pass does not enforce a plan there, and by the time it does, the plan
   is derived from the post-publication layout.
5. A 2-second no-reply timer misfiring under load. Impossible because no
   convergence timer exists. The round-trip window closes on the command's
   own resolution and the quarantined publication that follows it — ordered
   protocol output that cannot arrive early, late, or twice relative to the
   truth it announces; the rate limiters that remain only pace sends.
6. The hold released by an unrelated layout change (today's
   `resolveDividerResizeHold` judges by whether some layout assigns the sent
   span). Impossible because the in-flight entry is keyed to the tracked
   send itself and resolved by its own reply plus its own window's
   publication state; no layout shape, related or not, is consulted.
7. The portal following the layout engine's unsatisfiable solution instead
   of actual frames (fixed at head by `ad4e3e5c0f`;
   `synchronizeHostFrameToReference` now copies the reference's bounds). The
   model makes the fix a rule: actual is defined as view frames, and engine
   solutions are not an input the diff is allowed to read. There is no code
   position left for the bug to occupy.
8. Hidden tabs alive at SwiftUI opacity 0 intercepting hit tests and
   painting dividers (fixed at head by `12a5a2bc67`;
   `bonsplitController.isInteractive` in
   `RemoteTmuxWindowMirrorSplitView.swift` follows the visibility edge). The
   hidden bit becomes part of desired state, diffed like a frame: a revealed
   tree that is still hidden, or a hidden tree still interactive, is a
   mismatch the next pass corrects, so the property cannot silently rot on a
   missed edge.
9. A drag baseline niled awaiting a structurally impossible callback (the
   imposition parks `lastDividerPositions[splitId] = nil` for a post-layout
   callback the programmatic-sync guard eats; `seedMissingDividerBaselines`
   at drag begin was the patch). Impossible because baselines are deleted:
   no state waits on that callback, and drag-end sends need no pre-drag
   fraction.
10. A deferred portal hop dropped when requests fold
    (`pendingExternalGeometrySyncHasDeferredRequest` in
    `TerminalWindowPortal.swift` was the patch). The general form is the
    generation rule: folding requests is folding marks, which loses nothing,
    because a mark during the pass moves the generation and guarantees the
    follow-up. Any pass that ran too early is followed by one that did not.
11. Claims derived from rendered content feeding back (the growth spiral:
    the split tree's imposed width leaking into the container reading,
    walled off today by the overlay split in
    `RemoteTmuxWindowMirrorSplitView`). The model adds two guarantees on
    top of the existing feed-forward rule. Measured-from-screen geometry is
    only ever used to describe what IS, never to decide what SHOULD BE
    (the calibration constants are the one exception, and the section
    above says why they are safe). And what should be can never exceed the
    measured region — plan(w) ≤ w, checked by an assertion — so even a bad
    input cannot become an oversized plan.
12. Work amplifying under load (callbacks de-coalescing into per-event
    passes). Impossible by the coalescing invariant: events mark, marks fold
    into at most one scheduled pass, and the pass's cost is a function of
    tree size, not event count. N events between passes cost exactly one
    pass, and the DEBUG counter below makes any regression loud.

## Edge cases

Each scenario states what the pass does and why the sequence terminates.

- A window torn mid-resize: the probe frame already shows the post-resize
  slot while the window still reports its old frame. The snapshot is
  internally consistent (both read now); if the frame exceeds the transient
  bound the validity predicate holds the last valid container, and if it
  fits, desired is computed against the transient bound and may be
  transiently small. Either way the window's settle raises frame callbacks,
  the mark lands, and the next pass computes against the settled bound.
  Terminates because AppKit resizes finitely and the last pass's diff is
  zero. The transient render is the settled-property relaxation the current
  design doc already grants.
- A user drag begins mid-pass: drag begin and the pass both run on the main
  actor, so they cannot interleave within one drain; the earliest a drag can
  start is after commit. Passes do keep running mid-drag — the main queue
  does not pause for gestures — and that is fine. The dragged split is
  user-owned in the diff. Bonsplit's tree-wide refusal backstops any write
  that races the gesture's first frames. The zero-crossing at session end
  marks dirty, so both the refusal and the deferral heal at the drag-end
  pass. Terminates at drag end plus one pass.
- Local desired changes during a tmux round trip: the user drags (send in
  flight), then the window resizes so the claim changes. The pass sends the
  new claim — the claim is not the dragged split's state and is not blocked
  by it. Both commands resolve in FIFO order, each resolution marks dirty,
  and the final pass diffs against the final published layout. Terminates
  because each send is deduped or superseded, so the FIFO drains.
- Two rapid drags where the second invalidates the first's in-flight send:
  the intent slot for that split is overwritten before the commit sends
  again; the first send's resolution is a no-op beyond marking dirty. tmux
  applies the commands in order, so the last-sent span is the one the final
  layout assigns. Terminates when that layout's publication pass finds the
  assignment matching the user's position.
- A hidden tree revealed: SwiftUI may have recreated every view while the
  tab was hidden, so nothing holds the old plan. Reveal marks dirty; the
  pass samples the fresh views (all far from desired) and commits the full
  plan in one write set. No `IgnoringInputs` escape hatch is needed because
  no memo could have concluded "settled" in the first place. Terminates on
  the follow-up pass whose diff is empty.
- A no-op drag: the released fraction rounds to the span tmux already
  assigns. No intent is recorded (cells equal assigned — the same filter as
  today), but the views hold an off-grid fraction, so the same pass sees
  plain drift and re-imposes immediately. Today this is a special-cased
  branch in `splitTabBarDividerDragDidEnd`; here it falls out of the diff.
- Reconnect with stale desired: the stream reset in `spawnProcess` fails
  every pending tracked send and clears the in-flight set, and
  `reseedAfterReconnect` clears the sent and acked ledgers — while the
  requested ledgers (`lastWindowSizes`, `lastClientSize`) survive on
  purpose, because the reseed replays them into the fresh ssh client. The
  next pass snapshots the *refetched* layout (invariant 5 of the current
  doc: trust the snapshot, not the event stream) and recomputes desired from
  scratch — desired is never persisted, so there is nothing stale to flush —
  and the empty acked ledger makes every claim a nonzero diff, so claims
  re-send. Terminates like any cold attach.
- Multiple windows: one generation and one pass per mirror, each
  snapshotting only its own world. While per-window sizing is live, the only
  shared sizing state is the session-wide client-size envelope, which the
  connection owns and dedups (`setWindowSize` maintains the running max), so
  N windows are N separate fixed points. The exception is the session-wide
  fallback: when a server rejects the per-window form
  (`supportsPerWindowSize` flips off and claims route through
  `setClientSize`, `RemoteTmuxControlConnection+Sizing.swift:72-106`), the
  server holds one size for the whole session and per-window dedup is
  explicitly disabled (the comment at lines 147-151 says exactly why), so
  every window couples through that one value. There, convergence is
  per-connection, not per-window — the shared size is a shared fact in each
  mirror's diff, and smallest-wins semantics come from the claim function,
  not from independence.
- AppKit proportional drift between passes: a window rescale moves dividers
  off their imposed extents after the commit that placed them. The moved
  frames raise callbacks (no suppression window remains to eat them), the
  mark lands, and the next pass rewrites the drifted splits — top-down, all
  of them, from one snapshot. This single behavior replaces both the
  descendant renudge and the two-turn restate. Terminates because the
  rescale is finite and rewriting does not resize the container.
- Infeasible desired: tmux assigns a 1-column pane the platform floor
  refuses, or the exact-fit tree exceeds the container. Desired is computed
  through the exported bonsplit clamp and the region clamp (plan(w) ≤ w),
  so the pass converges to the best feasible geometry and stops. The
  clamp-equality assertion keeps "feasible for us" and "feasible for
  AppKit" the same set. If they ever diverge anyway, the circuit breaker
  bounds the writes (the 32pt floor is the measured precedent for exactly
  that divergence). The residual disagreement with tmux's assignment is
  reported by the existing grid-mismatch DEBUG probe, not fought.
- An observation arrives during commit: a commit write runs synchronous
  layout, whose callbacks fire mid-commit. Handlers only mark and return;
  the pass finishes committing from its snapshot, and because the pass
  claimed its generation at entry, the mid-commit mark moves the generation
  and buys exactly one follow-up pass. Re-entry is structurally impossible —
  the pass runs from its own drain, handlers cannot call it, and a DEBUG
  assertion (below) enforces that no write primitive runs from an
  observation context.
- A calibration sample lands mid-pass: the fold updates its minimum and
  marks; the running pass keeps its snapshot's copied constants, so one pass
  never mixes two calibrations. The follow-up pass uses the tighter
  constant. Terminates because the fold is a monotone integer minimum
  bounded below — it can only change finitely many times.
- Load smears callbacks across turns: however the runloop batches or delays
  event delivery, each handler is a mark, the drain runs one pass per
  generation change, and pass cost is O(tree). Work per real state change is
  constant; there is nothing to de-coalesce. The counters below make this
  checkable: a DEBUG run that violates it fails.

## Testing each layer

The pass structure makes each layer testable on its own, and the layers
where the code meets AppKit, bonsplit, ghostty, and tmux stay covered by
tests against the real thing. The split is not "unit tests instead of
integration tests." It is: stress the algorithm where stress is cheap, and
pin every real-world behavior the algorithm relies on where only the real
dependency can answer.

```
   layer                        runs against          what it proves
   -----                        ------------          --------------
   1  desired function          nothing (pure)        plan(w) <= w, clamp
                                                      equality, determinism
   2  reconcile loop (small)    scripted ports        loop skeleton only:
      (snapshot->diff->commit)                        convergence, bounded
                                                      passes
   3  dependency assumptions    real AppKit, real     THE WEIGHT GOES HERE:
                                bonsplit, real        the components handle
                                ghostty               our instructions and
                                                      layout as modeled
   4  protocol layer            real tmux, no app     FIFO, acks, barrier,
                                                      claim semantics
   5  the whole app             everything real       the fuzz marathon
```

Layer 1 is free to stress. The desired function is a pure function of the
snapshot, so a property harness can throw millions of generated snapshots
at it — arbitrary trees, container sizes, calibration constants, drag
states — and check the invariants on every one: output never exceeds the
measured region, the clamp is idempotent, the same snapshot always produces
the same plan.

Layer 2 is deliberately small. It checks the loop's skeleton — events
stopped implies convergence in bounded passes, one pass per generation
change, zero writes after convergence — by driving the pass through ports
(a world source, a view writer, a command transport) with scripted replies
and marks, turn-based and seeded so a failing interleaving replays exactly.
That is worth having because it is nearly free once the ports exist. It is
not where the weight goes, and the bug ledger says why: not one of the
day's bugs was the algorithm mis-stepping on its own state. Every one was a
divergence between our model of the world and what a downstream component
actually did — AppKit refused an apply we assumed would land, the layout
engine stomped a frame we assumed was ours, ghostty's draw blocked on a
transaction we assumed was closed, tmux clamped a claim we assumed it would
grant. A simulator encodes our model, so it inherits exactly those blind
spots. It can regress the loop; it cannot discover where the model is
wrong.

Layer 3 is where the weight goes, for that reason. The real components —
AppKit, SwiftUI, bonsplit, ghostty — stay in play, we drive them with the
same instructions the commit phase emits, and we assert they handled them
the way the model says: the exported clamp equals what bonsplit's
coordinator actually applies to a real NSSplitView; a synchronous
imposition lands and the frame read back matches; a portal write to a real
window sticks; a ghostty surface accepts a size push and schedules its own
repaint; no path displays a surface synchronously from inside a layout
pass (the layout-pass refresh tests). The dependency harness already
started this (the bonsplit clamp test, the ghostty floor, the measured
tmux facts); under reconcile every assumption the model makes gets a
real-dependency test by name. When one of these tests discovers a new
behavior — the 32pt floor was found exactly this way — the model is
corrected first, and layer 2 just replays against the corrected model.

Layer 4 drives the protocol layer against a real tmux server with no app
attached: FIFO correlation, ack barriers, per-window claim semantics,
refusal shapes. Layer 5 stays what it is today — the live fuzz marathon and
the render harness, judging rendered outcomes at rest.

## What the concurrency audit found

After the fuzz run wedged the app twice in one day, we audited the whole
mirror stack for deadlock risk: every lock, every synchronous wait on the
main thread, and the connection pipeline end to end.

The first result is an absence. The mirror stack has no explicit locks.
Everything is main-actor confined, and the pipe I/O on both sides is
bounded: the writer rejects instead of blocking, the reader tears the
connection down instead of buffering forever. So the dangerous resource
here is never a mutex. It is the open window transaction during a layout
pass, and the main thread itself.

Two rules fall out of the bugs we hit, and both are now pinned by tests.

First: never display a terminal surface synchronously from inside a layout
pass. `displayIfNeeded` on a Metal-backed surface reaches ghostty's
`drawFrame`, which waits for the GPU frame to complete. That frame presents
through the window transaction that the layout pass is still holding open.
The wait can never finish, and the main thread wedges for good. We hit this
four times: the portal's frame-change refresh (the fuzz hang), its twin on
the divider-drag path, the reveal nudge in `setVisibleInUI`, and a
whole-window `displayIfNeeded` in the browser panel that flushed sibling
terminal panes. All four are fixed the same way — the redraw waits for the
next main-queue turn. That is an event edge, not a timer.

Second: the main thread is one shared resource, and every subsystem in
this stack serializes through it. The control-stream ingest, the render
path, layout publication, and the RPC socket all contend for it. Three of
the day's bugs came down to exactly this.

```
   control-stream     render path      layout           RPC socket
   ingest (parse +    (draws, portal   publication      (main.sync
   handle, in         syncs)           (rects replies   per verb)
   stream order)                        -> windowsByID)
        |                 |                 |                |
        v                 v                 v                v
   +--------------------------------------------------------------+
   |                       the main thread                        |
   +--------------------------------------------------------------+

   wedge it   (a GPU wait inside a layout pass)  -> all four stop
   saturate it (an %output flood)                -> replies queue
                                                    behind redraws
```

The largest confirmed finding is architectural. The entire tmux stdout
pipeline — parsing and handling — runs on the main actor, in strict stream
order (`RemoteTmuxControlConnection.swift:421-428`). Every `%output` line
pushes bytes through ghostty synchronously. Every topology event rebuilds
the workspace inline. A command reply cannot be parsed until everything
ahead of it has been handled. Under churn this feeds itself: handling
generates more main-thread work, which delays the next chunk, which delays
the reply that would let sizing settle. This is what inflated control
round trips from 0.2s to 13s in the fuzz logs and starved layout
publication. The fix is to parse off the main actor, deliver batched
messages, coalesce `%output` per pane per batch, and coalesce topology
notifies to one per drain. That work is step zero of the migration below.
It ships on its own and touches transport, not sizing mechanisms, so it
does not disturb the three-step ordering rule.

The audit also found a fragile tier: paths that are safe today only
because of a convention nothing enforces. Each has a fix direction and
none blocks the current branch.

- `ghostty_surface_free` runs on main and joins ghostty's IO threads
  (`TerminalSurface+RuntimeLifecycle.swift:286`). Ghostty action callbacks
  from those threads hop to main with `DispatchQueue.main.sync`
  (`GhosttyTerminalView.swift:2483-2490`). If a free and a callback ever
  overlap, both sides wait forever. Safe today only because ghostty
  happens to deliver actions on main. Fix: make the off-main action branch
  async, or fence frees against in-flight callbacks.
- When main wedges, every RPC socket connection parks its thread in an
  untimed `DispatchQueue.main.sync` (`TerminalController.swift:3279`).
  No cycle, but the app fails slow — silence instead of an error — and new
  connections keep spawning parked threads. Fix: a bounded wait that
  returns a busy error.
- `beginReconnecting` fails pending tracked sends before it marks the
  connection down (`RemoteTmuxControlConnection.swift:636-652`). A
  completion that re-enters `send` passes the connected check and gets a
  false success into a dying pipe. `sendTracked` also registers its token
  before sending, so a rejected write can both invoke the completion and
  return false — a double edge the call sites survive only because they
  are idempotent. Fix: mark the connection down first, and register the
  token only after the send succeeds.
- The pipe writer's byte accounting drains through main-queue hops
  (`RemoteTmuxControlPipeWriter.swift:45-57`). A saturated main can make a
  healthy pipe look full and force a reconnect that reports backpressure
  the pipe never had. Fix: keep the counter on the writer's own queue.
- The ssh process runner waits on reader EOF with no timeout
  (`RemoteSessionProcessRunner.swift:138`). Safe only because every caller
  pins `ControlMaster=no`; a forked child that holds the pipe would wedge
  the coordinator queue permanently. Fix: derive a timeout from the
  request budget.
- The socket-worker auth verbs wait on untimed semaphores
  (`TerminalController.swift:1256`). A stuck MainActor task parks the
  worker forever. Fix: add timeouts.
- `Workspace` exposes blocking PTY calls to main-actor code with no guard
  and no callers (`Workspace.swift:5142-5188`). The first future caller
  buys a beachball. Fix: assert off-main in `runOnControllerQueue`, or
  delete the unused wrappers.

## The second geometry writer: autoresizing masks

The worst render bug the fuzz found was a frame ping-pong: every pane sat
exactly one host-width-delta wide of plan, the portal rewrote it each
pass, and something restored the wrong size within milliseconds —
hierarchy syncs in the thousands per settle window against a healthy ~17.
Three fix attempts failed before live forensics named the writer, so the
mechanism is worth pinning here.

Hosted terminal views reach the portal from SwiftUI hosting with
`autoresizingMask = [.width, .height]`. In an Auto Layout window that
mask does not stay a mask: AppKit translates it into constraints, and a
flexible mask translates into EDGE pins — a minX constant plus a trailing
margin to the host, with no width constraint at all. The pin distances
are snapshots of whatever geometry the last constraint pass saw.

```
   portal's theory                    engine's theory (flexible mask)

   "this pane IS                      "this pane's left edge is at 992
    215 x 141 at (992, 16)"            and its right edge is 7pt from
                                       the host's right edge"

                    host resizes by +148
                          |
                          v
   portal: pane is still 215 wide     engine: margins are fixed, so the
   (the anchor didn't move)           pane is now 215 + 148 = 363 wide
```

Both writers act on every display refresh. The portal writes plan truth;
the next layout flush lets the engine re-derive the pane from its frozen
margins against the new host bounds and write that back. Neither side
ever sees the other's reasoning, so the fight never converges — panes
render at a previous generation's geometry while the sync counters burn.

The rule: the portal is the only writer of hosted geometry, so adoption
clears the mask, every sync re-asserts it, and detach restores the
original. An empty mask translates to rigid position+size constants that
always equal the last portal write — the engine's opinion of a pane
becomes, by construction, whatever the portal last wrote. There is no
second theory of geometry left, rather than a suppressed one.

Two dead ends worth remembering. Fighting the engine at the frame setter
does not work in either direction: refusing its writes (returning without
`super`) desyncs AppKit's bookkeeping from the actual frame and NSWindow
eventually raises its per-cycle update-constraints budget exception; and
redirecting through `super` at the current frame is the same thing in
disguise, because an equal-value `super` call early-returns and the
engine still sees its apply not take. The fix has to remove the engine's
wrong opinion at its source, not veto the write.

Why every test missed it: views created directly in a test are born with
an empty mask, so the fixtures were accidentally running the fixed
configuration — three successive attempts at a red test came back green.
The disease only exists with the production mask, and once the fixture
sets it explicitly the failure is deterministic arithmetic (grow the
window 120pt, watch a 240pt pane become exactly 360). The regression test
does exactly that. The forensics practice that broke the case is also
kept: when a frame oscillates and one writer is unknown, the portal dumps
`constraintsAffectingLayout(for:)` and the translated constants at the
moment of the miss (`portal.stomp.diag`, rate-limited, DEBUG) — one
capture named what three rounds of inference got wrong.

## Migration

Three steps, each shippable, under one ordering rule: no step deletes a
mechanism whose replacement ships in a later step. The fuzz and UI harnesses
(`scripts/remote-tmux-live-fuzz.sh`, `scripts/remote-tmux-fuzz-marathon.sh`,
`scripts/remote-tmux-render-harness.sh`) and the socket introspection
(`remote.tmux.pane_grids` via `RemoteTmuxWindowMirrorSizingSnapshot`) judge
rendered outcomes at rest — assigned versus rendered grids, settle within
budget — and never reference the mechanisms being deleted, so they survive
all three steps unchanged and arbitrate each one.

The first step rebuilds the view side. `performSizingPassNow` becomes
`reconcileSizing()` — snapshot, compute, diff, commit, with generations, the
validity predicate, the probe dirty edges, the circuit breaker, and the
invariant assertions. It deletes only what the pass itself replaces in the
same step: the input memo, the parity apparatus, the parked readings, and
the two-turn restate. It carries the minimal bonsplit contract change — the
synchronous external apply, the exported clamp function, and the deletion of
the 50ms `isExternalUpdateInProgress` suppression window — because without
those the pass can neither observe an apply's outcome in the turn it commits
nor trust that post-commit drift raises a dirty edge. The divider baselines,
the old drag-end sync (`syncChangedDividerPositions(sendWithoutBaseline:)`),
and the `dividerResizeInFlight` hold with its grace timer all survive this
step untouched, and the pass consults the hold as its awaiting source: their
replacement is the protocol layer, and the ordering rule says they die with
it, not before it.

The second step is that protocol layer. `resize-pane` becomes a tracked
send; the acked claim recording lands on the `.perWindowSize` reply; the
in-flight set with its two-phase resolution replaces the hold and its grace
timer; drag-end records an intent the commit sends, with supersession
replacing replay — and the baselines, the old drag sync paths (drag-end and
the non-drag `didChangeGeometry` sync), and the hold are deleted here, in
the same step as their replacement. The no-reply heal test is rewritten to
drive the protocol edges (an error reply, a proven no-op after ack, a stream
reset) instead of a clock, which it should have been doing anyway.

The third step deletes bonsplit's remaining compensations: `imposedEpoch`,
`imposedRetryBudget` and the retry chain, `renudgeImposedDescendants`,
`lastImposedAvail`, and the resize-callback re-arms. What remains of the
imposed path is one clamped, synchronous `setPosition` per external
instruction, the mid-drag refusal, and outcome reporting. This goes last
because until the host reconciles, those mechanisms are the only healing
bonsplit gets; after steps one and two they are dead weight whose removal
the fuzz marathon can judge in isolation.

Regressions get loud through invariant counters, extending
`RemoteTmuxSizingDiagnostics` (`Sources/TerminalWindowPortal.swift:22`).
Passes per generation change must be exactly one; more means passes are
multiplying instead of coalescing. Writes per pass are bounded by tree
size, and must be zero on the pass after a converged one — a second
consecutive pass over an unchanged world that writes anything is a feedback
loop, caught early. Sends per pass are bounded by the intent slots plus one
claim. Circuit-breaker trips should be zero; any trip names a clamp-model
divergence. And writes from observation contexts must be zero, enforced by
a DEBUG assertion in the write primitives against an in-observation depth
counter — the same shape as the existing
`splitContainerProgrammaticSyncDepth`. Two more assertions enforce what the
model section promised: the clamp-equality check after every commit apply,
and the plan(w) ≤ w bound on the desired function's output. A unit test pins the generation semantics — a mark during commit
buys exactly one follow-up pass. The settle-latency budget in the harnesses
stays tight; a slow settle under this model is a missing dirty edge, which
is a bug, not a tuning problem.

## Out of scope

The single-pane path (a tmux window rendered without a mirror) keeps its
current window-bounded claim; it has no split tree, no impositions, and no
round-trip holds, so it has none of the problems this redesign fixes. The
portal's already-conformant pieces stay as they are: its fingerprint-guarded
no-op sync (`synchronizeLayoutHierarchy`) is actual-state diffing, and its
host frame already follows the reference's real bounds — the reconciliation
pass drives it through the same registry entry point as today. The authority
mechanism, the measured tmux 3.7 facts, the chrome-parity model, and the
calibration approach are specified in `docs/remote-tmux-sizing-design.md`
and are unchanged; this document is the execution model for that spec, not a
revision of it.

Two independent adversarial reviews were folded into this document; where a
review disagreed with the draft the code decided, and where a claim could
not be settled by reading, it is pinned above as a test or an assertion.
