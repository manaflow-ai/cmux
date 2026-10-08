--------------------------- MODULE OwnershipConvergence ---------------------------
(* Single writer per entity (OWNERSHIP-PRINCIPLES.md, ownership.md sections 3, 6).
   One owner stages each op, commits it durably, and only then publishes its
   delta and `settled {id, version, rejected}` (request-settled). Clients keep a
   confirmed mirror written only by owner messages plus an ordered intent log; an
   intent leaves the log only on its settled reply once the mirror has applied
   the settled version. Snapshots are messages carrying the requester's decided
   ids at the snapshot version. Channels reorder and duplicate messages and lose
   them on disconnect or owner restart; reconnect resends every pending intent
   with its key and requests a snapshot. Client-owned records may be written
   only by the connection's identity. *)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS Clients, Tabs, Panes, MaxOpsPerClient, MaxInFlight, MaxFaults, MaxRetries, None

VARIABLES
    durable,    \* [state, version, log, applied, rejected]: the owner's committed store
    staged,     \* None or [m, valid]: the op being committed (lost on restart)
    toOwner,    \* set of [op, from]; `from` is the connection's identity
    snapReq,    \* set of clients waiting for a snapshot reply
    toClient,   \* [Clients -> set of messages]
    connected,  \* [Clients -> BOOLEAN]
    awaiting,   \* [Clients -> BOOLEAN] snapshot requested, deltas buffered
    confirmed,  \* [Clients -> [state, version]]
    pending,    \* [Clients -> Seq(op)] intent log
    held,       \* [Clients -> set of settled replies] received, waiting for the mirror (client memory)
    settledOk,  \* [Clients -> set of ids] intents the client settled as applied (history)
    issued,     \* [Clients -> Nat]
    faults,     \* Nat: disconnects and restarts so far
    retries     \* Nat: timeout resends so far

vars == <<durable, staged, toOwner, snapReq, toClient, connected, awaiting, confirmed,
          pending, held, settledOk, issued, faults, retries>>

Range(s) == {s[i] : i \in DOMAIN s}
Remove(s, t) == SelectSeq(s, LAMBDA x : x # t)
Live(layout) == UNION {Range(layout[p]) : p \in Panes}
RECURSIVE SumOver(_)
SumOver(f) == IF DOMAIN f = {} THEN 0
              ELSE LET x == CHOOSE y \in DOMAIN f : TRUE
                   IN f[x] + SumOver([y \in DOMAIN f \ {x} |-> f[y]])
Count(layout, t) == SumOver([p \in Panes |-> Cardinality({i \in DOMAIN layout[p] : layout[p][i] = t})])

MoveOp(id, t, p) == [id |-> id, kind |-> "move", tab |-> t, pane |-> p, target |-> None]
CloseOp(id, t) == [id |-> id, kind |-> "close", tab |-> t, pane |-> None, target |-> None]
WriteOp(id, r) == [id |-> id, kind |-> "write", tab |-> None, pane |-> None, target |-> r]

\* The one reducer shared by the owner, mirror replay and intent overlay.
Valid(st, op, from) == IF op.kind = "write" THEN op.target = from ELSE op.tab \in Live(st.layout)
Apply(st, op, from) ==
    IF ~Valid(st, op, from) THEN st
    ELSE IF op.kind = "write" THEN [st EXCEPT !.records[op.target] = from]
    ELSE LET stripped == [p \in Panes |-> Remove(st.layout[p], op.tab)]
         IN [st EXCEPT !.layout = IF op.kind = "close" THEN stripped
                                  ELSE [stripped EXCEPT ![op.pane] = Append(@, op.tab)]]

RECURSIVE Overlay(_, _, _)
Overlay(st, ops, from) == IF ops = <<>> THEN st ELSE Overlay(Apply(st, Head(ops), from), Tail(ops), from)
RECURSIVE Replay(_, _)
Replay(st, entries) == IF entries = <<>> THEN st
                       ELSE Replay(Apply(st, Head(entries).op, Head(entries).from), Tail(entries))

\* Visible state: the confirmed mirror with the intent log overlaid in order.
View(c) == Overlay(confirmed[c].state, pending[c], c)

InitLayout ==
    LET first == CHOOSE p \in Panes : TRUE
        order == CHOOSE s \in [1..Cardinality(Tabs) -> Tabs] : Range(s) = Tabs
    IN [p \in Panes |-> IF p = first THEN order ELSE <<>>]
InitState == [layout |-> InitLayout, records |-> [c \in Clients |-> None]]

Init ==
    /\ durable = [state |-> InitState, version |-> 0, log |-> <<>>, applied |-> {}, rejected |-> {}]
    /\ staged = None
    /\ toOwner = {} /\ snapReq = {}
    /\ toClient = [c \in Clients |-> {}]
    /\ connected = [c \in Clients |-> TRUE]
    /\ awaiting = [c \in Clients |-> FALSE]
    /\ confirmed = [c \in Clients |-> [state |-> InitState, version |-> 0]]
    /\ pending = [c \in Clients |-> <<>>]
    /\ held = [c \in Clients |-> {}]
    /\ settledOk = [c \in Clients |-> {}]
    /\ issued = [c \in Clients |-> 0]
    /\ faults = 0 /\ retries = 0

Decided == durable.applied \cup durable.rejected
AppliedAt(id) == CHOOSE i \in DOMAIN durable.log : durable.log[i].op.id = id
Settled(id, ok, v) == [type |-> "settled", id |-> id, ok |-> ok, version |-> v]
Reply(c, msg) == [toClient EXCEPT ![c] = IF connected[c] THEN @ \cup {msg} ELSE @]
Broadcast(msg) == [c \in Clients |-> IF connected[c] THEN toClient[c] \cup {msg} ELSE toClient[c]]

------------------------------------------------------------------------------
\* Client actions.

Issue(c, op) ==
    /\ pending' = [pending EXCEPT ![c] = Append(@, op)]
    /\ toOwner' = toOwner \cup {[op |-> op, from |-> c]}
    /\ issued' = [issued EXCEPT ![c] = @ + 1]
    /\ UNCHANGED <<durable, staged, snapReq, toClient, connected, awaiting, confirmed, held, settledOk, faults, retries>>

NextId(c) == <<c, issued[c] + 1>>
IssueAny(c) ==
    /\ connected[c] /\ issued[c] < MaxOpsPerClient
    /\ \/ \E t \in Tabs, p \in Panes : Issue(c, MoveOp(NextId(c), t, p))
       \/ \E t \in Tabs : Issue(c, CloseOp(NextId(c), t))
       \/ \E r \in Clients : Issue(c, WriteOp(NextId(c), r))

\* Timeout: resend a pending intent with the same key.
Retry(c) ==
    /\ connected[c] /\ pending[c] # <<>> /\ retries < MaxRetries
    /\ \E i \in DOMAIN pending[c] : toOwner' = toOwner \cup {[op |-> pending[c][i], from |-> c]}
    /\ retries' = retries + 1
    /\ UNCHANGED <<durable, staged, snapReq, toClient, connected, awaiting, confirmed, pending, held, settledOk, issued, faults>>

DropPending(c, id) == SelectSeq(pending[c], LAMBDA o : o.id # id)

\* Deltas are buffered (stay in the channel) while a snapshot is outstanding.
ReceiveDelta(c, msg, keep) ==
    /\ connected[c] /\ ~awaiting[c]
    /\ msg \in toClient[c] /\ msg.type = "delta"
    /\ toClient' = [toClient EXCEPT ![c] = IF keep THEN @ ELSE @ \ {msg}]
    /\ IF msg.version = confirmed[c].version + 1
       THEN /\ confirmed' = [confirmed EXCEPT ![c] =
                   [state |-> Apply(@.state, msg.op, msg.from), version |-> msg.version]]
            /\ UNCHANGED <<awaiting, snapReq>>
       ELSE IF msg.version > confirmed[c].version + 1
       THEN \* Gap: ask for a snapshot.
            /\ awaiting' = [awaiting EXCEPT ![c] = TRUE]
            /\ snapReq' = snapReq \cup {c}
            /\ UNCHANGED confirmed
       ELSE UNCHANGED <<confirmed, awaiting, snapReq>>
    /\ UNCHANGED <<durable, staged, toOwner, connected, pending, held, settledOk, issued, faults, retries>>

\* request-settled: a reject leaves at once; an applied intent leaves only once
\* the mirror covers its version. A reply that arrives early is held in client
\* memory (it survives disconnects and owner restarts).
Settle(c, msg) ==
    /\ pending' = [pending EXCEPT ![c] = DropPending(c, msg.id)]
    /\ settledOk' = IF msg.ok THEN [settledOk EXCEPT ![c] = @ \cup {msg.id}] ELSE settledOk

ReceiveSettled(c, msg, keep) ==
    /\ connected[c] /\ msg \in toClient[c] /\ msg.type = "settled"
    /\ toClient' = [toClient EXCEPT ![c] = IF keep THEN @ ELSE @ \ {msg}]
    /\ IF msg.ok => confirmed[c].version >= msg.version
       THEN Settle(c, msg) /\ UNCHANGED held
       ELSE held' = [held EXCEPT ![c] = @ \cup {msg}] /\ UNCHANGED <<pending, settledOk>>
    /\ UNCHANGED <<durable, staged, toOwner, snapReq, connected, awaiting, confirmed, issued, faults, retries>>

SettleHeld(c, msg) ==
    /\ msg \in held[c] /\ confirmed[c].version >= msg.version
    /\ held' = [held EXCEPT ![c] = @ \ {msg}]
    /\ Settle(c, msg)
    /\ UNCHANGED <<durable, staged, toOwner, snapReq, toClient, connected, awaiting, confirmed, issued, faults, retries>>

\* A snapshot carries the state, its version and the requester's decided ids at
\* that version; the client adopts it and drops those intents.
ReceiveSnap(c, msg) ==
    /\ connected[c] /\ msg \in toClient[c] /\ msg.type = "snap"
    /\ toClient' = [toClient EXCEPT ![c] = @ \ {msg}]
    /\ awaiting' = [awaiting EXCEPT ![c] = FALSE]
    /\ IF msg.version >= confirmed[c].version
       THEN /\ confirmed' = [confirmed EXCEPT ![c] = [state |-> msg.state, version |-> msg.version]]
            /\ pending' = [pending EXCEPT ![c] = SelectSeq(@, LAMBDA o : o.id \notin msg.decided)]
            /\ settledOk' = [settledOk EXCEPT ![c] = @ \cup (msg.decided \cap durable.applied)]
       ELSE UNCHANGED <<confirmed, pending, settledOk>>
    /\ UNCHANGED <<durable, staged, toOwner, snapReq, connected, held, issued, faults, retries>>

Disconnect(c) ==
    /\ connected[c] /\ faults < MaxFaults
    /\ connected' = [connected EXCEPT ![c] = FALSE]
    /\ toClient' = [toClient EXCEPT ![c] = {}]
    /\ toOwner' = {m \in toOwner : m.from # c}
    /\ snapReq' = snapReq \ {c}
    /\ awaiting' = [awaiting EXCEPT ![c] = FALSE]
    /\ faults' = faults + 1
    /\ UNCHANGED <<durable, staged, confirmed, pending, held, settledOk, issued, retries>>

\* Reconnect: resend every pending intent (no knowledge of the owner's ledger)
\* and request a snapshot.
Reconnect(c) ==
    /\ ~connected[c]
    /\ connected' = [connected EXCEPT ![c] = TRUE]
    /\ toOwner' = toOwner \cup {[op |-> o, from |-> c] : o \in Range(pending[c])}
    /\ awaiting' = [awaiting EXCEPT ![c] = TRUE]
    /\ snapReq' = snapReq \cup {c}
    /\ UNCHANGED <<durable, staged, toClient, confirmed, pending, held, settledOk, issued, faults, retries>>

------------------------------------------------------------------------------
\* Owner actions.

\* Stage one op at a time. A decided key answers from the ledger.
OwnerReceive(m, keep) ==
    /\ staged = None /\ m \in toOwner
    /\ toOwner' = IF keep THEN toOwner ELSE toOwner \ {m}
    /\ IF m.op.id \in Decided
       THEN /\ toClient' = Reply(m.from,
                   IF m.op.id \in durable.applied THEN Settled(m.op.id, TRUE, AppliedAt(m.op.id))
                   ELSE Settled(m.op.id, FALSE, 0))
            /\ UNCHANGED staged
       ELSE /\ staged' = [m |-> m, valid |-> Valid(durable.state, m.op, m.from)]
            /\ UNCHANGED toClient
    /\ UNCHANGED <<durable, snapReq, connected, awaiting, confirmed, pending, held, settledOk, issued, faults, retries>>

\* Commit durably, then publish the delta and the settled reply.
Commit ==
    /\ staged # None
    /\ LET m == staged.m IN
       IF staged.valid
       THEN /\ durable' = [state |-> Apply(durable.state, m.op, m.from), version |-> durable.version + 1,
                           log |-> Append(durable.log, m), applied |-> durable.applied \cup {m.op.id},
                           rejected |-> durable.rejected]
            /\ toClient' = LET d == [type |-> "delta", op |-> m.op, from |-> m.from, version |-> durable.version + 1]
                               b == Broadcast(d)
                           IN [b EXCEPT ![m.from] = IF connected[m.from] THEN @ \cup {Settled(m.op.id, TRUE, durable.version + 1)} ELSE @]
       ELSE /\ durable' = [durable EXCEPT !.rejected = @ \cup {m.op.id}]
            /\ toClient' = Reply(m.from, Settled(m.op.id, FALSE, 0))
    /\ staged' = None
    /\ UNCHANGED <<toOwner, snapReq, connected, awaiting, confirmed, pending, held, settledOk, issued, faults, retries>>

OwnerSnap(c) ==
    /\ c \in snapReq /\ staged = None
    /\ snapReq' = snapReq \ {c}
    /\ toClient' = Reply(c, [type |-> "snap", state |-> durable.state, version |-> durable.version,
                             decided |-> {id \in Decided : id[1] = c}])
    /\ UNCHANGED <<durable, staged, toOwner, connected, awaiting, confirmed, pending, held, settledOk, issued, faults, retries>>

