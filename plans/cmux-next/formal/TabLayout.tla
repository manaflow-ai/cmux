------------------------------ MODULE TabLayout ------------------------------
(***************************************************************************)
(* Tab layout protocol between the workspace-store owner (cmux-tui daemon) *)
(* and client projections (the app), per OWNERSHIP-PRINCIPLES.md.          *)
(*                                                                         *)
(* Owner: alive panes -> sequence of tabs; each pane in one workspace (a   *)
(* workspace is the set of panes mapped to it). Typed ops with a client-   *)
(* chosen idempotency key (op id): MoveTab (incl. own pane / own index),   *)
(* SplitWithTab (own pane holding only the tab is rejected),               *)
(* MoveToNewWorkspace (tear-off), Close (only op that removes a tab). A    *)
(* pane that empties is removed in the same commit. One commit appends one *)
(* event batch (one transaction, tagged with the op id) to the log, so a   *)
(* sequence number names a batch. Every request ends with request-settled  *)
(* {transaction, sequence, rejected}, including rejects and replays. The   *)
(* replay record (doneOps, rejectedOps) is durable: it survives a restart. *)
(*                                                                         *)
(* Client: a confirmed mirror written only by owner batches, plus one      *)
(* ordered log of pending intents; visible = mirror + intents. An intent   *)
(* leaves on its echo (the batch carrying its op id), on a reject, on the  *)
(* write barrier (request-settled whose sequence the mirror has reached,   *)
(* so a no-change command also settles), or on a snapshot that lists it   *)
(* as processed. The event channel reorders (any in-flight batch can come  *)
(* next) and duplicates (bounded re-delivery). The client applies the next *)
(* sequence, drops stale ones, and takes a snapshot on a gap or when a     *)
(* batch names an unknown pane. Faults (bounded together by MaxFaults):    *)
(* duplicate batch, replayed request (same key), client disconnect then    *)
(* reconnect (snapshot, resend pending intents with their keys), owner     *)
(* restart (in-flight requests and messages lost, every client reconnects).*)
(*                                                                         *)
(* Drag presentation (DP1): during a drag the source strip hides the        *)
(* dragged tab (detached). A drop on the tab's own place (same strip, same *)
(* clamped final index) resolves to no operation (cancel). The drag ends   *)
(* on cancel, reject, lost connection, or when its intent settles (echo,  *)
(* barrier, snapshot), and release must show the tab again on every end.   *)
(* A split of the tab's own pane when it is the only tab is also no op,    *)
(* unless RESPAWN = TRUE (tab-split-respawn-v1): then it is the typed op   *)
(* SplitRespawn, which moves the tab into a new pane and creates one fresh *)
(* tab (id from SpawnTabs, never reused) in the old pane, in one commit.   *)
(* Creation is explicit, so I1 counts created tabs: live tabs are the     *)
(* initial and created tabs minus closed ones.                             *)
(* BUGGY_DETACH = TRUE: release only when the mirror removes the tab from  *)
(* the source strip, so a landed drop that keeps the tab in its own strip  *)
(* (own pane, other index) never ends the hidden state. The bug was        *)
(* app-side only; the owner kept every tab.                                *)
(*                                                                         *)
(* Abstraction: split and tear-off intents add no provisional pane to the  *)
(* visible state (the client does not know the new pane id); move and      *)
(* close intents apply to it. Pane geometry (edges, columns) is not        *)
(* modeled.                                                                *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS NTabs, NPanes, NWorkspaces, NClients, MaxOps, MaxFaults, BUGGY_DETACH,
          NSpawn, RESPAWN

Tabs       == 1..NTabs
SpawnTabs  == (NTabs + 1)..(NTabs + NSpawn)   \* ids for tabs a respawn creates
AllTabs    == Tabs \cup SpawnTabs
Panes      == 1..NPanes
Workspaces == 1..NWorkspaces
Clients    == 1..NClients

\* Initial layout: pane 1 holds tabs 1..NTabs-1, pane 2 holds tab NTabs,
\* both in workspace 1. Other pane ids are free for split / tear-off.
InitLayout == [p \in Panes |-> IF p = 1 THEN [k \in 1..(NTabs - 1) |-> k]
                               ELSE IF p = 2 THEN <<NTabs>> ELSE <<>>]
InitAlive  == {1, 2}
InitWs     == [p \in Panes |-> IF p \in InitAlive THEN 1 ELSE 0]

NoDrag == [tab |-> 0, src |-> 0]     \* dragging[c] when no gesture is held

VARIABLES
  \* owner (workspace store)
  layout, alive, wsOf, closed, created, log, doneOps, rejectedOps, requests,
  \* channels
  inbox, replies, faults,
  \* client projections
  mirror, mirrorAlive, mirrorWs, applied, pending, dragging, landing, hidden, stale,
  \* ids ever used (never reused) and bound
  usedPanes, usedWs, opCount

ownerVars  == <<layout, alive, wsOf, closed, created, log, doneOps, rejectedOps, usedPanes,
               usedWs>>
clientVars == <<mirror, mirrorAlive, mirrorWs, applied, pending, dragging, landing, hidden, stale>>
vars == <<layout, alive, wsOf, closed, created, log, doneOps, rejectedOps, requests,
          inbox, replies, faults, mirror, mirrorAlive, mirrorWs, applied,
          pending, dragging, landing, hidden, stale, usedPanes, usedWs, opCount>>

-----------------------------------------------------------------------------
(* Sequence helpers *)
Range(s)          == {s[k] : k \in DOMAIN s}
Contains(s, t)    == \E k \in DOMAIN s : s[k] = t
Remove(s, t)      == SelectSeq(s, LAMBDA x : x # t)
InsertAt(s, i, t) == SubSeq(s, 1, i - 1) \o <<t>> \o SubSeq(s, i, Len(s))
Min(a, b)         == IF a < b THEN a ELSE b
IndexOf(s, t)     == CHOOSE k \in DOMAIN s : s[k] = t

HasTab(lay, live, t) == \E p \in live : Contains(lay[p], t)
PaneOf(lay, live, t) == CHOOSE p \in live : Contains(lay[p], t)

\* Move t to pane p, final index i (clamped).
MoveIn(lay, live, t, p, i) ==
  LET src  == PaneOf(lay, live, t)
      lay1 == [lay EXCEPT ![src] = Remove(@, t)]
  IN  [lay1 EXCEPT ![p] = InsertAt(@, Min(i, Len(lay1[p]) + 1), t)]

Event(kind, t, p, i, w) == [kind |-> kind, tab |-> t, pane |-> p, idx |-> i, ws |-> w]

-----------------------------------------------------------------------------
(* Client view: visible = mirror + pending intents, in log order *)

ApplyIntent(lay, live, m) ==
  CASE m.kind = "move"  ->
         IF m.pane \in live /\ HasTab(lay, live, m.tab)
         THEN MoveIn(lay, live, m.tab, m.pane, m.idx) ELSE lay
    [] m.kind = "close" -> [p \in Panes |-> Remove(lay[p], m.tab)]
    [] OTHER            -> lay      \* split / tear-off: no provisional pane

RECURSIVE Overlay(_, _, _)
Overlay(lay, live, ms) ==
  IF ms = <<>> THEN lay
  ELSE Overlay(ApplyIntent(lay, live, Head(ms)), live, Tail(ms))

Visible(c)      == Overlay(mirror[c], mirrorAlive[c], pending[c])
VisibleTabs(c)  == UNION {Range(Visible(c)[p]) : p \in mirrorAlive[c]}
PendingOps(c)   == {pending[c][k].op : k \in DOMAIN pending[c]}
Dragging(c)     == dragging[c].tab # 0
\* Tabs held by the in-flight gesture and by landings awaiting settle.
HeldTab(c)      == (IF Dragging(c) THEN {dragging[c].tab} ELSE {})
                     \cup {l.tab : l \in landing[c]}

-----------------------------------------------------------------------------
Init ==
  /\ layout = InitLayout /\ alive = InitAlive /\ wsOf = InitWs
  /\ closed = {} /\ created = {} /\ log = <<>> /\ doneOps = {} /\ rejectedOps = {}
  /\ requests = {}
  /\ inbox = [c \in Clients |-> {}] /\ replies = [c \in Clients |-> {}]
  /\ faults = 0
  /\ mirror = [c \in Clients |-> InitLayout]
  /\ mirrorAlive = [c \in Clients |-> InitAlive]
  /\ mirrorWs = [c \in Clients |-> InitWs]
  /\ applied = [c \in Clients |-> 0]
  /\ pending = [c \in Clients |-> <<>>]
  /\ dragging = [c \in Clients |-> NoDrag]
  /\ landing = [c \in Clients |-> {}]
  /\ usedPanes = InitAlive /\ usedWs = {1}
  /\ hidden = [c \in Clients |-> {}]
  /\ stale = [c \in Clients |-> FALSE]
  /\ opCount = 0

-----------------------------------------------------------------------------
(* Client: gestures and intents *)

NewIntent(c, kind, t, p, i) ==
  [op |-> opCount + 1, client |-> c, kind |-> kind, tab |-> t, pane |-> p, idx |-> i]

\* Append the intent to the log and send it as a request (same record).
Commit(c, kind, t, p, i) ==
  /\ pending' = [pending EXCEPT ![c] = Append(@, NewIntent(c, kind, t, p, i))]
  /\ requests' = requests \cup {NewIntent(c, kind, t, p, i)}
  /\ opCount' = opCount + 1

\* The gesture ends; its tab stays hidden as a landing until the intent settles.
Land(c) == /\ dragging' = [dragging EXCEPT ![c] = NoDrag]
           /\ landing' = [landing EXCEPT ![c] = @ \cup
                 {[tab |-> dragging[c].tab, op |-> opCount + 1, src |-> dragging[c].src]}]
           /\ UNCHANGED hidden

\* The gesture ends with no operation: show the tab again.
Release(c) == /\ dragging' = [dragging EXCEPT ![c] = NoDrag]
              /\ hidden' = [hidden EXCEPT ![c] = @ \ {dragging[c].tab}]
              /\ UNCHANGED landing

CanCommit(c) == opCount < MaxOps /\ ~stale[c]

StartDrag(c, t) ==
  LET v == Visible(c) IN
  /\ CanCommit(c)
  /\ ~Dragging(c)
  /\ HasTab(v, mirrorAlive[c], t)
  /\ t \notin hidden[c]                    \* a hidden tab cannot be grabbed
  /\ dragging' = [dragging EXCEPT ![c] = [tab |-> t, src |-> PaneOf(v, mirrorAlive[c], t)]]
  /\ hidden' = [hidden EXCEPT ![c] = @ \cup {t}]
  /\ UNCHANGED <<ownerVars, requests, inbox, replies, faults, mirror, mirrorAlive,
                 mirrorWs, applied, pending, landing, stale, opCount>>

CancelDrag(c) ==
  /\ Dragging(c)
  /\ Release(c)
  /\ UNCHANGED <<ownerVars, requests, inbox, replies, faults, mirror, mirrorAlive,
                 mirrorWs, applied, pending, stale, opCount>>

DragReady(c) ==
  /\ ~stale[c]
  /\ Dragging(c)
  /\ HasTab(Visible(c), mirrorAlive[c], dragging[c].tab)

DropMove(c, p, i) ==
  LET t   == dragging[c].tab
      v   == Visible(c)
      src == PaneOf(v, mirrorAlive[c], t)
      own == src = p
  IN
  /\ DragReady(c)
  /\ p \in mirrorAlive[c]
  /\ i \in 1..(Len(v[p]) + (IF own THEN 0 ELSE 1))
  /\ IF own /\ Min(i, Len(v[p])) = IndexOf(v[p], t)
     THEN \* own place: no operation, nothing sent (I4)
          /\ Release(c)
          /\ UNCHANGED <<pending, requests, opCount>>
     ELSE /\ CanCommit(c)
          /\ Commit(c, "move", t, p, i)
          /\ Land(c)
  /\ UNCHANGED <<ownerVars, inbox, replies, faults, mirror, mirrorAlive, mirrorWs,
                 applied, stale>>

DropSplit(c, p) ==
  LET t == dragging[c].tab
      v == Visible(c)
  IN
  /\ DragReady(c)
  /\ p \in mirrorAlive[c]
  /\ IF PaneOf(v, mirrorAlive[c], t) = p /\ Len(v[p]) = 1
     THEN IF RESPAWN
          THEN \* split of its own pane with a fresh tab of the same kind left behind
               /\ CanCommit(c)
               /\ Commit(c, "splitRespawn", t, p, 0)
               /\ Land(c)
          ELSE \* split of its own pane when it is the only tab: no operation (I4)
               /\ Release(c)
               /\ UNCHANGED <<pending, requests, opCount>>
     ELSE /\ CanCommit(c)
          /\ Commit(c, "split", t, p, 0)
          /\ Land(c)
  /\ UNCHANGED <<ownerVars, inbox, replies, faults, mirror, mirrorAlive, mirrorWs,
                 applied, stale>>

DropTearOff(c) ==
  /\ DragReady(c)
  /\ CanCommit(c)
  /\ Commit(c, "tearoff", dragging[c].tab, 0, 0)
  /\ Land(c)
  /\ UNCHANGED <<ownerVars, inbox, replies, faults, mirror, mirrorAlive, mirrorWs,
                 applied, stale>>

CloseTab(c, t) ==
  /\ CanCommit(c)
  /\ t \notin HeldTab(c)
  /\ t \in VisibleTabs(c)
  /\ Commit(c, "close", t, 0, 0)
  /\ UNCHANGED <<ownerVars, inbox, replies, faults, mirror, mirrorAlive, mirrorWs,
                 applied, dragging, landing, hidden, stale>>

-----------------------------------------------------------------------------
(* Owner *)

\* Ids are never reused (cmux-tui public ids are unique), so a stale op that
\* names a removed pane cannot land in a new pane with the same id.
FreePanes == Panes \ usedPanes
FreeWs    == Workspaces \ usedWs
FreeTabs  == SpawnTabs \ created

Valid(r) ==
  /\ r.tab \notin closed
  /\ CASE r.kind = "move"    -> r.pane \in alive
       [] r.kind = "split"   ->
            /\ r.pane \in alive
            /\ FreePanes # {}
            /\ ~(PaneOf(layout, alive, r.tab) = r.pane /\ Len(layout[r.pane]) = 1)
       [] r.kind = "splitRespawn" ->
            \* only the pane's only tab; a concurrent op that added a tab rejects it
            /\ RESPAWN
            /\ r.pane \in alive
            /\ FreePanes # {}
            /\ FreeTabs # {}
            /\ layout[r.pane] = <<r.tab>>
       [] r.kind = "tearoff" ->
            LET src == PaneOf(layout, alive, r.tab) IN
            /\ FreePanes # {}
            /\ FreeWs # {}
            /\ ~(Len(layout[src]) = 1 /\ {p \in alive : wsOf[p] = wsOf[src]} = {src})
       [] r.kind = "close"   -> TRUE

\* Append one transaction batch; deliver to connected clients only.
Emit(r, events, tree) ==
  /\ log' = Append(log, [op |-> r.op, client |-> r.client, events |-> events, tree |-> tree])
  /\ inbox' = [c \in Clients |-> IF stale[c] THEN inbox[c] ELSE inbox[c] \cup {Len(log) + 1}]

Settle(r, seq, rej) ==
  replies' = [replies EXCEPT ![r.client] =
                IF stale[r.client] THEN @ ELSE @ \cup {[op |-> r.op, seq |-> seq, rej |-> rej]}]

\* Remove src in the same commit if it emptied: <<alive, wsOf, events>>.
Reap(lay, live, ws, src) ==
  IF src \in live /\ Len(lay[src]) = 0
  THEN <<live \ {src}, [ws EXCEPT ![src] = 0], <<Event("PaneClosed", 0, src, 0, 0)>>>>
  ELSE <<live, ws, <<>>>>

Commit3(lay, rp, ev, r) ==
  /\ layout' = lay /\ alive' = rp[1] /\ wsOf' = rp[2]
  /\ Emit(r, ev \o rp[3], [lay |-> lay, live |-> rp[1], ws |-> rp[2]])
  /\ usedPanes' = usedPanes \cup rp[1]
  /\ usedWs' = usedWs \cup {rp[2][x] : x \in rp[1]}

\* A valid op whose result equals the current layout (a move to the place
\* the tab already has, e.g. after a concurrent op) commits no batch; only
\* the write barrier settles it.
NoChange(r) ==
  r.kind = "move" /\ MoveIn(layout, alive, r.tab, r.pane, r.idx) = layout

ApplyOk(r) ==
  LET t   == r.tab
      src == PaneOf(layout, alive, t)
      q   == CHOOSE x \in FreePanes : TRUE
  IN
  CASE r.kind = "move" ->
         LET lay == MoveIn(layout, alive, t, r.pane, r.idx) IN
         /\ Commit3(lay, Reap(lay, alive, wsOf, src),
                    <<Event("TabChanged", t, r.pane, IndexOf(lay[r.pane], t), 0)>>, r)
         /\ UNCHANGED <<closed, created>>
    [] r.kind = "split" ->
         LET w    == wsOf[r.pane]
             live == alive \cup {q}
             ws   == [wsOf EXCEPT ![q] = w]
             lay  == MoveIn(layout, live, t, q, 1)
         IN /\ Commit3(lay, Reap(lay, live, ws, src),
                       <<Event("PaneAdded", 0, q, 0, w), Event("TabChanged", t, q, 1, 0)>>, r)
            /\ UNCHANGED <<closed, created>>
    [] r.kind = "splitRespawn" ->
         \* the fresh tab first, so the pane keeps a tab throughout; then the split
         LET n    == CHOOSE x \in FreeTabs : TRUE
             w    == wsOf[r.pane]
             live == alive \cup {q}
             ws   == [wsOf EXCEPT ![q] = w]
             lay  == [layout EXCEPT ![r.pane] = <<n>>, ![q] = <<t>>]
         IN /\ Commit3(lay, Reap(lay, live, ws, src),
                       <<Event("TabChanged", n, r.pane, 1, 0), Event("PaneAdded", 0, q, 0, w),
                         Event("TabChanged", t, q, 1, 0)>>, r)
            /\ created' = created \cup {n}
            /\ UNCHANGED closed
    [] r.kind = "tearoff" ->
         LET w    == CHOOSE x \in FreeWs : TRUE
             live == alive \cup {q}
             ws   == [wsOf EXCEPT ![q] = w]
             lay  == MoveIn(layout, live, t, q, 1)
         IN /\ Commit3(lay, Reap(lay, live, ws, src),
                       <<Event("WorkspaceAdded", 0, 0, 0, w), Event("PaneAdded", 0, q, 0, w),
                         Event("TabChanged", t, q, 1, 0)>>, r)
            /\ UNCHANGED <<closed, created>>
    [] r.kind = "close" ->
         LET lay == [layout EXCEPT ![src] = Remove(@, t)] IN
         /\ Commit3(lay, Reap(lay, alive, wsOf, src), <<Event("TabClosed", t, src, 0, 0)>>, r)
         /\ closed' = closed \cup {t}
         /\ UNCHANGED created

OwnerApply(r) ==
  /\ requests' = requests \ {r}
  /\ IF r.op \in doneOps THEN
          \* idempotent replay: no effect, settle with the recorded result
          /\ Settle(r, Len(log), r.op \in rejectedOps)
          /\ UNCHANGED <<layout, alive, wsOf, closed, created, log, inbox, doneOps,
                         rejectedOps, usedPanes, usedWs>>
     ELSE IF Valid(r) /\ NoChange(r) THEN
          /\ doneOps' = doneOps \cup {r.op}
          /\ Settle(r, Len(log), FALSE)
          /\ UNCHANGED <<layout, alive, wsOf, closed, created, log, inbox, rejectedOps,
                         usedPanes, usedWs>>
     ELSE IF Valid(r) THEN
          /\ ApplyOk(r)
          /\ doneOps' = doneOps \cup {r.op}
          /\ Settle(r, Len(log) + 1, FALSE)
          /\ UNCHANGED rejectedOps
     ELSE /\ doneOps' = doneOps \cup {r.op}
          /\ rejectedOps' = rejectedOps \cup {r.op}
          /\ Settle(r, Len(log), TRUE)
          /\ UNCHANGED <<layout, alive, wsOf, closed, created, log, inbox, usedPanes, usedWs>>
  /\ UNCHANGED <<faults, clientVars, opCount>>

-----------------------------------------------------------------------------
(* Client: receiving *)

\* End intent op. newMirror is the mirror after this step (for BUGGY_DETACH).
EndIntents(c, ops, newMirror) ==
  /\ pending' = [pending EXCEPT ![c] = SelectSeq(@, LAMBDA m : m.op \notin ops)]
  /\ LET ended == {l \in landing[c] : l.op \in ops}
         \* bug: release only when the mirror removed the tab from its source strip
         kept  == IF BUGGY_DETACH
                  THEN {l.tab : l \in {x \in ended : Contains(newMirror[x.src], x.tab)}}
                  ELSE {}
     IN /\ landing' = [landing EXCEPT ![c] = @ \ ended]
        /\ hidden' = [hidden EXCEPT ![c] = @ \ ({l.tab : l \in ended} \ kept)]
  /\ UNCHANGED dragging

\* Fold a batch's events into <<layout, alive, ws>>.
ApplyEvent(st, e) ==
  LET lay == st[1]  live == st[2]  ws == st[3] IN
  CASE e.kind = "WorkspaceAdded" -> st
    [] e.kind = "PaneAdded"  ->
         <<[lay EXCEPT ![e.pane] = <<>>], live \cup {e.pane}, [ws EXCEPT ![e.pane] = e.ws]>>
    [] e.kind = "TabChanged" ->
         <<IF HasTab(lay, live, e.tab) THEN MoveIn(lay, live, e.tab, e.pane, e.idx)
           ELSE [lay EXCEPT ![e.pane] = InsertAt(@, Min(e.idx, Len(@) + 1), e.tab)],
           live, ws>>
    [] e.kind = "TabClosed"  -> <<[p \in Panes |-> Remove(lay[p], e.tab)], live, ws>>
    [] e.kind = "PaneClosed" ->
         <<[lay EXCEPT ![e.pane] = <<>>], live \ {e.pane}, [ws EXCEPT ![e.pane] = 0]>>

RECURSIVE Fold(_, _)
Fold(st, es) == IF es = <<>> THEN st ELSE Fold(ApplyEvent(st, Head(es)), Tail(es))

RECURSIVE Unknown(_, _)
\* A TabChanged / PaneClosed naming a pane the mirror does not know.
Unknown(live, es) ==
  IF es = <<>> THEN FALSE
  ELSE LET e == Head(es) IN
       \/ (e.kind \in {"TabChanged", "PaneClosed"} /\ e.pane \notin live)
       \/ Unknown(IF e.kind = "PaneAdded" THEN live \cup {e.pane} ELSE live, Tail(es))

Snapshot(c) ==
  /\ mirror' = [mirror EXCEPT ![c] = layout]
  /\ mirrorAlive' = [mirrorAlive EXCEPT ![c] = alive]
  /\ mirrorWs' = [mirrorWs EXCEPT ![c] = wsOf]
  /\ applied' = [applied EXCEPT ![c] = Len(log)]
  /\ EndIntents(c, doneOps, layout)

ApplyBatch(c, s) ==
  LET st == Fold(<<mirror[c], mirrorAlive[c], mirrorWs[c]>>, log[s].events) IN
  /\ mirror' = [mirror EXCEPT ![c] = st[1]]
  /\ mirrorAlive' = [mirrorAlive EXCEPT ![c] = st[2]]
  /\ mirrorWs' = [mirrorWs EXCEPT ![c] = st[3]]
  /\ applied' = [applied EXCEPT ![c] = s]
  /\ EndIntents(c, {log[s].op}, st[1])           \* echo

Receive(c, s) ==
  /\ inbox' = [inbox EXCEPT ![c] = @ \ {s}]
  /\ IF s <= applied[c] THEN UNCHANGED clientVars          \* duplicate / stale
     ELSE IF s = applied[c] + 1 /\ ~Unknown(mirrorAlive[c], log[s].events)
     THEN ApplyBatch(c, s) /\ UNCHANGED stale
     ELSE Snapshot(c) /\ UNCHANGED stale                     \* gap or unknown pane
  /\ UNCHANGED <<ownerVars, requests, replies, faults, opCount>>

\* request-settled: a reject ends the intent; otherwise the write barrier
\* holds the settle until the mirror has applied its sequence.
ReceiveSettled(c, m) ==
  /\ m.rej \/ applied[c] >= m.seq
  /\ replies' = [replies EXCEPT ![c] = @ \ {m}]
  /\ EndIntents(c, {m.op}, mirror[c])
  /\ UNCHANGED <<ownerVars, requests, inbox, faults, mirror, mirrorAlive, mirrorWs,
                 applied, stale, opCount>>

\* Reconnect: snapshot, then resend every still-pending intent with its key.
Reconnect(c) ==
  /\ stale[c]
  /\ Snapshot(c)
  /\ stale' = [stale EXCEPT ![c] = FALSE]
  /\ requests' = requests \cup {pending[c][k] : k \in {j \in DOMAIN pending[c] :
                                                       pending[c][j].op \notin doneOps}}
  /\ UNCHANGED <<ownerVars, inbox, replies, faults, opCount>>

