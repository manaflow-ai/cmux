---------------------------- MODULE FeedHandoff ----------------------------
(***************************************************************************)
(* Handoff of one feed item from a daemon's local feed server to FeedDO    *)
(* (plans/cmux-next/feed.md section 5).                                     *)
(*                                                                         *)
(* The local server owns the item until it hands it over: it freezes the   *)
(* item (handing), sends feed.adopt with the full item and the key         *)
(* adopt:<id>, resends with the same key until it gets the result, and     *)
(* only then records moved. The cloud owner's ledger answers a repeated    *)
(* key from the first decision. Messages may be lost (bounded), duplicated *)
(* and reordered. A user may answer at whichever owner currently accepts   *)
(* ops; a waiter on the Mac follows owner.moved to the cloud.              *)
(*                                                                         *)
(* Mutants: NoFreeze keeps accepting ops while the adopt is in flight;     *)
(* Unfreeze returns to owned when no result came (a timeout).              *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS MaxFaults, NoFreeze, Unfreeze

Item == [st : {"open", "answered"}, by : {"none", "local", "cloud"}]
NoItem == [st |-> "none", by |-> "none"]

VARIABLES
  lstate,   \* local server: "owned" | "handing" | "moved"
  litem,    \* the local copy
  citem,    \* the cloud copy, or NoItem
  msgs,     \* in-flight messages (a set: a message may be delivered again)
  answers,  \* answers committed by any owner
  faults,   \* messages lost so far
  waiter    \* [at: "local"|"cloud"|"done", seen: "none"|"local"|"cloud"]

vars == <<lstate, litem, citem, msgs, answers, faults, waiter>>

Adopt(i) == [t |-> "adopt", item |-> i]
Ok == [t |-> "ok", item |-> NoItem]

Init ==
  /\ lstate = "owned"
  /\ litem = [st |-> "open", by |-> "none"]
  /\ citem = NoItem
  /\ msgs = {}
  /\ answers = 0
  /\ faults = 0
  /\ waiter = [at |-> "local", seen |-> "none"]

\* The user answers at the local server while it accepts ops.
LocalAnswer ==
  /\ lstate = "owned" \/ (NoFreeze /\ lstate = "handing")
  /\ litem.st = "open"
  /\ litem' = [st |-> "answered", by |-> "local"]
  /\ answers' = answers + 1
  /\ UNCHANGED <<lstate, citem, msgs, faults, waiter>>

\* Reconnect: freeze (unless the NoFreeze mutant), then send the snapshot.
StartHandoff ==
  /\ lstate = "owned"
  /\ lstate' = "handing"
  /\ msgs' = msgs \cup {Adopt(litem)}
  /\ UNCHANGED <<litem, citem, answers, faults, waiter>>

\* Retry with the same key and the current (frozen) item.
Resend ==
  /\ lstate = "handing"
  /\ msgs' = msgs \cup {Adopt(litem)}
  /\ UNCHANGED <<lstate, litem, citem, answers, faults, waiter>>

\* FeedDO: the first adopt commits the item; a repeated key replays the result.
CloudAdopt(m) ==
  /\ m \in msgs /\ m.t = "adopt"
  /\ citem' = IF citem = NoItem THEN m.item ELSE citem
  /\ msgs' = msgs \cup {Ok}
  /\ UNCHANGED <<lstate, litem, answers, faults, waiter>>

LocalMoved ==
  /\ Ok \in msgs /\ lstate = "handing"
  /\ lstate' = "moved"
  /\ UNCHANGED <<litem, citem, msgs, answers, faults, waiter>>

\* Mutant: give up on a missing result and accept ops again.
TimeoutUnfreeze ==
  /\ Unfreeze /\ lstate = "handing"
  /\ lstate' = "owned"
  /\ UNCHANGED <<litem, citem, msgs, answers, faults, waiter>>

CloudAnswer ==
  /\ citem /= NoItem /\ citem.st = "open"
  /\ citem' = [st |-> "answered", by |-> "cloud"]
  /\ answers' = answers + 1
  /\ UNCHANGED <<lstate, litem, msgs, faults, waiter>>

Lose(m) ==
  /\ m \in msgs /\ faults < MaxFaults
  /\ msgs' = msgs \ {m}
  /\ faults' = faults + 1
  /\ UNCHANGED <<lstate, litem, citem, answers, waiter>>

\* The waiter (an agent's watch through its daemon) reads its current owner.
WaiterLocal ==
  /\ waiter.at = "local"
  /\ \/ /\ litem.st = "answered" /\ lstate /= "moved"
        /\ waiter' = [at |-> "done", seen |-> litem.by]
     \/ /\ lstate = "moved"
        /\ waiter' = [at |-> "cloud", seen |-> "none"]
  /\ UNCHANGED <<lstate, litem, citem, msgs, answers, faults>>

WaiterCloud ==
  /\ waiter.at = "cloud" /\ citem /= NoItem /\ citem.st = "answered"
  /\ waiter' = [at |-> "done", seen |-> citem.by]
  /\ UNCHANGED <<lstate, litem, citem, msgs, answers, faults>>

Next ==
  \/ LocalAnswer \/ StartHandoff \/ Resend \/ LocalMoved \/ TimeoutUnfreeze \/ CloudAnswer
  \/ \E m \in msgs : CloudAdopt(m) \/ Lose(m)
  \/ WaiterLocal \/ WaiterCloud

Spec == Init /\ [][Next]_vars
FairSpec == Spec /\ WF_vars(Resend) /\ WF_vars(LocalMoved) /\ WF_vars(CloudAnswer)
             /\ \A m \in {Ok} \cup {Adopt(i) : i \in Item} : WF_vars(CloudAdopt(m))
             /\ WF_vars(WaiterLocal) /\ WF_vars(WaiterCloud)

TypeOK ==
  /\ lstate \in {"owned", "handing", "moved"}
  /\ litem \in Item
  /\ citem \in Item \cup {NoItem}
  /\ answers \in 0..2

\* At most one owner accepts ops for the item at any time.
SingleWriter == ~(lstate = "owned" /\ citem /= NoItem)
\* A request is answered at most once across both owners.
AtMostOneAnswer == answers <= 1
\* An answer given locally before the move is in the cloud copy.
NoLostAnswer == (lstate = "moved" /\ litem.st = "answered") => citem = litem
\* The waiter reports the answer the item finally holds.
WaiterSeesFinal == waiter.at = "done" =>
  waiter.seen = (IF citem /= NoItem THEN citem.by ELSE litem.by)

\* Liveness: a started handoff completes despite bounded loss.
HandoffCompletes == (lstate = "handing") ~> (lstate = "moved")
=============================================================================