\* Restart: every connection drops; the staged op is lost; the store is durable.
OwnerRestart ==
    /\ faults < MaxFaults /\ \E c \in Clients : connected[c]
    /\ staged' = None
    /\ connected' = [c \in Clients |-> FALSE]
    /\ awaiting' = [c \in Clients |-> FALSE]
    /\ toClient' = [c \in Clients |-> {}]
    /\ toOwner' = {} /\ snapReq' = {}
    /\ faults' = faults + 1
    /\ UNCHANGED <<durable, confirmed, pending, held, settledOk, issued, retries>>

Next ==
    \/ \E c \in Clients : IssueAny(c) \/ Retry(c) \/ Disconnect(c) \/ Reconnect(c) \/ OwnerSnap(c)
    \/ \E c \in Clients : \E msg \in held[c] : SettleHeld(c, msg)
    \/ \E c \in Clients : \E msg \in toClient[c] :
          ReceiveSnap(c, msg) \/ \E keep \in BOOLEAN : ReceiveDelta(c, msg, keep) \/ ReceiveSettled(c, msg, keep)
    \/ \E m \in toOwner, keep \in BOOLEAN : OwnerReceive(m, keep)
    \/ Commit
    \/ OwnerRestart

\* Fairness for the liveness config: delivery without duplication, commits,
\* snapshots and reconnects eventually happen.
Fairness ==
    /\ WF_vars(Commit)
    /\ \A c \in Clients : WF_vars(Reconnect(c)) /\ WF_vars(OwnerSnap(c)) /\ WF_vars(\E msg \in held[c] : SettleHeld(c, msg))
    /\ WF_vars(\E m \in toOwner : OwnerReceive(m, FALSE))
    /\ \A c \in Clients : WF_vars(\E msg \in toClient[c] :
          ReceiveSnap(c, msg) \/ ReceiveDelta(c, msg, FALSE) \/ ReceiveSettled(c, msg, FALSE))

