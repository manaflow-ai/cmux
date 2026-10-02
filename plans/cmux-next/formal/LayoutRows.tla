------------------------------ MODULE LayoutRows ------------------------------
(***************************************************************************)
(* Rows in the workspace-store layout (plans/cmux-next/rows.md): one      *)
(* screen is a strip of columns, each column a strip of rows, each row a   *)
(* sequence of panes (its split tree, geometry abstracted), each pane a    *)
(* sequence of tabs. Rows have a height in 1..MaxH units (MaxH stands for  *)
(* 1000 permille). Columns may be sticky (left or right).                  *)
(*                                                                         *)
(* Owner (workspace store) applies typed ops with a pure reducer: split,   *)
(* new column, new row, move tab to a pane, move tab to a new row (with    *)
(* the spawn-same-kind variant), close tab, set row height, set sticky.    *)
(* A rejected op changes nothing. A container that empties is removed in   *)
(* the same step, bottom up (pane, row, column), and sticky flags are      *)
(* normalized after a column removal. New ids are fresh and never reused.  *)
(* Every op carries a key; a replayed key changes nothing.                 *)
(*                                                                         *)
(* Clients build ops from their own mirror, which may be stale (another    *)
(* client's op landed first), so ops can name removed panes, rows or tabs; *)
(* the owner validates against its own state. A client's mirror is         *)
(* refreshed from the owner (snapshot) and its view state (focused pane,   *)
(* top row per column) is repaired in the same step with the close-focus   *)
(* rule of rows.md N3. The owner never reads client view state.           *)
(*                                                                         *)
(* The protocol under this (intent log, echo, request-settled, reorder,    *)
(* reconnect) is checked by TabLayout.tla and OwnershipConvergence.tla;    *)
(* this model checks the structure the row ops produce.                    *)
(*                                                                         *)
(* BUG selects one deliberate defect; every value other than "none" must   *)
(* produce a counterexample.                                               *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS NTabs, NPanes, NRows, NCols, NClients, MaxOps, MaxReplays, MaxH, BUG, START

TabIds  == 1..NTabs
PaneIds == 1..NPanes
RowIds  == 1..NRows
ColIds  == 1..NCols
Clients == 1..NClients
Heights == 1..MaxH
Edges   == {"none", "left", "right"}

ASSUME BUG \in {"none", "keepEmptyRow", "noStickyNormalize", "ownPlaceRowOnly",
                "noDedup", "noFocusRepair", "focusColumnFirst", "respawnDropsTab"}
\* START "one": one column, one row, two panes (a split screen; the daemon keeps
\* a screen with one column and one row as a split tree, which this model
\* represents as that one column and row). "sticky3": three columns of one
\* row and one pane each, the first sticky left and the last sticky right,
\* so removing the middle column leaves only sticky columns.
ASSUME START \in {"one", "sticky3"}

\* --------------------------------------------------------------------------
\* Sequence helpers
Range(s) == {s[i] : i \in DOMAIN s}
Remove(s, x) == SelectSeq(s, LAMBDA y : y # x)
IndexOf(s, x) == CHOOSE i \in DOMAIN s : s[i] = x
InsertAt(s, i, x) == SubSeq(s, 1, i - 1) \o <<x>> \o SubSeq(s, i, Len(s))
Min(S) == CHOOSE x \in S : \A y \in S : x <= y
Max(S) == CHOOSE x \in S : \A y \in S : x >= y

\* --------------------------------------------------------------------------
\* Layout states (records). Unused ids map to empty contents.
Empty == [cols |-> <<>>,
          rowsOf |-> [c \in ColIds |-> <<>>],
          panesOf |-> [r \in RowIds |-> <<>>],
          tabsOf |-> [p \in PaneIds |-> <<>>],
          height |-> [r \in RowIds |-> 0],
          sticky |-> [c \in ColIds |-> "none"],
          usedT |-> {}, usedP |-> {}, usedR |-> {}, usedC |-> {}, closed |-> {}]

InitOne == [Empty EXCEPT !.cols = <<1>>, !.rowsOf[1] = <<1>>, !.panesOf[1] = <<1, 2>>,
                         !.tabsOf[1] = <<1>>, !.tabsOf[2] = <<2>>, !.height[1] = MaxH,
                         !.usedT = {1, 2}, !.usedP = {1, 2}, !.usedR = {1}, !.usedC = {1}]
InitSticky3 ==
  [Empty EXCEPT !.cols = <<1, 2, 3>>,
                !.rowsOf = [c \in ColIds |-> IF c \in 1..3 THEN <<c>> ELSE <<>>],
                !.panesOf = [r \in RowIds |-> IF r \in 1..3 THEN <<r>> ELSE <<>>],
                !.tabsOf = [p \in PaneIds |-> IF p \in 1..3 THEN <<p>> ELSE <<>>],
                !.height = [r \in RowIds |-> IF r \in 1..3 THEN MaxH ELSE 0],
                !.sticky = [c \in ColIds |-> IF c = 1 THEN "left" ELSE IF c = 3 THEN "right" ELSE "none"],
                !.usedT = {1, 2, 3}, !.usedP = {1, 2, 3}, !.usedR = {1, 2, 3}, !.usedC = {1, 2, 3}]
Init0 == IF START = "one" THEN InitOne ELSE InitSticky3
InitTabSet == Init0.usedT

LiveCols(S)  == Range(S.cols)
LiveRows(S)  == UNION {Range(S.rowsOf[c]) : c \in LiveCols(S)}
LivePanes(S) == UNION {Range(S.panesOf[r]) : r \in LiveRows(S)}
LiveTabs(S)  == UNION {Range(S.tabsOf[p]) : p \in LivePanes(S)}

ColOfRow(S, r)  == CHOOSE c \in LiveCols(S) : r \in Range(S.rowsOf[c])
RowOfPane(S, p) == CHOOSE r \in LiveRows(S) : p \in Range(S.panesOf[r])
PaneOfTab(S, t) == CHOOSE p \in LivePanes(S) : t \in Range(S.tabsOf[p])

\* What a user sees, ids of panes, rows and columns erased (tab ids kept).
Sig(S) == [i \in 1..Len(S.cols) |->
             LET c == S.cols[i] IN
             <<S.sticky[c],
               [j \in 1..Len(S.rowsOf[c]) |->
                  LET r == S.rowsOf[c][j] IN
                  <<S.height[r], [k \in 1..Len(S.panesOf[r]) |-> S.tabsOf[S.panesOf[r][k]]]>>]>>]

Fresh(used, pool) == Min(pool \ used)
HasFresh(used, pool) == pool \ used # {}

\* Sticky normalization after a column removal (sticky-column.md): with fewer
\* than two columns, or only sticky columns, nothing is sticky.
Normalize(S) ==
  IF BUG = "noStickyNormalize" THEN S
  ELSE IF Len(S.cols) < 2 \/ \A c \in LiveCols(S) : S.sticky[c] # "none"
       THEN [S EXCEPT !.sticky = [c \in ColIds |-> "none"]]
       ELSE S

\* Remove pane p (already without tabs) and cascade: row, then column.
RemovePane(S, p) ==
  LET r  == RowOfPane(S, p)
      c  == ColOfRow(S, r)
      S1 == [S EXCEPT !.panesOf[r] = Remove(@, p)]
      S2 == IF S1.panesOf[r] = <<>> /\ BUG # "keepEmptyRow"
            THEN [S1 EXCEPT !.rowsOf[c] = Remove(@, r), !.height[r] = 0]
            ELSE S1
  IN IF S2.rowsOf[c] = <<>>
     THEN Normalize([S2 EXCEPT !.cols = Remove(@, c), !.sticky[c] = "none"])
     ELSE S2

\* Take tab t out of its pane; an emptied pane is removed.
TakeTab(S, t) ==
  LET p  == PaneOfTab(S, t)
      S1 == [S EXCEPT !.tabsOf[p] = Remove(@, t)]
  IN IF S1.tabsOf[p] = <<>> THEN RemovePane(S1, p) ELSE S1

\* --------------------------------------------------------------------------
\* Ops: one record shape for every kind (unused fields are 0 / FALSE / "none").
\* b: insert the new row before the anchor's row (top boundary); rows: the
\* column's row set the client saw (SetRowHeights rejects a stale set).
Op(k, t, p, c, h, e, rs, b, rows) ==
  [k |-> k, t |-> t, p |-> p, c |-> c, h |-> h, e |-> e, rs |-> rs, b |-> b, rows |-> rows]

OpsFrom(M) ==
     {Op("split", 0, p, 0, 0, "none", FALSE, FALSE, {}) : p \in LivePanes(M)}
  \cup {Op("newcol", 0, p, 0, h, "none", FALSE, FALSE, {}) : p \in LivePanes(M), h \in Heights}
  \cup {Op("newrow", 0, p, 0, h, "none", FALSE, FALSE, {}) : p \in LivePanes(M), h \in Heights}
  \cup {Op("move", t, p, 0, 0, "none", FALSE, FALSE, {}) : t \in LiveTabs(M), p \in LivePanes(M)}
  \cup {Op("torow", t, p, 0, h, "none", rs, b, {}) : t \in LiveTabs(M), p \in LivePanes(M),
                                                    h \in Heights, rs \in BOOLEAN, b \in BOOLEAN}
  \cup {Op("close", t, 0, 0, 0, "none", FALSE, FALSE, {}) : t \in LiveTabs(M)}
  \cup {Op("heights", 0, 0, c, h, "none", FALSE, FALSE, Range(M.rowsOf[c])) : c \in LiveCols(M), h \in Heights}
  \cup {Op("sticky", 0, 0, c, 0, e, FALSE, FALSE, {}) : c \in LiveCols(M), e \in Edges}

Reject == [ok |-> FALSE, noop |-> FALSE, s |-> Empty]
Done(S) == [ok |-> TRUE, noop |-> FALSE, s |-> S]
NoOp(S) == [ok |-> TRUE, noop |-> TRUE, s |-> S]

\* Where the new row goes in the anchor's column: before or after the anchor's row.
Slot(S, op) == LET aRow == RowOfPane(S, op.p) IN
               IndexOf(S.rowsOf[ColOfRow(S, aRow)], aRow) + (IF op.b THEN 0 ELSE 1)

\* The row move without its own-place rule: insert a new row at the slot
\* holding t, then take t out of its source pane (respawn keeps the source
\* pane with a new tab of the same kind).
RowMoveRaw(S, op) ==
  LET t   == op.t
      src == PaneOfTab(S, t)
      aRow == RowOfPane(S, op.p)
      c   == ColOfRow(S, aRow)
      nr  == Fresh(S.usedR, RowIds)
      np  == Fresh(S.usedP, PaneIds)
      nt  == Fresh(S.usedT, TabIds)
      dropBug == op.rs /\ BUG = "respawnDropsTab"
      S1  == [S EXCEPT !.tabsOf[src] = IF op.rs /\ ~dropBug THEN <<nt>> ELSE Remove(@, t),
                       !.usedT = IF op.rs THEN @ \cup {nt} ELSE @]
      S2  == [S1 EXCEPT !.rowsOf[c] = InsertAt(@, Slot(S, op), nr),
                        !.panesOf[nr] = <<np>>,
                        !.tabsOf[np] = IF dropBug THEN <<nt>> ELSE <<t>>,
                        !.height[nr] = op.h,
                        !.usedR = @ \cup {nr}, !.usedP = @ \cup {np}]
  IN IF S2.tabsOf[src] = <<>> THEN RemovePane(S2, src) ELSE S2

RowMoveIdsOk(S, op) ==
  HasFresh(S.usedR, RowIds) /\ HasFresh(S.usedP, PaneIds)
  /\ (op.rs => HasFresh(S.usedT, TabIds))

\* Own place (rows.md R6): the pane's only tab, its row's only pane, dropped
\* on either boundary of its own row (slot j or j + 1 where j is the own
\* row's index) in its own column, at the same height, without respawn.
RowOwnPlace(S, op) ==
  LET src == PaneOfTab(S, op.t)
      sRow == RowOfPane(S, src)
      aRow == RowOfPane(S, op.p)
      c == ColOfRow(S, sRow)
      j == IndexOf(S.rowsOf[c], sRow)
  IN /\ ~op.rs
     /\ Len(S.tabsOf[src]) = 1
     /\ S.panesOf[sRow] = <<src>>
     /\ op.h = S.height[sRow]
     /\ aRow \in Range(S.rowsOf[c])
     /\ IF BUG = "ownPlaceRowOnly" THEN Slot(S, op) = j + 1 ELSE Slot(S, op) \in {j, j + 1}

Apply(S, op) ==
  CASE op.k = "split" ->
        IF op.p \notin LivePanes(S) \/ ~HasFresh(S.usedP, PaneIds) \/ ~HasFresh(S.usedT, TabIds)
        THEN Reject
        ELSE LET r == RowOfPane(S, op.p)
                 np == Fresh(S.usedP, PaneIds)
                 nt == Fresh(S.usedT, TabIds)
             IN Done([S EXCEPT !.panesOf[r] = InsertAt(@, IndexOf(@, op.p) + 1, np),
                               !.tabsOf[np] = <<nt>>, !.usedP = @ \cup {np}, !.usedT = @ \cup {nt}])
    [] op.k = "newcol" ->
        IF op.p \notin LivePanes(S) \/ ~HasFresh(S.usedC, ColIds) \/ ~HasFresh(S.usedR, RowIds)
           \/ ~HasFresh(S.usedP, PaneIds) \/ ~HasFresh(S.usedT, TabIds)
        THEN Reject
        ELSE LET c0 == ColOfRow(S, RowOfPane(S, op.p))
                 nc == Fresh(S.usedC, ColIds)
                 nr == Fresh(S.usedR, RowIds)
                 np == Fresh(S.usedP, PaneIds)
                 nt == Fresh(S.usedT, TabIds)
             IN Done([S EXCEPT !.cols = InsertAt(@, IndexOf(@, c0) + 1, nc),
                               !.rowsOf[nc] = <<nr>>, !.panesOf[nr] = <<np>>, !.tabsOf[np] = <<nt>>,
                               !.height[nr] = op.h,
                               !.usedC = @ \cup {nc}, !.usedR = @ \cup {nr},
                               !.usedP = @ \cup {np}, !.usedT = @ \cup {nt}])
    [] op.k = "newrow" ->
        IF op.p \notin LivePanes(S) \/ ~HasFresh(S.usedR, RowIds)
           \/ ~HasFresh(S.usedP, PaneIds) \/ ~HasFresh(S.usedT, TabIds)
        THEN Reject
        ELSE LET r0 == RowOfPane(S, op.p)
                 c0 == ColOfRow(S, r0)
                 nr == Fresh(S.usedR, RowIds)
                 np == Fresh(S.usedP, PaneIds)
                 nt == Fresh(S.usedT, TabIds)
             IN Done([S EXCEPT !.rowsOf[c0] = InsertAt(@, IndexOf(@, r0) + 1, nr),
                               !.panesOf[nr] = <<np>>, !.tabsOf[np] = <<nt>>, !.height[nr] = op.h,
                               !.usedR = @ \cup {nr}, !.usedP = @ \cup {np}, !.usedT = @ \cup {nt}])
    [] op.k = "move" ->
        IF op.t \notin LiveTabs(S) \/ op.p \notin LivePanes(S) THEN Reject
        ELSE LET src == PaneOfTab(S, op.t) IN
             IF src = op.p
             THEN IF S.tabsOf[src][Len(S.tabsOf[src])] = op.t THEN NoOp(S)
                  ELSE Done([S EXCEPT !.tabsOf[src] = Remove(@, op.t) \o <<op.t>>])
             ELSE LET S1 == TakeTab(S, op.t)
                  IN Done([S1 EXCEPT !.tabsOf[op.p] = @ \o <<op.t>>])
    [] op.k = "torow" ->
        IF op.t \notin LiveTabs(S) \/ op.p \notin LivePanes(S) THEN Reject
        ELSE IF op.rs /\ Len(S.tabsOf[PaneOfTab(S, op.t)]) # 1 THEN Reject
        ELSE IF RowOwnPlace(S, op) THEN NoOp(S)
        ELSE IF ~RowMoveIdsOk(S, op) THEN Reject
        ELSE Done(RowMoveRaw(S, op))
    [] op.k = "close" ->
        IF op.t \notin LiveTabs(S) THEN Reject
        ELSE LET S1 == TakeTab(S, op.t) IN Done([S1 EXCEPT !.closed = @ \cup {op.t}])
    [] op.k = "heights" ->
        \* SetRowHeights: the client names the whole row set it saw; a stale set is refused.
        IF op.c \notin LiveCols(S) \/ op.rows # Range(S.rowsOf[op.c]) THEN Reject
        ELSE IF \A r \in op.rows : S.height[r] = op.h THEN NoOp(S)
        ELSE Done([S EXCEPT !.height = [r \in RowIds |-> IF r \in op.rows THEN op.h ELSE @[r]]])
    [] op.k = "sticky" ->
        IF op.c \notin LiveCols(S) THEN Reject
        ELSE IF S.sticky[op.c] = op.e THEN NoOp(S)
        ELSE LET st == [c \in ColIds |->
                          IF c = op.c THEN op.e
                          ELSE IF op.e # "none" /\ S.sticky[c] = op.e THEN "none"
                          ELSE S.sticky[c]]
             IN IF \E c \in LiveCols(S) : st[c] = "none"
                THEN Done([S EXCEPT !.sticky = st])
                ELSE Reject

\* --------------------------------------------------------------------------
\* Client view repair (rows.md N3): previous pane in the row, else the row
\* above, else the row below, else the column to the left, else the first
\* column. M is the mirror the client had, N the new one.
FirstPane(N, c) == N.panesOf[N.rowsOf[c][1]][1]

Successor(M, N, f) ==
  IF LivePanes(N) = {} THEN 0
  ELSE IF f \in LivePanes(N) THEN f
  ELSE IF f = 0 \/ f \notin LivePanes(M) THEN FirstPane(N, N.cols[1])
  ELSE
    LET r  == RowOfPane(M, f)
        c  == ColOfRow(M, r)
        ps == M.panesOf[r]
        rs == M.rowsOf[c]
        i  == IndexOf(ps, f)
        j  == IndexOf(rs, r)
        prevInRow  == {k \in 1..(i - 1) : ps[k] \in LivePanes(N)}
        nextInRow  == {k \in (i + 1)..Len(ps) : ps[k] \in LivePanes(N)}
        above      == {k \in 1..(j - 1) : rs[k] \in LiveRows(N)}
        below      == {k \in (j + 1)..Len(rs) : rs[k] \in LiveRows(N)}
        left       == {k \in 1..(IndexOf(M.cols, c) - 1) : M.cols[k] \in LiveCols(N)}
    IN IF prevInRow # {} THEN ps[Max(prevInRow)]
       ELSE IF nextInRow # {} THEN ps[Min(nextInRow)]
       ELSE IF BUG = "focusColumnFirst" /\ left # {} THEN FirstPane(N, M.cols[Max(left)])
       ELSE IF above # {} THEN N.panesOf[rs[Max(above)]][1]
       ELSE IF below # {} THEN N.panesOf[rs[Min(below)]][1]
       ELSE IF c \in LiveCols(N) THEN FirstPane(N, c)
       ELSE IF left # {} THEN FirstPane(N, M.cols[Max(left)])
       ELSE FirstPane(N, N.cols[1])

RepairTop(N, top, f) ==
  [c \in ColIds |->
     IF c \notin LiveCols(N) THEN 0
     ELSE IF f \in LivePanes(N) /\ ColOfRow(N, RowOfPane(N, f)) = c THEN RowOfPane(N, f)
     ELSE IF top[c] \in Range(N.rowsOf[c]) THEN top[c]
     ELSE N.rowsOf[c][1]]

\* --------------------------------------------------------------------------
VARIABLES own, req, done, commits, opCount, replays, mirror, focus, top, audit

vars == <<own, req, done, commits, opCount, replays, mirror, focus, top, audit>>

TopOf(S, f) == [c \in ColIds |-> IF c \in LiveCols(S) THEN S.rowsOf[c][1] ELSE 0]

Init ==
  /\ own = Init0
  /\ req = {}
  /\ done = {}
  /\ commits = [k \in 1..MaxOps |-> 0]
  /\ opCount = 0
  /\ replays = 0
  /\ mirror = [c \in Clients |-> Init0]
  /\ focus = [c \in Clients |-> 1]
  /\ top = [c \in Clients |-> TopOf(Init0, 1)]
  /\ audit = [noopSound |-> TRUE, local |-> TRUE]

\* A client issues an op built from its (possibly stale) mirror.
Issue(cl) ==
  /\ opCount < MaxOps
  /\ \E op \in OpsFrom(mirror[cl]) :
       req' = req \cup {[key |-> opCount + 1, cl |-> cl, op |-> op]}
  /\ opCount' = opCount + 1
  /\ UNCHANGED <<own, done, commits, replays, mirror, focus, top, audit>>

\* The owner processes one request.
Process ==
  \E q \in req :
    /\ req' = req \ {q}
    /\ done' = done \cup {q}
    /\ IF q \in done /\ BUG # "noDedup"
       THEN UNCHANGED <<own, commits, audit>>
       ELSE LET res == Apply(own, q.op)
                raw == IF q.op.k = "torow" /\ res.noop /\ RowMoveIdsOk(own, q.op)
                       THEN RowMoveRaw(own, q.op) ELSE own
            IN /\ own' = IF res.ok THEN res.s ELSE own
               /\ commits' = IF res.ok /\ ~res.noop
                             THEN [commits EXCEPT ![q.key] = @ + 1] ELSE commits
               /\ audit' = [audit EXCEPT !.noopSound = @ /\ Sig(raw) = Sig(own)]
    /\ UNCHANGED <<opCount, replays, mirror, focus, top>>

\* A request with an already used key arrives again (retry after reconnect).
Replay ==
  /\ replays < MaxReplays
  /\ \E q \in done : req' = req \cup {q}
  /\ replays' = replays + 1
  /\ UNCHANGED <<own, done, commits, opCount, mirror, focus, top, audit>>

\* A client adopts the owner's state and repairs its view in the same step.
Sync(cl) ==
  /\ mirror[cl] # own
  /\ LET M == mirror[cl]
         f == focus[cl]
         nf == IF BUG = "noFocusRepair" THEN f ELSE Successor(M, own, f)
         oldCol == IF f \in LivePanes(M) THEN ColOfRow(M, RowOfPane(M, f)) ELSE 0
         stayLocal == oldCol \in LiveCols(own) /\ f \notin LivePanes(own)
     IN /\ mirror' = [mirror EXCEPT ![cl] = own]
        /\ focus' = [focus EXCEPT ![cl] = nf]
        /\ top' = [top EXCEPT ![cl] = IF BUG = "noFocusRepair" THEN @ ELSE RepairTop(own, @, nf)]
        /\ audit' = [audit EXCEPT !.local =
                       @ /\ (stayLocal /\ nf \in LivePanes(own)
                             => ColOfRow(own, RowOfPane(own, nf)) = oldCol)]
  /\ UNCHANGED <<own, req, done, commits, opCount, replays>>

\* The user focuses a pane; the client reveals its row (view state only).
Focus(cl) ==
  /\ \E p \in LivePanes(mirror[cl]) \ {focus[cl]} :
       /\ focus' = [focus EXCEPT ![cl] = p]
       /\ top' = [top EXCEPT ![cl][ColOfRow(mirror[cl], RowOfPane(mirror[cl], p))] =
                                RowOfPane(mirror[cl], p)]
  /\ UNCHANGED <<own, req, done, commits, opCount, replays, mirror, audit>>

Next ==
  \/ \E cl \in Clients : Issue(cl) \/ Sync(cl) \/ Focus(cl)
  \/ Process
  \/ Replay

Spec == Init /\ [][Next]_vars

\* --------------------------------------------------------------------------
\* Invariants on the owner (rows.md R1 to R5, layout-invariants.md I1 to I3).

R1_SinglePlacement ==
  /\ \A i, j \in DOMAIN own.cols : i # j => own.cols[i] # own.cols[j]
  /\ \A r \in LiveRows(own) :
       Cardinality({c \in LiveCols(own) : r \in Range(own.rowsOf[c])}) = 1
       /\ \A c \in LiveCols(own) : Cardinality({i \in DOMAIN own.rowsOf[c] : own.rowsOf[c][i] = r}) <= 1
  /\ \A p \in LivePanes(own) :
       Cardinality({r \in LiveRows(own) : p \in Range(own.panesOf[r])}) = 1
       /\ \A r \in LiveRows(own) : Cardinality({i \in DOMAIN own.panesOf[r] : own.panesOf[r][i] = p}) <= 1
  /\ \A t \in LiveTabs(own) :
       Cardinality({p \in LivePanes(own) : t \in Range(own.tabsOf[p])}) = 1
       /\ \A p \in LivePanes(own) : Cardinality({i \in DOMAIN own.tabsOf[p] : own.tabsOf[p][i] = t}) <= 1
  \* nothing hangs off a removed container
  /\ \A c \in ColIds \ LiveCols(own) : own.rowsOf[c] = <<>>
  /\ \A r \in RowIds \ LiveRows(own) : own.panesOf[r] = <<>> /\ own.height[r] = 0
  /\ \A p \in PaneIds \ LivePanes(own) : own.tabsOf[p] = <<>> \/ p \notin own.usedP

R2_NoEmptyContainer ==
  /\ \A c \in LiveCols(own) : own.rowsOf[c] # <<>>
  /\ \A r \in LiveRows(own) : own.panesOf[r] # <<>>
  /\ \A p \in LivePanes(own) : own.tabsOf[p] # <<>>

\* I1: only a close removes a tab; spawning ops add exactly their new tab.
R3_TabConservation == LiveTabs(own) = own.usedT \ own.closed /\ own.closed \subseteq own.usedT
                      /\ InitTabSet \subseteq own.usedT

R4_HeightInRange == \A r \in LiveRows(own) : own.height[r] \in Heights

R5_StickyConsistent ==
  /\ \A c \in ColIds \ LiveCols(own) : own.sticky[c] = "none"
  /\ \A e \in {"left", "right"} : Cardinality({c \in LiveCols(own) : own.sticky[c] = e}) <= 1
  /\ (\E c \in LiveCols(own) : own.sticky[c] # "none") => (\E c \in LiveCols(own) : own.sticky[c] = "none")

\* R6 (soundness): an op the owner treats as own place would not have
\* changed what a user sees.
R6_OwnPlaceSound == audit.noopSound

\* I5: one key commits at most once.
ExactlyOnce == \A k \in DOMAIN commits : commits[k] <= 1

\* Client view state stays valid against its own mirror.
ViewValid ==
  \A cl \in Clients :
    /\ IF LivePanes(mirror[cl]) = {} THEN focus[cl] = 0 ELSE focus[cl] \in LivePanes(mirror[cl])
    /\ \A c \in LiveCols(mirror[cl]) : top[cl][c] \in Range(mirror[cl].rowsOf[c])

\* N3: a removed focus stays in its column while that column has panes.
FocusStaysLocal == audit.local

TypeOK ==
  /\ own.closed \subseteq TabIds
  /\ opCount \in 0..MaxOps
  /\ replays \in 0..MaxReplays

\* R6 (completeness), action property: every committed change changes what
\* a user sees; an op that would only churn ids is caught as own place.
R6_OwnPlaceComplete == [][own' # own => Sig(own') # Sig(own)]_vars

\* A rejected or replayed op leaves the owner unchanged (structural check of
\* Process: the owner changes only through Apply results).
=============================================================================