-----------------------------------------------------------------------------
(* Faults, bounded together *)

DuplicateBatch(c, s) ==
  /\ faults < MaxFaults /\ ~stale[c]
  /\ s <= applied[c] /\ s \notin inbox[c]
  /\ inbox' = [inbox EXCEPT ![c] = @ \cup {s}]
  /\ faults' = faults + 1
  /\ UNCHANGED <<ownerVars, requests, replies, clientVars, opCount>>

ReplayRequest(c, k) ==
  /\ faults < MaxFaults /\ ~stale[c]
  /\ requests' = requests \cup {pending[c][k]}
  /\ faults' = faults + 1
  /\ UNCHANGED <<ownerVars, inbox, replies, clientVars, opCount>>

Disconnect(c) ==
  /\ faults < MaxFaults /\ ~stale[c]
  /\ stale' = [stale EXCEPT ![c] = TRUE]
  /\ inbox' = [inbox EXCEPT ![c] = {}]
  /\ replies' = [replies EXCEPT ![c] = {}]
  /\ dragging' = [dragging EXCEPT ![c] = NoDrag]   \* connection lost ends the drag
  /\ landing' = [landing EXCEPT ![c] = {}]        \* and its landings
  /\ hidden' = [hidden EXCEPT ![c] = @ \ HeldTab(c)]
  /\ \/ UNCHANGED requests                        \* in-flight requests survive ...
     \/ requests' = {r \in requests : r.client # c} \* ... or are lost
  /\ faults' = faults + 1
  /\ UNCHANGED <<ownerVars, mirror, mirrorAlive, mirrorWs, applied, pending, opCount>>

