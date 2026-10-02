# Tab layout protocol model (TLA+)

`TabLayout.tla` models the tab layout protocol between the workspace-store owner (the cmux-tui daemon) and client projections (the app), as `../OWNERSHIP-PRINCIPLES.md` binds it. TLC checks it.

**Owner.** Alive panes map to sequences of tabs; each pane maps to one workspace, and a workspace is the set of panes that map to it. Ops carry a client-chosen idempotency key: MoveTab (including the own pane and own index), SplitWithTab (rejected for the tab's own pane when it is the only tab), MoveToNewWorkspace (tear-off) and Close, the only op that removes a tab. A pane that empties is removed in the same commit. Pane and workspace ids are never reused. One commit appends one event batch, tagged with the op id, to the log, so a sequence number names a transaction. A valid op that changes nothing commits no batch. Every request ends with request-settled `{transaction, sequence, rejected}`, including rejects and replays. The replay record (`doneOps`, `rejectedOps`) and the log survive an owner restart.

**Client.** A confirmed mirror is written only by owner batches. An ordered intent log holds pending ops, and visible = mirror + intents. An intent leaves on its echo (the batch with its op id), on a reject, on the write barrier (a settle whose sequence the mirror has reached, which is how a no-change op settles), or on a snapshot that lists it as processed. Delivery reorders (any in-flight batch may come next) and duplicates. The client applies the next sequence, drops stale ones, and takes a snapshot on a gap or when a batch names an unknown pane. Faults share one bound (`MaxFaults`): a duplicated batch, a replayed request with the same key, a client disconnect (in-flight requests survive or are lost) followed by a reconnect (snapshot, then every pending intent is resent with its key), and an owner restart (in-flight requests and messages are lost and every client reconnects).

**Drag presentation.** A strip hides the dragged tab while the gesture is held and while its landing awaits settle. A second drag may start during a landing. A drop on the tab's own place (same pane, same clamped final index, or a split of its own pane when it is the only tab) sends nothing. Every end shows the tab again: cancel, reject, a settled landing (echo, barrier or snapshot) or a lost connection. `BUGGY_DETACH = TRUE` reproduces the app bug fixed in `TabDragLifecycle.release`: release happened only when the mirror removed the tab from its source strip, so a drop on its own pane at another index kept it hidden forever.

Difference from the app: on a lost connection the model ends both the landing and a gesture still in flight (`Disconnect`, `OwnerRestart`). The app settles a committing drag on `.disconnected` or when the event stream ends (DaemonStore runs every waiter, db4ea257a73), and `release` then ends its presentation, as in the model. A drag not yet committed is not ended by the disconnect: the session cancels it on the next mouse-down or app resign. The model's earlier end is a stronger assumption only for the presentation of an uncommitted gesture; that gesture sends nothing, so the owner and mirror properties are unaffected.

Abstractions: split and tear-off intents add no provisional pane to the visible state (the client does not know the new id). Pane geometry, columns, groups and terminals are not modeled. A snapshot is read atomically from owner state.

## Properties

| Name | Kind | Meaning |
| --- | --- | --- |
| `I1_TabConservation` | invariant | owner tabs = initial tabs minus closed |
| `I2_ExactlyOnePane` | invariant | each live tab is in exactly one alive pane, once |
| `I3_NoEmptyPaneOrWorkspace` | invariant | no empty pane; every alive pane is in a workspace |
| `I4_OwnPlaceNoOp` | action | a drop whose effect leaves the visible layout unchanged, or a split of the own single-tab pane, sends nothing |
| `P1_Projection` | invariant | the mirror equals the owner's tree at the client's applied sequence |
| `Convergence` (principle 4) | invariant | empty intent log and empty inbox imply visible = owner |
| `Idempotency`, `IdempotentReplay` (principle 5) | invariant, action | one batch per key; a replayed key changes nothing |
| `ConcurrentSerializable` (principle 6) | invariant | an accepted intent that left a client's log has its batch in that mirror; a settle never precedes its batch |
| `DP1_DragPresentation`, `DP1_EndsExactlyOnce` | invariant, action | hidden = tabs of in-flight drags and landings; each end shows its tab in the same step, exactly once |
| `VisibleNoDuplicate`, `QuiescentConvergence` | invariant | no tab shown twice; at quiescence every client equals the owner |
| `EventuallyConverged` | liveness | under weak fairness of system actions only, infinitely often everything is settled and every client equals the owner, except a gesture the user still holds |

## Running

```bash
plans/cmux-next/formal/run-tlc.sh          # fixed, live, buggy
plans/cmux-next/formal/run-tlc.sh fixed    # or: live, buggy
```

The script needs Java 11 or later. It downloads `tla2tools.jar` v1.7.4 into `~/.cache/cmux-tla` (override with `CMUX_TLA_CACHE`), checks its sha256, and runs TLC with `-workers 2` (override with `TLC_WORKERS`). v1.8.0 is a rolling prerelease whose jar changes, so it cannot be pinned by hash. The exit code is 0 only when the fixed and live configs pass and the buggy config fails.

## Last results

Run 2026-10-01 on a shared Mac at load 300-440, TLC 1.7.4, Java 26, `-workers 2`.

| Config | Bound | Result | Distinct states | Depth | Time |
| --- | --- | --- | --- | --- | --- |
| `TabLayout_fixed.cfg` | 3 tabs, 4 pane ids, 3 workspace ids, 2 clients, 2 ops, 1 fault | pass (all invariants and action properties) | 3,953,751 (24,022,337 generated) | 16 | 32 min 52 s |
| `TabLayout_live.cfg` | same, 2 tabs, plus `EventuallyConverged` | pass | 573,873 (3,258,194 generated) | 16 | 14 min 11 s |
| `TabLayout_buggy.cfg` | as fixed, `BUGGY_DETACH = TRUE` | `DP1_DragPresentation` violated | 1,822 when found | 5 | 1 s |

Buggy counterexample: (1) initial state, pane 1 = [1, 2], pane 2 = [3]; (2) client 1 starts dragging tab 1, the strip hides it; (3) client 1 drops it on its own pane at index 2, sending move op 1 and keeping tab 1 hidden as a landing; (4) the owner applies op 1 (pane 1 = [2, 1]) and emits its batch; (5) client 1 applies the echo, the intent and the landing end, but tab 1 is still in its source strip, so the buggy release skips it and tab 1 stays hidden with no drag or landing in flight.

Mutation checks on the fixed config: settling an intent before the mirror reaches the settle sequence (no write barrier) fails `ConcurrentSerializable` at depth 5; removing the owner's replay dedup fails `IdempotentReplay` at depth 5. Reusing pane ids is not caught by any property (a stale op that names a removed pane would land in a new pane with that id), so id freshness is an assumption of the model, not a checked result.

Not covered: two faults in one behavior (`MaxFaults = 2`), a replay record that is lost on restart, a snapshot that arrives out of order with later batches, columns and groups. The fixed run is too slow for every push at this load; a CI job should run `run-tlc.sh` on a dedicated runner or nightly.

## Companion: `OwnershipConvergence.tla`

The generic op protocol under every single-writer entity (`../ownership.md` section 6): owner commit before publish (a restart loses only the staged op), `request-settled` with a sequence, client replies held in memory until the mirror covers that sequence, snapshots carrying the requester's decided keys, resend of every intent on reconnect, and client-owned records written only by the connection's identity. Run `./run-ownership-tlc.sh` (default config), `./run-ownership-tlc.sh OwnershipConvergence-live.cfg` (liveness) or `./run-ownership-tlc.sh --mutants` (seven broken variants that must each fail).

## Companion: `LayoutRows.tla`

The structure that the row ops of `../rows.md` produce. Owner state: one screen as a strip of columns, each column a strip of rows (height 1..MaxH units, MaxH standing for 1000 permille), each row a sequence of panes (its split tree with geometry abstracted), each pane a sequence of tabs; sticky flags per column. A split screen (the daemon's one column with one row) is represented as that column and row. Ops, each with a key: split inside a row, new column, new row, move a tab to a pane, move a tab to a new row before or after the anchor's row (with the spawn-same-kind variant), close a tab, set the heights of a column's rows (refused when the client's row set is stale), set sticky. A rejected op changes nothing; a container that empties is removed in the same step, bottom up (pane, row, column), and sticky flags are normalized after a column removal; new ids are fresh and never reused; a replayed key changes nothing. Clients build ops from their own, possibly stale mirror, so ops can name removed panes, rows or tabs; the owner validates against its own state. A client adopts the owner's state in one step and repairs its view (focused pane, top row per column) with the close-focus rule of rows.md N3. The owner never reads client view state. The protocol under this (intent log, echo, request-settled, reordered and lost messages, reconnect) is TabLayout.tla's and OwnershipConvergence.tla's.

| Name | Kind | Meaning |
| --- | --- | --- |
| `R1_SinglePlacement` | invariant | every tab in one pane, every pane in one row, every row in one column, once; nothing hangs off a removed container |
| `R2_NoEmptyContainer` | invariant | no empty pane, row or column |
| `R3_TabConservation` | invariant | live tabs = tabs ever created minus closed tabs (moves never add or drop a tab; spawning ops add exactly theirs) |
| `R4_HeightInRange` | invariant | every live row height in 1..MaxH |
| `R5_StickyConsistent` | invariant | at most one sticky column per edge; if any column is sticky, one scrolls |
| `R6_OwnPlaceSound` | invariant | an op the owner treats as own place would not have changed what a user sees |
| `R6_OwnPlaceComplete` | action | every committed change changes what a user sees (no op only churns ids) |
| `ExactlyOnce` | invariant | one key commits at most once (I5) |
| `ViewValid` | invariant | each client's focused pane and top rows exist in its mirror |
| `FocusStaysLocal` | invariant | a removed focus stays in its column while that column has panes (N3) |

Mutants (`BUG`), each must fail: `keepEmptyRow` (an emptied row is kept), `noStickyNormalize` (a column removal skips sticky normalization; run on the three-column start), `ownPlaceRowOnly` (own place sees only the boundary below the own row), `noDedup` (a replayed key applies again), `noFocusRepair` (a client keeps a removed focus), `focusColumnFirst` (focus repair jumps to the left column before the rows above and below), `respawnDropsTab` (the spawn-same-kind move puts the new tab in the new row and drops the moved tab).

Run `./run-rows-tlc.sh` (main configs and mutants), `./run-rows-tlc.sh main` or `./run-rows-tlc.sh mutants`.

Last results (2026-10-01/02, shared Mac at load 130-160, TLC 1.7.4, Java 26; heights 1..2):

| Config | Bound | Result | Distinct states | Depth | Time |
| --- | --- | --- | --- | --- | --- |
| `LayoutRows.cfg` | 1 client, 3 ops, no replay; 4 tabs, 4 pane ids, 3 row ids, 2 column ids | pass | 22,804,256 (77,900,119 generated) | 12 | 27 min, 6 workers |
| `LayoutRows_2clients.cfg` | 2 clients, 2 ops, 1 replay; same ids | pass | 6,793,112 (39,838,937 generated) | 14 | 2 min 43 s, 4 workers |
| `LayoutRows_sticky3.cfg` | three columns, outer two sticky; 1 client, 2 ops, 1 replay; 5 tabs, 5 pane ids, 4 row ids, 4 column ids | pass | 1,508,296 (6,550,262 generated) | 11 | 78 s |
| `keepEmptyRow` | as `LayoutRows.cfg` with 1 replay | `R2_NoEmptyContainer` violated | 16,282 when found | 5 | 1 s |
| `sticky3_noStickyNormalize` | as `LayoutRows_sticky3.cfg` | `R5_StickyConsistent` violated | 603 when found | 5 | 1 s |
| `ownPlaceRowOnly` | as `LayoutRows.cfg` with 1 replay | `R6_OwnPlaceComplete` violated | 65,497 when found | 5 | 2 s |
| `noDedup` | same | `ExactlyOnce` violated | 196,016 when found | 6 | 2 s |
| `noFocusRepair` | same | `ViewValid` violated | 11,605 when found | 5 | 1 s |
| `focusColumnFirst` | same | `FocusStaysLocal` violated | 12,748,151 when found | 9 | 203 s |
| `respawnDropsTab` | same | `R3_TabConservation` violated | 1,947 when found | 4 | 2 s |

Bounds that did not finish and are not evidence: two clients with three ops (more than 53 million distinct states, queue still growing after 17 minutes) and one client with three ops plus a replay (79 million distinct states, 26 million queued after 70 minutes). Not covered: split ratios and column widths (the reducer does not model them yet), `fit` heights (sum 1000), sticky rows (not in `rows-v1`), the vertical scroll reducer (Swift tests), legacy commands from old clients (daemon proptest, rows.md step 3).

## Companion: `closefocus.tla`

Focus and scroll after a close (`../close-focus.md`): one window's client view state over the projected layout. `Kind = "strip"` is the niri column strip (columns of panes, the successor is `FocusAfterClose.pane`, `Policy` previous neighbor or most recent); `Kind = "list"` is the sidebar's workspace list (the successor is the next row, else the previous one). Anyone may close any item; origin does not enter the rules. A close re-anchors the offset, reveals the focus with the least scroll, clamps, and the presented offset animates to the target.

Properties: `Safety` (focus is live and never removed, target clamped, target shows the focus), `UnfocusedCloseKeepsFocus`, `NoJump`, `MinimalReveal`, `SuccessorRule` (stated on column indices, independent of the successor definition), `NoSecondScroll` (a `Resync` step re-settles unchanged geometry and must not scroll), and liveness `Settles` (after the last user step the view settles with the focus visible; weak fairness on the animation only).

Run `./run-closefocus-tlc.sh` (configs strip, strip-recent, list; must pass) and `./run-closefocus-tlc.sh --mutants` (history-first successor, no anchor on strip and list, centering reveal, no reveal, a nudging resync on list and strip; each must fail). Same pinned jar as `run-tlc.sh`.

Last results (2026-10-01, TLC 1.7.4, Java 26, `-workers 2`): strip 23,057 distinct states (83,305 generated, depth 11), strip-recent 23,229 (84,039, depth 11), list 93,149 (332,887, depth 10); about 20 s in all. Mutants: history caught by `SuccessorRule`, noanchor (list and strip) by `NoJump`, center by `MinimalReveal`, noreveal (strip) by `Safety`, nudge by `Safety` first and by `NoSecondScroll` alone when the other properties are off.

Abstractions: every column is `CW` wide and every row `CW` tall with no gap and no padding (the Swift model checks cover mixed widths, padding and gaps); the presented offset moves one unit per animation step; niri's restore point after closing a just-opened column is not modeled.