Spec == Init /\ [][Next]_vars
LiveSpec == Spec /\ Fairness

Sym == Permutations(Clients)
InFlight == Cardinality(toOwner) + SumOver([c \in Clients |-> Cardinality(toClient[c])])
InFlightBound == InFlight <= MaxInFlight

------------------------------------------------------------------------------
\* Safety.

TypeOK == \A c \in Clients : confirmed[c].version <= durable.version

NoDuplicate(layout) == \A t \in Tabs : Count(layout, t) <= 1
\* Principles 1, 2 at the protocol level: no visible state duplicates a tab.
\* (Given the shared Apply these mostly test the reducer; the reducer crate's
\* proptest and TabLayout.tla cover tree shape and emptied panes.)
Conservation ==
    /\ NoDuplicate(durable.state.layout)
    /\ \A c \in Clients : NoDuplicate(confirmed[c].state.layout) /\ NoDuplicate(View(c).layout)
NoSilentLoss ==
    \A t \in Tabs : t \notin Live(durable.state.layout) =>
        \E i \in DOMAIN durable.log : durable.log[i].op.kind = "close" /\ durable.log[i].op.tab = t

\* Principle 5: a key is applied at most once.
NoDoubleApply ==
    /\ durable.version = Len(durable.log)
    /\ Len(durable.log) = Cardinality(durable.applied)
    /\ \A i, j \in DOMAIN durable.log : i # j => durable.log[i].op.id # durable.log[j].op.id

