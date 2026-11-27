---------------------------- MODULE hovercard ----------------------------
(***************************************************************************)
(* The cmux-next hover card state machine (HoverCardMachine.swift) and    *)
(* the world its effects drive: the one card window and the one timer.    *)
(* plans/cmux-next/hovercards.md. Run: plans/cmux-next/formal/tlc.sh       *)
(*                                                                         *)
(* Safety: at most one card, and it is the machine's; the timer is the     *)
(* machine's; a hover card is for what the pointer is over; nothing is     *)
(* active while suppressed; a stale timer never acts; no card is lost      *)
(* while the pointer rests on a target. Liveness: a pointer that rests on  *)
(* a target, with nothing else happening, gets that target's card.         *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS Targets, None, MaxToken, Reasons

VARIABLES
    phase,      \* "idle" | "pending" | "shown" | "pinned" | "grace"
    target,     \* the pending / shown / pinned target, or None
    token,      \* the phase's timer token (pending, grace, pinned), else 0
    lastHit,    \* what the last hit test found under the pointer, or None
    quiet,      \* after a dismissal: a still pointer starts no card
    supp,       \* active suppressions (drag, scroll)
    nextToken,  \* tokens are used once
    visible,    \* WORLD: the target the one card window shows, or None
    armed       \* WORLD: the token the one timer carries, or 0

vars == <<phase, target, token, lastHit, quiet, supp, nextToken, visible, armed>>
Machine == <<phase, target, token, lastHit, quiet, supp, nextToken>>

Init ==
    /\ phase = "idle" /\ target = None /\ token = 0 /\ lastHit = None
    /\ quiet = FALSE /\ supp = {} /\ nextToken = 1 /\ visible = None /\ armed = 0

\* Tokens cycle through 1..MaxToken: only "equals the armed token" matters,
\* so a finite counter keeps the state space finite without a constraint.
Succ(k) == IF k = MaxToken THEN 1 ELSE k + 1

Shown == IF phase \in {"shown", "pinned"} THEN target ELSE None
ArmedToken == IF phase \in {"pending", "grace", "pinned"} THEN token ELSE 0

\* Effects on the world, applied with the new machine state.
\* The world follows the machine through effects only: show sets the card,
\* hide clears it, schedule and cancel set the timer. Each action below
\* states the effects it emits explicitly in visible' and armed'.

\* --- Helpers producing the post-state of an "end" (back to idle) ---
EndTo(q) ==
    /\ phase' = "idle" /\ target' = None /\ token' = 0
    /\ visible' = None /\ armed' = 0
    /\ quiet' = q

\* Arm a pending card for t (schedule).
ArmTo(t) ==
    /\ phase' = "pending" /\ target' = t /\ token' = nextToken
    /\ nextToken' = Succ(nextToken)
    /\ armed' = nextToken /\ visible' = None

\* resume: idle, pointer resting, not quiet, not suppressed -> arm.
CanResume(l, q, s) == l # None /\ ~q /\ s = {}

(* hit(t, moved) *)
Hit(t, moved) ==
    \* Quiet covers only the target the pointer already rested on.
    LET q == IF moved \/ t # lastHit THEN FALSE ELSE quiet IN
    /\ lastHit' = t
    /\ supp' = supp
    /\ IF supp # {} THEN
         /\ EndTo(q) /\ UNCHANGED nextToken
       ELSE IF q /\ ~moved /\ t = lastHit THEN
         IF Shown # None /\ Shown = t
           THEN /\ quiet' = q /\ UNCHANGED <<phase, target, token, nextToken, visible, armed>>
           ELSE /\ EndTo(q) /\ UNCHANGED nextToken
       ELSE CASE phase = "idle" ->
                 IF t = None THEN /\ quiet' = q /\ UNCHANGED <<phase, target, token, nextToken, visible, armed>>
                             ELSE /\ ArmTo(t) /\ quiet' = q
              [] phase = "pending" ->
                 IF t = None THEN /\ EndTo(q) /\ UNCHANGED nextToken
                 ELSE IF t = target THEN /\ quiet' = q /\ UNCHANGED <<phase, target, token, nextToken, visible, armed>>
                 ELSE /\ ArmTo(t) /\ quiet' = q
              [] phase = "grace" ->
                 IF t = None THEN /\ quiet' = q /\ UNCHANGED <<phase, target, token, nextToken, visible, armed>>
                 ELSE /\ phase' = "shown" /\ target' = t /\ token' = 0 /\ visible' = t /\ armed' = 0
                      /\ quiet' = q /\ UNCHANGED nextToken
              [] phase = "shown" ->
                 IF t = None THEN /\ phase' = "grace" /\ target' = None /\ token' = nextToken
                                  /\ nextToken' = Succ(nextToken) /\ visible' = None /\ armed' = nextToken /\ quiet' = q
                 ELSE /\ phase' = "shown" /\ target' = t /\ token' = 0 /\ visible' = t /\ armed' = 0
                      /\ quiet' = q /\ UNCHANGED nextToken
              [] phase = "pinned" ->
                 \* Only a pointer that moves onto another target takes over.
                 IF t = None \/ t = target \/ ~moved THEN /\ quiet' = q /\ UNCHANGED <<phase, target, token, nextToken, visible, armed>>
                 ELSE /\ phase' = "shown" /\ target' = t /\ token' = 0 /\ visible' = t /\ armed' = 0
                      /\ quiet' = q /\ UNCHANGED nextToken

(* deadline(k): the timer fires (k = armed) or a stale token arrives. *)
Deadline(k) ==
    /\ k \in 1..MaxToken
    /\ IF k # ArmedToken THEN UNCHANGED vars     \* stale: nothing happens
       ELSE CASE phase = "pending" ->
                 /\ phase' = "shown" /\ token' = 0 /\ visible' = target /\ armed' = 0
                 /\ UNCHANGED <<target, lastHit, quiet, supp, nextToken>>
              [] phase = "grace" ->
                 /\ phase' = "idle" /\ token' = 0 /\ armed' = 0
                 /\ UNCHANGED <<target, lastHit, quiet, supp, nextToken, visible>>
              [] phase = "pinned" ->
                 IF supp = {} /\ lastHit = target
                   THEN /\ phase' = "shown" /\ token' = 0 /\ armed' = 0
                        /\ UNCHANGED <<target, lastHit, quiet, supp, nextToken, visible>>
                 ELSE IF CanResume(lastHit, quiet, supp)
                   THEN /\ ArmTo(lastHit) /\ UNCHANGED <<lastHit, quiet, supp>>
                 ELSE /\ EndTo(quiet) /\ UNCHANGED <<lastHit, supp, nextToken>>

Dismiss ==
    /\ EndTo(TRUE) /\ UNCHANGED <<lastHit, supp, nextToken>>

Suppress(r) ==
    /\ supp' = supp \cup {r}
    /\ EndTo(TRUE) /\ UNCHANGED <<lastHit, nextToken>>

Unsuppress(r) ==
    /\ r \in supp
    /\ supp' = supp \ {r}
    /\ lastHit' = lastHit /\ quiet' = quiet
    /\ IF phase = "idle" /\ CanResume(lastHit, quiet, supp \ {r})
         THEN ArmTo(lastHit)
         ELSE UNCHANGED <<phase, target, token, nextToken, visible, armed>>

Removed(t) ==
    LET l == IF lastHit = t THEN None ELSE lastHit IN
    /\ lastHit' = l /\ supp' = supp
    /\ IF target # t THEN /\ quiet' = quiet /\ UNCHANGED <<phase, target, token, nextToken, visible, armed>>
       ELSE IF CanResume(l, quiet, supp)
         THEN /\ ArmTo(l) /\ quiet' = quiet
         ELSE /\ EndTo(quiet) /\ UNCHANGED nextToken

Pin(t) ==
    /\ supp = {}
    /\ phase' = "pinned" /\ target' = t /\ token' = nextToken /\ nextToken' = Succ(nextToken)
    /\ visible' = t /\ armed' = nextToken /\ quiet' = FALSE
    /\ UNCHANGED <<lastHit, supp>>

Fire == armed > 0 /\ Deadline(armed)

Next ==
    \/ \E t \in Targets \cup {None}, m \in BOOLEAN : Hit(t, m)
    \/ \E k \in 1..MaxToken : Deadline(k)
    \/ Dismiss
    \/ \E r \in Reasons : Suppress(r) \/ Unsuppress(r)
    \/ \E t \in Targets : Removed(t) \/ Pin(t)

Spec == Init /\ [][Next]_vars /\ WF_vars(Fire)

TypeOK ==
    /\ phase \in {"idle", "pending", "shown", "pinned", "grace"}
    /\ target \in Targets \cup {None} /\ lastHit \in Targets \cup {None}
    /\ visible \in Targets \cup {None} /\ supp \subseteq Reasons

\* I1: the one card and the one timer are the machine's.
CardIsMachines == visible = Shown
TimerIsMachines == armed = ArmedToken
\* I2: a hover card (not pinned) is for what the pointer is over.
UnderPointer == phase = "shown" => lastHit = target
\* I6: nothing active while suppressed.
SuppressedIdle == supp # {} => phase = "idle"
\* I8: no lost card while the pointer rests on a target.
NoLostCard == (phase = "idle" /\ lastHit # None /\ ~quiet /\ supp = {}) => FALSE
\* Single card: one phase, one target; a pending, shown or pinned card has one.
OneCard == (phase \in {"pending", "shown", "pinned"}) <=> (target # None)

Safety == TypeOK /\ CardIsMachines /\ TimerIsMachines /\ UnderPointer /\ SuppressedIdle /\ NoLostCard /\ OneCard

\* I3 as a step property: a stale deadline changes nothing.
StaleDoesNothing == [][\A k \in 1..MaxToken : (k # ArmedToken /\ Deadline(k)) => UNCHANGED vars]_vars

\* I9: content moving under a still pointer never takes a pinned card.
PinnedStaysUnderStillPointer ==
    [][(phase = "pinned" /\ \E t \in Targets \cup {None} : Hit(t, FALSE)) => target' = target]_vars
\* I10: a new target under a still pointer gets the normal path.
NewTargetUnderStillPointer ==
    [][\A t \in Targets : (supp = {} /\ phase # "pinned" /\ t # lastHit /\ Hit(t, FALSE)) => target' = t]_vars

\* Liveness: once only "resting" steps happen (the timer fires, stale
\* timers arrive, geometry re-hits find the same target under the still
\* pointer) and the pointer rests on t with nothing keeping cards away,
\* t's card eventually shows and stays.
Resting(t) ==
    \/ \E k \in 1..MaxToken : Deadline(k)
    \/ Hit(t, FALSE)
RestingGetsCard == \A t \in Targets :
    (<>[][Resting(t)]_vars /\ <>[](lastHit = t /\ supp = {} /\ ~quiet)) => <>[](visible = t)
=============================================================================