\* Owner restart: committed state and the replay record are durable;
\* in-flight requests and messages are lost; every client reconnects.
OwnerRestart ==
  /\ faults < MaxFaults
  /\ requests' = {}
  /\ inbox' = [c \in Clients |-> {}]
  /\ replies' = [c \in Clients |-> {}]
  /\ stale' = [c \in Clients |-> TRUE]
  /\ dragging' = [c \in Clients |-> NoDrag]      \* connection lost ends drags
  /\ landing' = [c \in Clients |-> {}]
  /\ hidden' = [c \in Clients |-> hidden[c] \ HeldTab(c)]
  /\ faults' = faults + 1
  /\ UNCHANGED <<ownerVars, mirror, mirrorAlive, mirrorWs, applied, pending, opCount>>

-----------------------------------------------------------------------------
UserNext ==
  \E c \in Clients :
     \/ \E t \in AllTabs : StartDrag(c, t) \/ CloseTab(c, t)
     \/ CancelDrag(c)
     \/ \E p \in Panes : DropSplit(c, p) \/ \E i \in 1..(NTabs + NSpawn) : DropMove(c, p, i)
     \/ DropTearOff(c)

SystemNext ==
  \/ \E r \in requests : OwnerApply(r)
  \/ \E c \in Clients :
       \/ \E s \in inbox[c] : Receive(c, s)
       \/ \E m \in replies[c] : ReceiveSettled(c, m)
       \/ Reconnect(c)