\* Principle 6: an op a client settled as applied is in the durable store, even
\* after a restart (fails if the owner publishes before it commits).
NoLostAck == \A c \in Clients : settledOk[c] \subseteq durable.applied

\* Single writer for client-owned records, judged by connection identity.
RecordSingleWriter == \A r \in Clients : durable.state.records[r] \in {None, r}

\* Principle 4 (prefix form): a mirror at version k equals the owner's state at k.
MirrorIsPrefix ==
    \A c \in Clients : confirmed[c].state = Replay(InitState, SubSeq(durable.log, 1, confirmed[c].version))

\* Principle 6: an intent the owner has not decided stays in its sender's
\* intent log, hence in its visible state (View overlays the log).
PendingVisible ==
    \A c \in Clients : \A k \in 1..issued[c] :
        <<c, k>> \notin Decided => \E i \in DOMAIN pending[c] : pending[c][i].id = <<c, k>>

\* No flicker after settlement: once a client settles an intent as applied, its
\* mirror already contains that op (the intent never leaves before its effect).
NoFlicker ==
    \A c \in Clients : \A id \in settledOk[c] \cap durable.applied :
        confirmed[c].version >= AppliedAt(id)

Quiescent ==
    /\ staged = None /\ toOwner = {} /\ snapReq = {}
    /\ \A c \in Clients : connected[c] /\ ~awaiting[c] /\ toClient[c] = {} /\ held[c] = {}

Converged == \A c \in Clients :
    /\ View(c) = durable.state
    /\ confirmed[c].version = durable.version
    /\ pending[c] = <<>>

\* Principle 4: with nothing in flight, every visible state equals the owner's.
Convergence == Quiescent => Converged

\* Liveness (LiveSpec, bounded faults and retries): the system always converges.
EventuallyConverged == <>(Quiescent /\ Converged)
=============================================================================
