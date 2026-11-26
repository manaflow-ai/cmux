# Remote-tmux mirror sizing

## What we're doing

Sizing is a one-way pure transform. Data flows in one direction from an input
that does not depend on anything we render:

```
window content area  →  claim to tmux  →  tmux assigns cell rects  →  pane point rects  →  set pane frames
```

- **Claim (app → tmux):** `available = windowContentArea − chrome`,
  `(cols,rows) = floor(available / cell)`. Input is window geometry and fixed
  chrome constants only — never a measured pane container.
- **Authority:** tmux owns the grid. We render exactly the cell rects it assigns.
- **Render (tmux → app):** bonsplit draws the panes, dividers, per-pane tab
  bars, and drag — we do not draw or reimplement any chrome. We compute each
  split's first-child extent in points from the tmux-assigned cells and impose
  it on bonsplit; bonsplit lays out and paints. Placement is our computed
  extent, applied by bonsplit.
- **Authority mechanism: per-window `refresh-client -C '@id:WxH'` pins**, with
  the session-wide client size held at the max of live window claims so each
  pin is honored. The pin is a *ceiling*: tmux sizes a window to the per-axis
  minimum across all clients viewing it (measured on tmux 3.7), so a smaller
  co-viewer clamps the window down and the larger one shows a border — never a
  wrap. Only the visible window claims; hidden tabs are sized when shown.
- **User drag** stays bonsplit's native divider drag; on drag-end the resulting
  extent is converted to cells and sent to tmux (`resize-pane`), and tmux's next
  layout becomes the settled truth.