FaultNext ==
  \/ OwnerRestart
  \/ \E c \in Clients :
       \/ Disconnect(c)
       \/ \E s \in 1..Len(log) : DuplicateBatch(c, s)
       \/ \E k \in DOMAIN pending[c] : ReplayRequest(c, k)

Next == UserNext \/ SystemNext \/ FaultNext

Fairness ==
  /\ WF_vars(\E r \in requests : OwnerApply(r))
  /\ \A c \in Clients :
       /\ WF_vars(\E s \in inbox[c] : Receive(c, s))
       /\ WF_vars(\E m \in replies[c] : ReceiveSettled(c, m))
       /\ WF_vars(Reconnect(c))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* Owner invariants. Names follow layout-invariants.md (I1-I4, P1, DP1)
   and OWNERSHIP-PRINCIPLES.md 4-6 (Convergence, Idempotency,
   ConcurrentSerializable). *)

LiveTabs == (Tabs \cup created) \ closed

\* I1: no op but Close changes the set of tabs, and no op but SplitRespawn
\* adds one (explicitly, with a never-used id).
I1_TabConservation ==
  /\ UNION {Range(layout[p]) : p \in alive} = LiveTabs
  /\ created \subseteq SpawnTabs

\* I2: every tab is in exactly one pane, once.
I2_ExactlyOnePane ==
  /\ \A t \in LiveTabs : Cardinality({p \in alive : Contains(layout[p], t)}) = 1
  /\ \A p \in alive : Len(layout[p]) = Cardinality(Range(layout[p]))
  /\ \A p \in Panes \ alive : layout[p] = <<>> /\ wsOf[p] = 0

