---------------------------- MODULE closefocus ----------------------------
(***************************************************************************)
(* Focus and scroll after a close (plans/cmux-next/close-focus.md).       *)
(* One window's client view state over a projected layout:                *)
(*   Kind = "strip": a niri column strip. Columns of panes, each column    *)
(*     CW wide, a viewport VW wide; the successor of a closed focused pane *)
(*     is FocusAfterClose.pane (previous pane in its column, else the next *)
(*     there; a gone column goes to the column on the left, else right,    *)
(*     entering it at its most recently focused pane), or the most recent  *)
(*     pane (Policy = "recent").                                           *)
(*   Kind = "list": the sidebar's workspace list. Rows CW tall, one item   *)
(*     each; the successor is the next row, else the previous one          *)
(*     (FocusAfterClose.workspace).                                        *)
(* Anyone may close any item (the user, the CLI, another client, the      *)
(* daemon): origin does not enter the rules. A close re-anchors the       *)
(* offset on the focused item (strip: the focused column keeps its screen *)
(* x; list: the focused row if visible, else the first visible row), then *)
(* reveals the focus with the least scroll, clamped; the presented offset *)
(* animates toward that target one unit per step.                         *)
(*                                                                         *)
(* Safety: focus is a live item whenever one exists (never null, never    *)
(* removed); closing an unfocused item never moves focus; the target      *)
(* shows the focus whole and is clamped; a close that keeps the focus     *)
(* visible does not move it on screen unless the clamp forces it; a       *)
(* reveal is minimal. Liveness: after the user stops, the view settles    *)
(* with the focused item visible, and never scrolls again after settle.   *)
(* MUTANT names a broken variant that the run script expects to fail.     *)
(***************************************************************************)
EXTENDS Naturals, Integers, Sequences, FiniteSets

CONSTANTS Kind, Policy, Items, InitLayout, CW, VW, MaxSteps, None, MUTANT

VARIABLES
    cols,     \* sequence of columns, each a non-empty sequence of items (list: one item each)
    focus,    \* the focused item, or None
    hist,     \* focus history, newest first (a sequence without repeats)
    target,   \* where the offset settles
    off,      \* the presented offset (animates toward target)
    budget,   \* user/automation steps left (closes, focus moves, creations)
    closed    \* the item the last step closed, or None (for action properties)

vars == <<cols, focus, hist, target, off, budget, closed>>

Range(s) == {s[i] : i \in DOMAIN s}
AllItems(cs) == UNION {Range(cs[i]) : i \in DOMAIN cs}
Width(cs) == Len(cs) * CW
MaxOff(cs) == IF Width(cs) > VW THEN Width(cs) - VW ELSE 0
Clamp(x, cs) == IF x < 0 THEN 0 ELSE IF x > MaxOff(cs) THEN MaxOff(cs) ELSE x
ColOf(cs, p) == CHOOSE i \in DOMAIN cs : p \in Range(cs[i])
Pos(cs, p) == (ColOf(cs, p) - 1) * CW
Visible(cs, p, o) == Pos(cs, p) >= o /\ Pos(cs, p) + CW <= o + VW
Abs(x) == IF x < 0 THEN -x ELSE x

\* Least scroll from o that shows p whole (CW <= VW in every config).
Reveal(cs, p, o) ==
    IF p = None THEN Clamp(o, cs)
    ELSE IF Visible(cs, p, Clamp(o, cs)) THEN Clamp(o, cs)
    ELSE IF MUTANT = "center" THEN Clamp(Pos(cs, p) - (VW - CW) \div 2, cs)
    ELSE IF Abs(Pos(cs, p) - o) <= Abs(Pos(cs, p) + CW - VW - o)
         THEN Clamp(Pos(cs, p), cs) ELSE Clamp(Pos(cs, p) + CW - VW, cs)

Remove(s, x) == SelectSeq(s, LAMBDA y : y # x)
RemoveItem(cs, p) ==
    LET stripped == [i \in DOMAIN cs |-> Remove(cs[i], p)]
    IN SelectSeq(stripped, LAMBDA c : Len(c) > 0)
Push(h, p) == IF p = None THEN h ELSE <<p>> \o Remove(h, p)

FirstIn(h, S) == IF \E i \in DOMAIN h : h[i] \in S
                 THEN h[CHOOSE i \in DOMAIN h : h[i] \in S /\ \A j \in 1..(i-1) : h[j] \notin S]
                 ELSE None
IndexIn(s, x) == CHOOSE i \in DOMAIN s : s[i] = x

\* FocusAfterClose.pane (strip) / FocusAfterClose.workspace (list), over
\* the columns before the close; h is the history without p.
Successor(cs, p, h) ==
    LET c == ColOf(cs, p)
        col == cs[c]
        k == IndexIn(col, p)
        left == {i \in 1..(c-1) : TRUE}
        right == {i \in (c+1)..Len(cs) : TRUE}
        all == AllItems(cs) \ {p}
    IN IF all = {} THEN None
       ELSE IF MUTANT = "history" /\ FirstIn(h, all) # None THEN FirstIn(h, all)
       ELSE IF Kind = "strip" /\ Policy = "recent" /\ FirstIn(h, all) # None THEN FirstIn(h, all)
       ELSE IF Kind = "strip" /\ k > 1 THEN col[k - 1]
       ELSE IF Kind = "strip" /\ k < Len(col) THEN col[k + 1]
       ELSE LET pick == IF Kind = "list"
                        THEN (IF right # {} THEN c + 1 ELSE c - 1)
                        ELSE (IF left # {} THEN c - 1 ELSE c + 1)
                inner == Range(cs[pick])
            IN IF FirstIn(h, inner) # None THEN FirstIn(h, inner) ELSE cs[pick][1]

\* The anchored offset after cs -> ns. Strip: the old focused column keeps
\* its screen x when it survives. List: the focused row when it survives and
\* was visible, else the first visible row that survives.
Anchor(cs, ns, o, f) ==
    IF MUTANT = "noanchor" THEN Clamp(o, ns)
    ELSE LET survivors == AllItems(ns)
             visibleOld == {q \in AllItems(cs) : Pos(cs, q) + CW > o /\ Pos(cs, q) < o + VW}
             a == IF f # None /\ f \in survivors /\ (Kind = "strip" \/ f \in visibleOld) THEN f
                  ELSE IF Kind = "list" /\ \E q \in visibleOld \cap survivors : TRUE
                       THEN CHOOSE q \in visibleOld \cap survivors :
                              \A r \in visibleOld \cap survivors : Pos(cs, q) <= Pos(cs, r)
                       ELSE None
         IN IF a = None THEN Clamp(o, ns) ELSE Clamp(o + Pos(ns, a) - Pos(cs, a), ns)

\* Initial layouts the configs substitute for InitLayout.
StripInit == << <<"a", "b">>, <<"c">>, <<"d">> >>
ListInit == << <<"w1">>, <<"w2">>, <<"w3">>, <<"w4">>, <<"w5">> >>

Init ==
    /\ cols = InitLayout
    /\ focus \in AllItems(InitLayout)
    /\ hist = <<focus>>
    /\ target \in {o \in 0..MaxOff(InitLayout) : Visible(InitLayout, focus, o)}
    /\ off = target
    /\ budget = MaxSteps
    /\ closed = None

\* Anyone closes item p (the focused one or not).
Close(p) ==
    /\ budget > 0
    /\ p \in AllItems(cols)
    /\ LET ns == RemoveItem(cols, p)
           h == Remove(hist, p)
           nf == IF focus = p THEN Successor(cols, p, h) ELSE focus
           a == Anchor(cols, ns, target, focus)
           revealed == IF MUTANT = "noreveal" THEN a ELSE Reveal(ns, nf, a)
       IN /\ cols' = ns
          /\ focus' = nf
          /\ hist' = Push(h, nf)
          /\ target' = revealed
          /\ off' = Clamp(off + (a - target), ns)
          /\ budget' = budget - 1
          /\ closed' = p

\* The user focuses item p (click, keyboard).
Focus(p) ==
    /\ budget > 0
    /\ p \in AllItems(cols) /\ p # focus
    /\ focus' = p
    /\ hist' = Push(hist, p)
    /\ target' = Reveal(cols, p, target)
    /\ budget' = budget - 1
    /\ closed' = None
    /\ UNCHANGED <<cols, off>>

\* A new column (strip) or row (list) right after the focused one, focused.
Create(p) ==
    /\ budget > 0
    /\ p \in Items \ AllItems(cols)
    /\ focus # None
    /\ LET c == ColOf(cols, focus)
           ns == SubSeq(cols, 1, c) \o <<<<p>>>> \o SubSeq(cols, c + 1, Len(cols))
       IN /\ cols' = ns
          /\ focus' = p
          /\ hist' = Push(hist, p)
          /\ target' = Reveal(ns, p, Anchor(cols, ns, target, focus))
          /\ off' = Clamp(off + (Anchor(cols, ns, target, focus) - target), ns)
          /\ budget' = budget - 1
          /\ closed' = None

\* The animation steps the presented offset toward the target.
Animate ==
    /\ off # target
    /\ off' = IF off < target THEN off + 1 ELSE off - 1
    /\ closed' = None
    /\ UNCHANGED <<cols, focus, hist, target, budget>>

\* The client settles the same geometry again (any later model sync that
\* changes nothing: a redraw, an unrelated store event). V6/S6: no scroll.
Resync ==
    /\ off = target
    /\ target' = IF MUTANT = "nudge" THEN Clamp(target + 1, cols)
                 ELSE Reveal(cols, focus, Anchor(cols, cols, target, focus))
    /\ off' = target'
    /\ closed' = None
    /\ UNCHANGED <<cols, focus, hist, budget>>

Next ==
    \/ \E p \in Items : Close(p) \/ Focus(p) \/ Create(p)
    \/ Animate
    \/ Resync

Spec == Init /\ [][Next]_vars /\ WF_vars(Animate)

-----------------------------------------------------------------------------
\* Invariants

TypeOK ==
    /\ focus \in Items \cup {None}
    /\ target \in Int /\ off \in Int /\ budget \in 0..MaxSteps

\* C2, C3: focus is a live item, and null only when nothing is left.
FocusLive == (focus = None) <=> (AllItems(cols) = {})
FocusNotRemoved == focus # None => focus \in AllItems(cols)

\* V1/S2: the target is clamped.
TargetClamped == target >= 0 /\ target <= MaxOff(cols)

\* V2/S1: the settled view shows the focus whole.
TargetShowsFocus == focus # None => Visible(cols, focus, target)

Safety == TypeOK /\ FocusLive /\ FocusNotRemoved /\ TargetClamped /\ TargetShowsFocus

-----------------------------------------------------------------------------
\* Action properties

\* C1: closing an unfocused item, by anyone, never moves focus.
UnfocusedCloseKeepsFocus ==
    [][(closed' # None /\ closed' # focus) => focus' = focus]_vars

\* V3/S3: a close that keeps the focus, which was visible, does not move it
\* on screen unless the clamp forces a move.
NoJump ==
    [][(closed' # None /\ focus # None /\ focus' = focus /\ Visible(cols, focus, target)
        /\ Clamp(target + Pos(cols', focus) - Pos(cols, focus), cols') = target + Pos(cols', focus) - Pos(cols, focus))
       => Pos(cols', focus') - target' = Pos(cols, focus) - target]_vars

\* V4/S4: a changed focus is revealed with the least scroll: no offset
\* nearer the anchored one shows it.
MinimalReveal ==
    [][(closed' # None /\ focus' # focus /\ focus' # None)
       => LET a == Anchor(cols, cols', target, focus)
          IN \A o \in 0..MaxOff(cols') : Visible(cols', focus', o) => Abs(o - a) >= Abs(target' - a)]_vars

\* The configured successor rule, stated on column indices independently of
\* Successor: strip previous: same column (previous item, else next) while
\* it survives, else the nearest column on the left, else on the right;
\* list: the next row, else the previous one; recent: the newest
\* surviving item of the history.
SuccessorRule ==
    [][(closed' # None /\ closed' = focus /\ focus' # None)
       => LET c == ColOf(cols, focus)
              col == cols[c]
              k == IndexIn(col, focus)
              h == Remove(hist, focus)
              live == AllItems(cols')
          IN IF Kind = "list"
             THEN focus' = IF c < Len(cols) THEN cols[c + 1][1] ELSE cols[c - 1][1]
             ELSE IF Policy = "recent" /\ FirstIn(h, live) # None THEN focus' = FirstIn(h, live)
             ELSE IF Len(col) > 1 THEN focus' = IF k > 1 THEN col[k - 1] ELSE col[k + 1]
             ELSE IF c > 1 THEN focus' \in Range(cols[c - 1])
             ELSE focus' \in Range(cols[c + 1])]_vars

\* V6/S6: once settled, nothing but a user step scrolls (Resync is the
\* step that re-settles unchanged geometry; the "nudge" mutant breaks it).
NoSecondScroll == [][(off = target /\ budget' = budget /\ cols' = cols /\ focus' = focus) => target' = target]_vars

\* Liveness: after the last user step, the view settles with the focus visible.
Settles == <>[](off = target /\ (focus # None => Visible(cols, focus, off)))
=============================================================================
