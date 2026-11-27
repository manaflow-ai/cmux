# Agent runtime handoff and capacity-aware routing

Status: Draft

This RFC defines how cmux keeps an agent session usable when its sidecar,
surface, machine, account, provider, or chat task changes. The intended user
experience is simple: an agent keeps its identity and context, a moved chat
continues from the last confirmed boundary, and a model or account capacity
event is absorbed by routing whenever a safe route exists. The user should not
have to copy a prompt into a new chat or manually select another model for a
transient capacity failure.

The proposal connects four existing pieces without making any one of them the
source of truth for all the others:

- cmux's stable surface binding and planned `AgentSession` authority in
  [`docs/agent-session-tracking-spec.md`](../agent-session-tracking-spec.md);
- the agent-chat sidecar and its normalized provider event stream in
  [`agent-chat/README.md`](../../agent-chat/README.md);
- CodeRouter's account selection, request IDs, cooldowns, and route telemetry
  in [`web/services/coderouter/README.md`](../../web/services/coderouter/README.md);
- the sticky, load-aware machine routing model in
  [`docs/internal/machine-router.md`](../internal/machine-router.md).

## User outcome

An agent session is a durable logical object. A browser tab, cmux surface,
sidecar process, provider process, account, and machine are replaceable
attachments to that object.

When the user moves a chat, reconnects after a restart, opens the same session
on another surface, or a provider account reaches capacity:

1. cmux identifies the same logical session and shows its last authoritative
   state;
2. the runtime resumes from a durable event and transcript checkpoint;
3. an in-flight operation is either completed once, explicitly retried before
   output, or marked recoverable without duplicating a partial response;
4. routing chooses a healthy account or machine with the same requested
   capability when possible;
5. the UI explains the state in plain language: `rerouting`, `resuming`,
   `waiting for capacity`, or `needs attention`.

The normal path contains no account IDs, provider credentials, machine IDs, or
manual prompt copying. An advanced view can show a request or operation ID so
an operator can join the UI state to telemetry.

## Problem and scope

The current agent-chat MVP has one in-memory session map per sidecar and a
replayable in-memory event log. WebSocket reconnects can replay that log, but a
sidecar restart loses it. A `send` has no operation identity, so a client retry
cannot distinguish a lost request from a request that the provider already
accepted. Forking copies event history but does not yet establish durable
parent/child lineage.

The session-tracking proposal binds one authoritative session to each stable
surface, with versioned snapshots, push as a hint, pull as authoritative, and
process-exit/transcript backstops. This RFC retains those reconciliation rules
but proposes a separate logical identity and an explicit attachment transaction
for cross-surface moves. That identity change is not implemented by the cited
session-tracking contract.

Routing has a related boundary. CodeRouter and Subrouter can select among
accounts, but provider capacity is not always an HTTP error. A provider may
return a successful streaming response whose first event is a quota or model
capacity error. Once output bytes are visible, replaying the request can
duplicate a partial generation. The router therefore needs a common outcome
contract and an explicit output boundary.

This RFC covers session identity, durable runtime state, handoff and fork
semantics, capacity-aware routing, and observability. It does not define a new
provider protocol, replace native provider resume APIs, or make arbitrary
model substitutions without a user or team policy permitting them.

## Research signals

This boundary follows the features that recur across independent harnesses and
provider tooling:

- [oh-my-openagent](https://github.com/docevilOck/oh-my-opencode) emphasizes
  one-command activation, parallel specialists, tmux visibility, recovery,
  model fallback, and context-lazy skills.
- [oh-my-claudecode](https://github.com/Yeachan-Heo/oh-my-claudecode) moved from
  a large command vocabulary toward intent-based activation while retaining
  explicit escape hatches and diagnostics.
- [oh-my-pi](https://github.com/can1357/oh-my-pi) treats compaction, branch
  summaries, session trees, memory, and provider routing as durable runtime
  concerns; its reliability-focused fork adds turn metrics, MCP failure
  isolation, abort tests, and compaction metrics.
- [Superpowers](https://github.com/obra/superpowers) and
  [Super-Ralph](https://github.com/aezizhu/super-ralph) put planning, TDD,
  verification, circuit breakers, and session continuity in the harness
  methodology rather than in the terminal host.
- [Shepherd](https://github.com/SecurityRonin/shepherd) and
  [twaldin/harness](https://github.com/twaldin/harness) show the terminal-host
  side: process ownership, cancellation, adoption, logs, quality gates,
  notifications, and provider-neutral adapters.

The [Harness Engineering source-code study](https://arxiv.org/abs/2609.00006)
describes the harness as the layer coupling a model to tools, context, safety,
orchestration, and extension surfaces. cmux should provide the durable runtime
and transport primitives that those harnesses can use, while leaving their
workflow opinions replaceable.

## Ownership model

Each layer owns a narrow class of state. A layer may cache another layer's
state, but it must not silently become authoritative for it.

| Layer | Owns | Does not own |
| --- | --- | --- |
| **cmux app** | Stable `surfaceID`, workspace attachment, visible session catalog, local process ownership, user actions | Provider account health or provider session IDs |
| **Agent runtime / harness** | Agent process, provider protocol, native provider session ID, turn lifecycle, permissions, output boundary, transcript/event journal | Which account or machine is selected |
| **CodeRouter** | Model/provider/account selection for its route, sticky binding, health windows, cooldowns, pre-output retry budget, route telemetry | cmux surface identity, chat transcript authority, user-visible fork lineage |
| **Subrouter** | Account-pool brokering for requests that traverse Subrouter, hosted tenant capability and account assignment | cmux session identity or another router's mutable pool state |
| **Control plane** | Durable metadata, leases, idempotency records, entitlement and billing facts | Live UI state and provider output contents |
| **Presence service** | Best-effort live device/session hints and versioned snapshots | Durable session history or authorization decisions outside its team scope |
| **Agent-chat sidecar** | HTTP/WebSocket transport and adapter process supervision | The durable source of truth; it must be reconstructible from the journal |

CodeRouter and Subrouter are separate routing planes. A request must carry a
route envelope that identifies which plane handled it; the planes must not
attempt to coordinate by mutating each other's account records. A session can
remain sticky to a route while that route is healthy, but a capacity or health
event is an explicit reason to evict the temporary binding.

## Durable session model

The authoritative record is keyed by a cmux-generated `sessionID`, independent
of both surface and provider identity. A session has at most one writable
surface attachment, and a surface has at most one attached session. Additional
history viewers are read-only and do not claim an attachment. A detached
session remains in the durable catalog.

This intentionally revises the **Authority** and **Persistence across app
relaunch** sections of the [session-tracking proposal](../agent-session-tracking-spec.md):
its per-surface record becomes an attachment index, and its hook-supplied
`sessionID` becomes `providerSessionID`. Migration allocates a logical UUID for
each existing surface record once and persists the mapping; it must not
recompute logical identity from the surface or provider ID on restore. An
implementation must update that contract and its readers together before
exposing cross-surface moves. The surface UUID itself stays invariant for the
terminal's lifetime; a move changes the binding, never either surface UUID.

```text
AgentSession {
  sessionID              // cmux logical session identity
  attachment? {          // absent while detached
    surfaceID            // immutable identity of the currently attached terminal
    workspaceID          // presentation attribute, may change during restore
  }
  attachmentEpoch        // monotonic, retained across detach/attach
  agentKind              // claude | codex | acp | pi | ...
  provider               // provider family used by the adapter
  providerSessionID      // native resume/thread ID, if available
  cwd
  worktree               // optional repository/branch identity
  state                  // launching | idle | working | needsInput | ended | recovering
  version                // monotonic snapshot version
  eventSeq               // last durable event sequence
  lastActivityAt
  activeLease            // fenced runtime lease, if one exists
  parentSessionID        // set only for an explicit fork
}
```

The runtime stores an append-only event journal and periodic snapshots. Events
have a monotonic `seq`, a session `version`, an `operationID` when caused by a
client operation, and a normalized event kind. The first implementation may use
the sidecar's configured state directory, but the storage interface must allow
cmux to move authority to its own daemon later. Journal writes and snapshot
writes happen off the main actor; the UI receives parsed, `Sendable` snapshots.

The sidecar is started from a snapshot and journal tail. If its process dies,
cmux reconnects to a new sidecar, verifies the session token, and asks for
events after its last `seq`. A version gap causes a snapshot pull before any
local event is applied. Retained `ended` state remains visible so a completed
session is not mistaken for a missing one.

### Atomic surface attachment

All entrypoints use one `moveAttachment` operation containing `operationID`,
`sessionID`, expected source surface (or detached), expected attachment epoch,
and destination surface/workspace. A durable transaction must:

1. Check the current runtime lease, source binding and attachment epoch, and
   that the destination exists and is unbound. An occupied destination returns
   `surface_in_use`, including when its attached session is `ended`; it never
   overwrites that session. Repeating a committed operation returns its result.
2. Remove the old surface-index entry, set the new session attachment, insert
   the destination-index entry, increment the attachment epoch and session
   version, and append `attachment_moved` in the same commit. Enforce uniqueness
   in both directions. A detach follows the same path with no destination.
3. Publish only the committed snapshot. A crash leaves the old or new complete
   binding; recovery never constructs an intermediate state from UI caches.

The source surface becomes unbound; it does not retain a second authoritative
session record. History remains under `sessionID`. No move copies pending
prompts into a destination session. An occupied target must be explicitly
vacated first, or a new surface created.

Hook and mutation authorization must include logical session ID, surface ID,
attachment epoch and runtime lease epoch, checked against current authority.
Surface-only legacy hooks cannot support cross-surface moves: the source
producer must be quiesced, and a destination adapter restarted or issued a new
scoped binding token before it can write. Late source hooks and stale pending
input are rejected, never redirected to whatever session now occupies that
surface. Same-surface runtime handoffs preserve the attachment but still fence
writes with the new lease epoch.

### Operation identity

Every mutating client action has an `operationID` generated before transport:

```text
operationID = UUID
sessionID
kind       = prompt | interrupt | set_option | fork | handoff | resume
clientSeq  = client-local monotonic number
```

The journal and snapshots persist the following record, not just the latest
route attempt:

```text
OperationRecord {
  operationID
  state                   // accepted | started | output_started | recoverable |
                          // completed | cancelled | failed
  outputStarted           // monotonic; true before any output is exposed
  lastDurableEventSeq
  providerTurnID?
  recovery? {             // required for recoverable
    reason                // capacity | disconnect | handoff | unknown_outcome
    mode                  // native_resume | explicit_new_turn
    checkpointRef         // retained partial transcript/event checkpoint
    providerCursorRef?    // required for native_resume; protected local reference
  }
}
```

Persist output and its boundary before releasing it to a client. On a
post-output interruption, persist `recoverable` and its recovery fields before
advertising recovery or acknowledging a handoff packet. `recoverable` is a
nonterminal state that prevents automatic fresh submission; it is distinct
from a terminal `failed` result. `RouteAttempt.phase` is diagnostic and cannot
override this operation record.

Repeating an `operationID` returns the recorded result or current state; it
never submits a second provider turn. A resume action has its own deduplicated
operation ID and targets the original recoverable operation. It may transition
that operation back to `output_started` only through a provider-native,
non-duplicating continuation at the persisted cursor. Without that guarantee,
keep `explicit_new_turn` and require a user decision; preserve the partial
turn and link any new turn to it. Close the old operation as `cancelled`
before accepting that new turn, retaining its output and recovery metadata.

After a crash, reconstruct the operation from the snapshot and journal before
accepting input. An unfinished `started` or `output_started` record whose
provider outcome cannot be confirmed becomes `recoverable` with
`unknown_outcome`; lack of a completion event is not permission to replay.
A verified pre-output rejection may still use the bounded routing retry under
the original operation ID. An unconfirmed submission may not.

## Handoff packet

A handoff moves runtime ownership while preserving the logical session. It is
not a transcript copy pasted into a new chat. The source creates one durable
packet identified by `handoffID`; retries of packet delivery are idempotent.

```text
HandoffPacket {
  protocolVersion
  handoffID
  operationID
  mode                    // handoff | fork
  sessionID
  parentSessionID?        // required for fork, absent for handoff
  sourceLeaseEpoch
  destinationClaim?
  checkpoint {
    eventSeq
    sessionVersion
    providerSessionID?
    transcriptRef
    transcriptDigest?
    lastConfirmedTurnID?
    outputBoundary         // no_output | output_started | completed
    activeOperationID?     // joins the persisted OperationRecord
  }
  expectedSourceAttachment // surfaceID or detached, plus attachmentEpoch
  attachment {             // requested destination, not yet authoritative
    cwd
    worktree?
    workspaceID?
    surfaceID?
  }
  route {
    requestedModel
    capabilityPolicy
    conversationKey
    routePlane             // coderouter | subrouter | direct
    bindingHint?
  }
  pendingOperations[]      // complete nonterminal OperationRecords, including recovery
  reason                   // user_move | restart | capacity | machine_loss | operator
  createdAt
  expiresAt
}
```

The packet contains references and digests, not provider tokens, route keys,
raw prompts, or credentials. A local handoff uses an authenticated cmux
channel; a remote handoff uses a short-lived capability scoped to the session
and lease epoch. A packet is accepted only once for its `handoffID`.

### Handoff protocol

1. **Prepare.** The source changes the session to `recovering`, rejects new
   mutating operations with `handoff_in_progress`, and records the latest
   journal checkpoint.
2. **Quiesce.** The harness asks the provider to finish or cancel at a safe
   boundary. If output has not started, the provider request may be retried on
   another route only after a confirmed pre-output rejection or safe cancellation.
   An interrupted partial or unconfirmed turn is persisted as `recoverable`
   with its checkpoint and continuation mode; it is never replayed as fresh input.
3. **Persist.** The source writes the packet, transcript reference, and pending
   operation states, then acknowledges that the packet is durable.
4. **Claim.** The destination atomically claims a lease with a higher fencing
   epoch. It restores the provider session and persisted operation records
   without submitting pending prompts. A new provider session may receive the
   completed checkpoint, but any recoverable partial turn still requires the
   continuation rules above. Claiming a lease alone does not move a surface
   binding or enable input.
5. **Commit.** In one durable transaction, the destination checks its lease and
   the expected source attachment, applies `moveAttachment` (or verifies the
   unchanged binding for a same-surface handoff), and appends
   `handoff_committed`. An occupied destination aborts that transaction without
   changing either binding. It then publishes the committed versioned snapshot
   and enables input only as allowed by the restored operation state. The source
   may release resources only after observing the committed epoch.
6. **Recover.** If the destination fails before commit, the source may resume
   only while its lease epoch is still current. If the lease was superseded,
   the source must stop and let the new owner recover from the journal.

Fencing prevents two sidecars from accepting prompts for one session. A stale
source can still serve read-only history, but cannot append provider turns or
commit a conflicting handoff. A destination that has claimed the lease but
cannot attach keeps the session in `recovering`; only that lease owner can
retry attachment or explicitly transfer the lease back. The source binding
remains visible but cannot authorize stale runtime writes.

### Fork semantics

A fork is deliberately different from a handoff. It creates a new
`sessionID`, sets `parentSessionID`, and copies a checkpoint reference. The
child gets its own lease, operation namespace, route binding, and transcript
tail. A provider-native fork/resume is used when available. Otherwise the
runtime starts a new provider session from the bounded checkpoint and marks
the fork as `continuation`, so the UI does not imply shared live state.

## Capacity-aware routing

All provider and router outcomes are normalized to this internal shape:

```text
RouteAttempt {
  requestID
  operationID
  routeAttemptID
  plane                  // coderouter | subrouter | direct
  provider
  model
  accountClass?          // opaque class, never a credential or secret
  outcome                // success | capacity | rate_limited | invalid_credential |
                         // provider_unavailable | client_error | cancelled
  phase                  // pre_output | streaming | completed
  retryAfterMs?
  responseStarted
  outputStarted
  excludedOnRetry
}
```

The route envelope is attached to the runtime operation and to the handoff
packet. It lets a moved chat continue the same conversation policy without
requiring the destination to trust an old account assignment.

### Selection and recovery rules

- Before a turn, select a healthy route using the stable conversation key,
  recent headroom, expiry pressure, and a deterministic tie-break. A cooling or
  quarantined account is never selected.
- On an HTTP or streaming capacity signal before output, mark the account/model
  route cooling down, exclude it for the request, and retry within a bounded
  replay budget. Prefer the same model on another account or provider.
- A model-family or quality downgrade requires an explicit capability policy
  (`same_model_only`, `same_family`, or `allow_fallback`). The router must not
  silently turn a coding task into a materially different model.
- Once output has started, do not replay the turn. Preserve the partial output,
  mark the operation `recoverable`, and offer resume/new-turn behavior. A
  provider-specific continuation is allowed only when its protocol guarantees
  a non-duplicating resume.
- Cooldowns are adaptive and bounded. Repeated capacity events increase the
  backoff; a successful probe or a successful request clears the failure
  window. A route that remains unavailable is removed from candidate selection
  until its next health window.
- Account and model health are separate dimensions. One account may be healthy
  for one model family and unavailable for another.

The same policy applies whether the request goes through CodeRouter or
Subrouter. Each plane owns its own account pool and emits the normalized route
attempt; the runtime only consumes the outcome and safe-retry boundary.

## User-visible state and observability

The UI receives compact state transitions and can offer details on demand:

```text
working → rerouting (model capacity)
rerouting → working (same model, alternate account)
working → recovering (output started; resume required)
recovering → working (handoff committed)
recovering → needsInput (no safe route or provider resume)
```

The default message names the action and next state, not internal account
details: “The model is busy. cmux is trying another route.” If no safe fallback
exists: “This turn started producing output and cannot be replayed safely. You
can resume it or start a new turn.”

Every operation is joinable through:

```text
sessionID → operationID → handoffID? → routeAttemptID(s) → requestID → traceID
```

Telemetry records IDs, outcome, phase, attempt count, cooldown, policy, and
durations. It never records prompts, generated content, cookies, tokens, route
keys, account labels, or raw provider error bodies. Push notifications remain
best-effort; snapshots and event cursors are authoritative, as specified by
the presence and agent-session designs.

Minimum dashboards and alerts:

- percentage of turns completed without user-visible capacity errors;
- pre-output capacity recovery rate and replay count;
- output-started recovery rate and duplicate-output incidents;
- handoff prepare/claim/commit latency and expired packets;
- stale-lease/fencing rejections;
- event-journal replay gaps and sidecar restart recovery;
- route health by provider/model family, without account identity exposure.

## Phased implementation

### Phase 0: contracts and fixtures

Define the session snapshot, event, operation, route-attempt, lease, and
handoff packet schemas. Add deterministic fixtures for HTTP capacity, streaming
capacity before output, streaming capacity after output, provider disconnect,
duplicate operation delivery, and stale lease claims. Add the ID join fields to
request telemetry without changing routing behavior.

### Phase 1: durable local runtime

Replace the sidecar-only session map with a journal/snapshot store. Add
operation IDs and deduplication to `send`, `interrupt`, and option changes.
Reconnect by event sequence and pull a snapshot on a version gap. Keep the
existing normalized `AgentEvent` surface so the UI does not need provider
branches.

### Phase 2: same-host handoff and fork

Implement fenced local leases, packet persistence, source quiescing, and
destination restore. Add explicit fork lineage and separate child operation
namespaces. Exercise sidecar kill/restart and cmux surface reattachment in
integration tests before exposing remote moves.

### Phase 3: capacity-aware routing

Make CodeRouter and Subrouter emit the normalized route-attempt contract. Add
pre-output streaming inspection, adaptive cooldowns, candidate exclusion, and
policy-controlled model fallback. Surface rerouting state in agent-chat and
include route IDs in the session status detail view.

### Phase 4: cross-machine and presence integration

Move lease and packet authority to the control plane for cloud or multi-device
handoffs. Use presence as a live hint only; reconnect always pulls the
authoritative session snapshot. Add machine-router work keys ahead of cwd hash,
server-side bindings, and per-team coordination as described in the machine
router design.

### Phase 5: hardening and rollout

Run failure-injection tests, provider-specific resume compatibility tests, and
capacity canaries. Roll out by team or feature flag, compare user-visible
capacity errors and duplicate-output rates, then remove the in-memory-only
fallback once durable replay and handoff have been exercised in production.

## Acceptance criteria

The implementation is ready for broad rollout when all of the following are
demonstrated in runtime tests or production-safe canaries:

1. Killing and restarting the sidecar restores the same `sessionID`, provider
   session identity, state, transcript cursor, and last durable event without
   losing acknowledged events.
2. Repeating any mutating request with the same `operationID` never submits a
   second provider turn and returns the original or current operation result.
3. A handoff can be retried safely, commits exactly one destination lease, and
   rejects stale source writes through fencing.
4. A fork creates a new session and transcript lineage; subsequent prompts and
   route bindings cannot affect the parent.
5. An injected capacity response before output is retried on an eligible route
   and does not reach the user as “selected model is at capacity” when a safe
   route exists.
6. An injected capacity response after output has started is never replayed;
   the partial turn and recovery mode survive a sidecar crash and handoff.
   Native resume uses the saved cursor without duplication; providers without
   that guarantee require an explicit new turn. A crash with an unknown
   provider outcome cannot cause automatic replay.
7. Same-model, same-family, and no-fallback policies produce the documented
   routing behavior, including an explicit user-visible reason when no safe
   candidate exists.
8. A cross-surface move atomically removes the source binding and installs the
   destination binding without changing the logical session or surface UUIDs.
   An occupied destination, competing move, crash during commit, or delayed
   source hook cannot overwrite or cross-attach sessions. Repeating the move
   returns its original result.
9. A reconnect, missed push, or version gap converges to the authoritative
   snapshot and event sequence without showing a different conversation.
10. Session, operation, handoff, route, request, and trace IDs join in telemetry
   while prompts, output, credentials, and account identities remain absent.
11. The measured rate of user-visible transient capacity errors decreases in a
    canary, with no increase in duplicate output, cross-session attachment, or
    stale-lease incidents.

## Open decisions

- Which local journal implementation meets durability and privacy needs without
  making the cmux main actor perform file I/O?
- Which providers support a true non-duplicating continuation after output, and
  what compatibility matrix should the UI expose?
- Should the control plane own handoff packets for local sessions immediately,
  or only when a session crosses devices or cloud machines?
- What default capability policy should teams choose for coding agents that
  have materially different model quality or tool support?
- Which health and capacity signals can be probed without adding provider load?