\* I3: every pane has a tab and every workspace a pane, or it is removed in
\* the same transaction. A workspace is the set of panes mapped to it, so
\* "every workspace has a pane" is "every alive pane maps to a workspace".
I3_NoEmptyPaneOrWorkspace ==
  /\ \A p \in alive : Len(layout[p]) > 0
  /\ \A p \in alive : wsOf[p] \in Workspaces

\* I4: a drop on the tab's own place sends nothing (action property).
\* Own place is defined by effect, not by the resolver's own condition: a
\* move whose result equals the visible layout, or a split of the tab's own
\* pane when it is the only tab (with RESPAWN that split is the real op
\* SplitRespawn, not an own place).
OwnPlaceMove(c, p, i) ==
  LET t == dragging[c].tab  v == Visible(c) IN
  /\ Dragging(c) /\ p \in mirrorAlive[c] /\ HasTab(v, mirrorAlive[c], t)
  /\ MoveIn(v, mirrorAlive[c], t, p, i) = v
OwnSplit(c, p) ==
  LET t == dragging[c].tab  v == Visible(c) IN
  /\ ~RESPAWN /\ Dragging(c) /\ HasTab(v, mirrorAlive[c], t)
  /\ PaneOf(v, mirrorAlive[c], t) = p /\ Len(v[p]) = 1