The rule that makes it sound: nothing downstream of rendering (a measured
container, a laid-out frame, a surface's reported size) ever feeds the claim.
With that, the claim is a pure function of window geometry, so it cannot grow or
oscillate; it settles by construction.

Invariants:
1. The claim reads only window geometry, chrome constants, and cell metrics.
2. Every view is space-filling (answers a proposal with the proposal; hosting
   controllers publish no intrinsic size) so content exerts no outward pressure.
3. tmux is the only grid authority.
4. A size is sent only when it differs from what the server was last sent.
5. Across a transport gap, trust a refetched snapshot, not the event stream.

## Correctness is a settled property, not a per-frame one

Exactness is required only at rest. While the user is dragging a divider, or a
window is resizing, or a reconnect is in flight, the panes may wrap or show gaps,
because tmux has not yet been told the final size and rendered its authoritative
layout. That transient is fine and expected: the user is mid-gesture and does not
read a pane that is actively moving. The guarantee is that once the interaction
ends and tmux assigns the final grid, every pane renders exactly its assigned
span.

This relaxation is load-bearing for the whole design. It means the render side
never has to keep pane geometry perfect on every frame of a drag, so there is no
need to apply sizing synchronously or race the layout to stay pixel-exact mid
gesture — the attempts to do that are what caused the beach-ball. During a drag
we can let the divider move freely (or render tmux's last layout scaled), tell
tmux the target as it changes, and only the settled frame after drag-end must be
exact. It also fixes what the gate judges: it measures at rest, never mid
transition, so a mid-drag wrap is not a failure and a persistent wrap at rest is.

## Fresh-connect wedge: a pre-window reading must not stick

At fresh connect the mirror's container can get a geometry callback before its
window is laid out — SwiftUI proposes a size (historically the full display
width) while the window is still ordering in. This is not content pressure
(invariant #2 rules that out); it is a startup-ordering transient. The danger is
banking that pre-window size as the claim input when no later callback fires, so
the claim stays wrong and tmux — sized to the real, smaller window — never
matches: a wedge.

The design handles it with no feedback, purely from the reading and the window
bound:

- With a visible hosting window present, clamp the reading to its content rect —
  the authoritative bound.
- With no visible window yet but a size already on record, defer: ignore the
  unvalidated reading and wait for one taken against a real window, rather than
  overwriting a good size with a pre-window guess.
- Only the first reading with no window falls back to a display-sized ceiling, so
  an attach that never yet had a window still gets an initial claim.
- The sizing pass re-clamps the stored size against the live window before it
  reads, so a size banked slightly early heals on the next pass.

This is a settled-state guarantee: the transient may be briefly wrong but cannot
stick, and the claim converges to the window size. The decision is a pure
function of the reading, the current size, the window bound, the display bound,
and visibility — no measured feedback — so it is unit-tested directly rather than
left to the live view.

Deferring is only safe when a retry edge exists. A reading and its validator
must be sampled at the same instant: the geometry callback delivers a size at
one moment, and the window that could vouch for it may not exist until a
moment later. If the mirror drops the reading and nothing re-runs the check,
the bank rots — the mirror keeps rendering a stale-wide tree in a fraction of
its region with every claim looking sane, because the region never changes
size again and no further callback ever comes. Two things close that hole:

- A reading deferred for lack of a window is held, not dropped, and stashing
  it schedules the pass that re-validates it once a window exists. A reading
  a live window's bound rejects is usually content-derived and carries no
  truth about the slot — but the verdict can be wrong the other way: during
  an AppKit window resize, the callback can deliver the correct post-resize
  slot size while the window still reports its transient old frame. The
  reading is truth, the bound is noise, and no further callback comes once
  the region holds its final size. So a dropped reading is re-judged once
  against the next settled bound: banked verbatim if it now fits, discarded
  for good if it still exceeds it. Truth delivered during a torn window
  state must not be discarded on the noise's verdict. It is never clamped —
  clamping a genuinely oversized reading would bank the bound itself, the
  poison the drop exists to prevent.
- The pass resolves its window bound through the probe view planted in the
  mirror's own subtree, which survives the portal churn that can blank every
  pane view exactly when a bound is needed most. The full-chain regression
  test (bank wide, mount narrow, heal) holds with these two alone; stronger
  liveness edges (a pass on the probe's own move-to-window, same-instant
  frame sampling) were tried and proved unnecessary on this architecture.

## One tmux window shown in more than one place: clamp to the smallest

A tmux window can be displayed at two different sizes at once — most obviously
when the same window is mirrored in two macOS windows (drag a tab across
windows), and in principle by any co-attached client. `resize-window` under
`window-size manual` is client-independent (verified on tmux 3.7: it holds its
size and ignores a smaller co-attached client), so tmux will not pick a size
that fits every viewer for us. We choose it: size each tmux window to the
**per-axis minimum claimed grid across every view currently mirroring it**, and
recompute whenever a view appears, resizes, or closes.

Smallest-wins is the correct direction because the design tolerates gaps but
never wrap. At the minimum size the smallest viewer renders exactly, and every
larger viewer shows a little blank margin — a gap, which is fine. Sizing to the
largest would invert this and make the smaller viewer wrap, the one failure the
whole design exists to remove.

Within cmux this needs no special handling: there is exactly one window mirror
per tmux window id (`windowMirrorByWindowId`), so the same tmux window is never
displayed in two cmux OS windows at once, and macOS tabs within one window share
that window's content area (hidden tabs included). The multi-viewer case is
therefore only a co-attached *external* client (a real `tmux attach` elsewhere),
and the per-window pin already handles it: the pin is a ceiling, so tmux sizes
the window to the min of our pin and the external client, and whichever side is
larger shows the border. Nothing extra to compute.

## What we rely on tmux doing (measured on tmux 3.7)

These are the tmux behaviors the authority mechanism rests on. They were checked
against a real server on an isolated socket (`tmux -L probe` with
`TMUX_TMPDIR` pointed at a scratch dir), not assumed. The commands below
reproduce each result; re-run them if the pinned tmux version changes, since
window sizing has changed between tmux releases.

The default `window-size` is `latest`. Under `latest`, a window follows the size
of the client that most recently used it: a fresh 200×50 window viewed by a
100×30 client becomes 100×30, and the larger client then shows the window with
an unused border. With two clients attached, `smallest` sizes the window to the
smaller and `largest` to the larger. So across separate clients tmux already
clamps to the smallest viewer and borders the rest — the behavior we want for
one tmux window shown at two sizes.

```
tmux new-session -d -s s -x 80 -y 24
tmux set -g window-size smallest
# attach a 200x50 and a 100x30 control client, then:
tmux display -p '#{window_width}x#{window_height}'   # -> 100x30
```

`resize-window` forces a server-side size that is independent of any client. A
window resized to 200×50 stays 200×50 while a 100×30 client is attached, and
`resize-window` overrides even `window-size latest`. This is why it is the wrong
primitive for us: it would hold a large size against a smaller viewer and make
that viewer wrap, defeating the smallest-clamp.

```
tmux set -g window-size manual
tmux resize-window -t @1 -x 200 -y 50
tmux display -p -t @1 '#{window_width}x#{window_height}'  # -> 200x50, ignores a smaller client
```

Per-window client pins (`refresh-client -C '@id:WxH'`) are what we use instead.
A pin is a ceiling: tmux sizes a window to the per-axis minimum of all live pins
and any real client viewing it, and it stays independent per window, so two
mirrored windows never share one value. The one caveat the code already handles
(`RemoteTmuxControlConnection+Sizing.swift`): the client's own overall size must
cover the largest pin, because a pin cannot carry a window above the client's
size — so the session-wide client size is held at the running max of live
claims.

Finally, tmux partitions a window's grid exactly: a horizontal split of a
200-wide window yields children whose widths plus the one separator column sum
to 200 (`100 + 1 + 99`), and nested splits divide the remaining span the same
way. The pane rects we read back therefore tile the window with no rounding
slack of tmux's own.

With `pane-border-status` on, the title row replaces the separator between
stacked panes rather than adding to it. An 80×30 window with three even
vertical panes divides 10+1+9+1+9 without titles; turning titles on gives
every pane a title row and NO separator rows — (1+9)×3, with the lower panes'
title lines serving as the borders. Each pane therefore costs its grid rows
plus exactly one, and a height model that charges per-pane titles must not
also credit separator cells for the gaps.

```
tmux new-session -d -s t -x 80 -y 30
tmux split-window -v; tmux split-window -v; tmux select-layout even-vertical
tmux list-panes -F '#{pane_height} @ #{pane_top}'   # -> 10@0 9@11 9@21
tmux set -w pane-border-status top
tmux list-panes -F '#{pane_height} @ #{pane_top}'   # -> 9@1 9@11 9@21
```

```
tmux split-window -h -t @1
tmux list-panes -t @1 -F '#{pane_width}x#{pane_height} @ #{pane_left},#{pane_top}'
# -> 100x50 @ 0,0   and   99x50 @ 101,0     (100 + 1 sep + 99 == 200)
```

## Render ownership: exactly one writer per split

The transform ends at "impose the extents; bonsplit lays out and paints," but
the render side is not one passive step. Four layout authorities write pane
geometry: SwiftUI proposals, AppKit split view layout, bonsplit's own model —
which re-asserts its stored geometry when it observes a resize it did not
initiate, synchronously, inside the very layout pass that moved the frames —
and the portal's forced window layout. Left unarbitrated they fight: bonsplit
re-applies a stale extent against a container that changed, the re-apply runs
another layout pass, the pass moves more frames, and the storm pins the main
thread while split views inflate past the window. No claim feedback is
involved; the claim can be provably settled while the render layer loops on
its own.

The rule that closes it: **at any moment, exactly one authority writes a
split's geometry.**

- **At rest, the plan owns it.** A split holding an imposed extent takes
  writes only from imposition. Bonsplit must not re-assert its model against
  frames that moved under it — an imposed split whose container changed is
  *stale*, and the correction is the next sizing pass re-imposing from fresh
  inputs, never bonsplit re-applying the old extent mid-layout. The transient
  between container change and re-imposition may render off-plan; that is the
  settled-property relaxation doing its job. Re-imposing an extent equal to
  the one already stored still re-arms one apply: the number being unchanged
  does not mean the frames hold it (a foreign resize can move frames without
  touching the model), so an explicit imposition always earns one write.
- **Mid-drag, the user owns it.** A divider drag is a session with a
  deterministic start and end taken from the mouse-tracking lifecycle itself —
  never inferred from which event happens to be current when a resize callback
  fires. While a session is live, sizing passes are deferred; nothing imposes
  over the user's hand. At session end the resulting extent is converted to
  cells and sent (`resize-pane`), and tmux's reply — the settled truth —
  triggers the pass that re-imposes. When the drag rounds to the same cells
  nothing is sent and the mirror re-imposes immediately (the drag cleared the
  split's imposition, so the views no longer hold the plan), and a pass that
  was deferred mid-drag re-arms at session end because its inputs changed
  independently of the gesture.

  The round trip after a send is a known-stale-plan window, so the mirror
  holds the parity re-arm and shields the dragged split until the send is
  resolved — and every edge that releases the hold is a protocol event,
  never time. The normal edge is a reconciled layout assigning the sent
  span (or the split's structure disappearing under it). Control mode
  answers every command with an ordered `%begin`/`%end` block on the same
  stream as its notifications, and a notification a command causes lands
  after that command's `%end` but before any block for a command sent
  later. So when the resize's own block resolves, the mirror issues one
  cheap barrier command. The barrier ack closes the ordering window: at
  that point, if no layout for the window is quarantined behind its rects
  fetch, every event the resize could produce is already on our side, and
  the mirror judges the hold against the current tree; if a layout is
  quarantined, the verdict defers to that fetch's resolution (publication
  or drop — also protocol events). An `%error` reply recovers at once, and
  a stream reset fails the tracked completion, so an armed hold always
  owns a pending protocol edge.

  Amendment (2026-07-14, root-caused): this section previously claimed "a
  span tmux's cascade minimums clamp to a no-op emits no `%layout-change`
  at all" and framed the barrier as proving that silence. tmux 3.7's
  source says otherwise: `layout_resize_layout` notifies unconditionally,
  no-op or clamped (layout.c:726-728), and the only silent `resize-pane`
  is one along an axis with no container of that orientation above the
  pane (layout.c:686-687). The claim was written from lab observation and
  was unfalsifiable by our oracles — a no-op's identical-string layout
  event stages, publishes, and releases the hold through the reconcile
  path, so both hypotheses produce the same observable release; only
  reading the source distinguished them. The mechanism was and is correct
  under both readings; the barrier's real roles are the ordering fence and
  the one silent case. The tmux facts now live in
  `docs/remote-tmux-reconcile-design.md` (the tmux section), verified
  against source rather than observed behavior.
- **Hidden, nobody writes.** A hidden tab's tree is frozen: no impositions
  (already the rule) and no model re-assertions. It is re-planned from fresh
  inputs when shown.

Drag state is never inferred from imposition state. Without the deferral, a
sizing pass landing after drag-start re-arms the imposition on the dragged
split, and any "imposed means not mid-drag" shortcut then swallows the drag's
`resize-pane` permanently. With sizing deferred for the length of the session,
an imposed split really cannot be mid-drag — by construction, not assumption.

Ownership also carries a liveness obligation: an apply may never terminate
off-target without a re-arm edge. Imposing is asynchronous — bonsplit applies
on a later turn, and the result can land somewhere else entirely (a divider
parked at a minimum, a retry budget expired against mid-commit bounds). The
transaction's settled check compares only inputs, so on its own a miss like
that would sit behind unchanged inputs forever; the live fuzz held a 1199pt
plan against a 984pt view for over fifty seconds while every trigger reported
settled. So the transaction verifies the outcome after applying: once the
geometry has had time to land, it compares the planned outer sizes against
the hosted views' actual frames, and a parked or budget-expired imposition
gets one bounded re-apply — a few attempts per input fixed point, reset when
the inputs change, so an extent bonsplit genuinely cannot hold stops after a
bounded correction instead of looping.

Settle speed is itself a testable property. A healthy full cycle — claim,
tmux layout, imposition, rendered frames — settles in well under a second
(about 0.4s measured on the live lab). The harnesses fail an iteration that
has not settled within 8 seconds instead of waiting longer: every stall this
work chased eventually argued itself out within a generous window, so a
generous window is exactly what masked the defect.

## Chrome parity

The claim subtracts a model of the chrome — surface padding, per-pane tab-bar
height, the divider-versus-separator difference, and pane-title rows — to decide
how many cells fit. The render then draws the actual chrome. The transform is
correct only if those two amounts are identical. If the claim reserves a 24pt tab
bar while bonsplit paints 28, or models the divider a point off, the per-pane
rects no longer sum to the container and the trailing pane comes up a column
short — the same wrap this work exists to remove. A pure transform computed with
the wrong chrome constant is still wrong, so parity is a soundness requirement,
not a detail.

Two encodings of the same quantity drift. The claim computes chrome in
`clientGrid`'s residual; bonsplit computes it from its own appearance config.
Since bonsplit is the renderer, parity means the claim reads its chrome sizes —
divider thickness, per-pane tab-bar height, pane insets — from the *same*
bonsplit appearance config bonsplit paints with, never from a separate estimate.
One source, read by both.

A debug check must then assert the measured rendered chrome (a pane's
`surfacePx − cols·cellPx`, and the container minus the summed pane rects) equals
the model, failing loudly on drift, because parity that is not checked rots
silently. Some of the residual mismatches were this drift, not feedback or
latency: the claim reserved a different divider or tab-bar amount than bonsplit
painted, so the panes never quite fit however cleanly the rest settled.

## Alternatives considered

- **Claim from the measured SwiftUI container (`proxy.size`).** This is what the
  code does today and it is the bug: the input depends on the output, so the
  container can grow ~19pt per pass and never settle. Rejected — it is a feedback
  controller, not a transform.

- **Draw our own panes, dividers, tab bars, and drag (direct-frame render).**
  Placement would become `frame = rect` with no layout solver, and chrome parity
  would hold by construction. Rejected: it throws away bonsplit's native chrome,
  per-pane tab bars, divider feel, and drag, and reimplementing all of that to
  match is a large, permanent maintenance cost for a rendering job bonsplit
  already does well. We keep bonsplit as the renderer and instead make the claim
  agree with it (shared chrome config) and impose the tmux-assigned extents on it.

- **One client size + `window-size latest` (all windows follow).** Simple, but
  O(N): one change resizes every window in the session, fanning out layout events
  under churn. Rejected in favor of per-window `refresh-client -C` pins on the
  visible window only (O(1)); same visual result without the fan-out.

- **Let NSSplitView's built-in minimum pane sizes stand.** Its minimums caused
  the wrong behavior (a 1-column tmux pane rendered wider than assigned); tmux is
  the authority and allows 1-column panes, so a minimum is incorrect. We keep
  bonsplit but drive its minimums to match tmux's, rather than accepting its
  defaults.

## Open questions

- The exact bonsplit appearance config the claim must read for chrome parity
  (divider thickness, per-pane tab-bar height, insets) and where that single
  source lives so both the claim and the renderer read it.
- How faithfully bonsplit applies an imposed extent mid-drag, and whether the
  drag-end → `resize-pane` → settled-layout round trip needs any nudge to land
  exactly.
- `window-size manual` behaviour on a real shared session (co-attached clients),
  verified only on the loopback lab so far.