I4_OwnPlaceNoOp ==
  [][\A c \in Clients : \A p \in Panes :
       /\ \A i \in 1..(NTabs + NSpawn) : (OwnPlaceMove(c, p, i) /\ DropMove(c, p, i))
                             => UNCHANGED <<requests, pending, opCount>>
       /\ (OwnSplit(c, p) /\ DropSplit(c, p)) => UNCHANGED <<requests, pending, opCount>>]_vars

\* P1: once a transaction's events are applied (echo, barrier or snapshot),
\* the client's mirror equals the owner's tree for that transaction.
TreeAt(s) == IF s = 0 THEN [lay |-> InitLayout, live |-> InitAlive, ws |-> InitWs]
             ELSE log[s].tree
P1_Projection ==
  \A c \in Clients :
    LET tr == TreeAt(applied[c]) IN
    /\ mirrorAlive[c] = tr.live
    /\ \A p \in tr.live : mirror[c][p] = tr.lay[p] /\ mirrorWs[c][p] = tr.ws[p]

\* Principle 4 (Convergence): with an empty intent log and nothing queued,
\* a connected client's visible state equals the owner's.
Convergence ==
  \A c \in Clients :
    (~stale[c] /\ pending[c] = <<>> /\ inbox[c] = {}) =>
      /\ mirrorAlive[c] = alive
      /\ \A p \in alive : Visible(c)[p] = layout[p] /\ mirrorWs[c][p] = wsOf[p]

\* The visible state never shows a tab twice.
VisibleNoDuplicate ==
  \A c \in Clients : \A t \in AllTabs :
    Cardinality({pk \in mirrorAlive[c] \X (1..(NTabs + NSpawn)) :
                   pk[2] \in DOMAIN Visible(c)[pk[1]] /\ Visible(c)[pk[1]][pk[2]] = t}) <= 1

\* DP1: a strip hides a tab only while the drag or landing that holds it is
\* in flight, so with none in flight every strip shows exactly its pane's
\* tabs (state part) ...
DP1_DragPresentation == \A c \in Clients : hidden[c] = HeldTab(c)

\* ... and every end (cancel, reject, landed, connection lost) releases its
\* tab in the same step, exactly once: a tab is shown again only when its
\* hold ends, and a hold that ends shows its tab (action part).
DP1_EndsExactlyOnce ==
  [][\A c \in Clients : \A t \in AllTabs :
       /\ (t \in hidden[c] /\ t \notin hidden'[c]) => (t \in HeldTab(c) /\ t \notin HeldTab(c)')
       /\ (t \in HeldTab(c) /\ t \notin HeldTab(c)') => t \notin hidden'[c]]_vars

\* Principle 5 (Idempotency): each key commits at most one batch, and a
\* replayed key has no further effect (action property). Both restate the
\* owner's dedup and serve as mutation guards (removing the doneOps check
\* fails IdempotentReplay at depth 6).
Idempotency == \A s1, s2 \in DOMAIN log : log[s1].op = log[s2].op => s1 = s2
IdempotentReplay ==
  [][\A r \in requests :
       (r.op \in doneOps /\ OwnerApply(r)) => UNCHANGED ownerVars]_vars

\* Principle 6 (ConcurrentSerializable): ops from both clients serialize on
\* one owner log into valid states (I1-I3 hold in every state), and no
\* client loses an acknowledged op: once an accepted intent has left its
\* client's log, its batch is in that client's mirror; a settle never names
\* a sequence before its own batch (mutation guard). Removing the write
\* barrier fails the first conjunct at depth 5.
ConcurrentSerializable ==
  /\ \A c \in Clients : \A s \in DOMAIN log :
       (log[s].client = c /\ log[s].op \notin PendingOps(c)) => s <= applied[c]
  /\ \A c \in Clients : \A m \in replies[c] : \A s \in DOMAIN log :
       (~m.rej /\ log[s].op = m.op) => s <= m.seq

(* Convergence *)

Quiescent ==
  /\ requests = {}
  /\ \A c \in Clients : ~stale[c] /\ inbox[c] = {} /\ replies[c] = {}
                        /\ ~Dragging(c) /\ landing[c] = {} /\ pending[c] = <<>>

Converged ==
  \A c \in Clients :
    /\ mirrorAlive[c] = alive
    /\ \A p \in alive : Visible(c)[p] = layout[p] /\ mirrorWs[c][p] = wsOf[p]
    /\ hidden[c] = {}

QuiescentConvergence == Quiescent => Converged

\* Liveness under fairness of system actions only (no assumption that a user
\* ends a gesture). A drag the user still holds is allowed: infinitely often every request,
\* batch, settle and reconnect is done, no drag waits on an intent, and
\* every projection equals the owner apart from a held drag's hidden tab.
SystemQuiescent ==
  /\ requests = {}
  /\ \A c \in Clients : ~stale[c] /\ inbox[c] = {} /\ replies[c] = {}
                        /\ pending[c] = <<>> /\ landing[c] = {}

ConvergedModuloHeldDrag ==
  \A c \in Clients :
    /\ mirrorAlive[c] = alive
    /\ \A p \in alive : Visible(c)[p] = layout[p] /\ mirrorWs[c][p] = wsOf[p]
    /\ hidden[c] = HeldTab(c)

EventuallyConverged == []<>(SystemQuiescent /\ ConvergedModuloHeldDrag)
=============================================================================
