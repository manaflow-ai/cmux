# Personal orchestration through cmux Next

Status: proposed design for the cmux Next coordinator

This plan makes cmux Next a reliable command center for agent sessions without making
any one client responsible for session truth. A desktop app, mobile viewer, CLI, MCP
client, or future web client should be able to observe the same typed session state,
follow activity, and request a narrowly scoped control operation. The session host and
workspace store remain authoritative; clients are projections with an explicit intent
log.

The first useful slice is a read-only activity monitor for a long-running session. It
starts with a consistent `session.snapshot`, follows `session.events` or
`session.journal.subscribe`, and renders agent state, notifications, usage, topology,
recent output, and reconnect or gap status. Control is a later phase, introduced only
through typed operations with ownership and confirmation checks.

## Existing seams

This work composes existing cmux Next work rather than replacing it. On
`feat-cmux-next` today:

- The acpmux protocol registry (`cmux-tui/crates/acpmux/src/protocol/`) names every
  served method and notification and is committed as `spec/acpmux-protocol.json`;
  the web generates its typed client from that file. `_acpmux/attach`, `detach`,
  `view`, `markUnread`, `watch`, `events`, and the `_acpmux/event` notification are
  listed, but all of them are still untyped (`params` and `result` accept any
  JSON). Clients read the committed file at build time. `_acpmux/schema` serves the
  hand-written `docs/acpmux-schema.json` at runtime; nothing serves the registry.
- [#20929](https://github.com/manaflow-ai/cmux/pull/20929) added
  `_acpmux/complete`: one cheap, headless LLM text completion through the user's own
  harness login (hq#1957, used for auto-naming). It takes a short prompt and returns
  `{ text, harness, model }`, creates no chat session, keeps no record, and is
  accepted only over the local unix socket. It is not an operation-completion
  receipt and carries no operation id, final state, or journal sequence.
- [#20924](https://github.com/manaflow-ai/cmux/pull/20924) lists the MCP servers a
  session's harness loaded in its summary, which gives a viewer enough context to
  explain what the session can do. Only Claude Code reports them today; ACP agents
  and the Codex bridge report none.

Still open, not in code:

- [#20894](https://github.com/manaflow-ai/cmux/pull/20894) types attach, events,
  detach, view, markUnread, watch, and `_acpmux/event` in the registry.
- [#20912](https://github.com/manaflow-ai/cmux/pull/20912) would serve the protocol
  IR at runtime through `_acpmux/protocol`, so a client can discover methods and
  their schemas from the daemon it is connected to.
- [#16279](https://github.com/manaflow-ai/cmux/pull/16279) is the proposed
  orchestrator seam for chat, memory, code mode, and link operations.

Where this plan relies on one of the open PRs, it says so.

The cmux-tui contract already provides the daemon lifecycle, raw and typed protocol
surfaces, event-driven waits, and capability negotiation. The Swift client side has
`ControlSessionInfo` for stable session identity and `ControlSnapshot` for immutable,
off-main read-only queries. `plans/cmux-next/control-snapshot-topology.md`,
`plans/cmux-next/cmux-tui-contract.md`, and
`plans/cmux-next/OWNERSHIP-PRINCIPLES.md` remain the binding design references.

## Goals

1. Give every supported client one typed, versioned way to discover sessions,
   capabilities, ownership, activity, and safe actions.
2. Make a read-only activity monitor useful before control is enabled: a user can see
   what is running, what changed, what needs attention, and whether the stream is
   complete.
3. Add orchestration as explicit parent and child operations. Fan-out must be visible,
   bounded, cancellable, and attributable; completion must be a typed receipt rather
   than an inferred lack of output.
4. Preserve the state rules: the session host owns process and transcript facts, the
   workspace store owns shared layout, and each client owns its view state.
5. Keep command-center clients small and responsive. They consume snapshots and event
   streams, do not build or run a second session host, and do not poll for changes.
6. Reserve resource capacity for the command center and its transport. A busy agent or
   a large historical replay must not starve the UI, control socket, or event journal.

## Non-goals for the first release

- No unrestricted remote shell, arbitrary command execution, or pass-through harness
  parameters from a viewer.
- No client-side session database that can diverge from the host.
- No implicit child-agent creation when a prompt is observed.
- No focus stealing, selection changes, or scrolling another client as a side effect
  of automation.
- No requirement that a lightweight client compile the native cmux app. Native and
  other build-heavy verification belongs on managed builders or explicitly enrolled
  hosts.

## Contract and data flow

### Discovery and identity

A client begins with `initialize`, advertises its client kind and supported
capabilities, and reads the daemon and ACPMUX capability sets. Typed method
descriptions and the protocol version come from the committed protocol IR today;
once `_acpmux/protocol` (#20912) lands, the client reads them from the connected
daemon instead, so it can disable an operation that daemon does not serve and say
why. Every request includes a client identity, an
idempotency key, a parent operation id when applicable, and an origin (`user`, `cli`,
`mcp`, `script`, or `remote`). `ControlSessionInfo` carries the stable session and
host identity across reconnects; it is never reconstructed from a window title or a
transient process id.

The local socket keeps its user-only trust boundary. Remote connections require the
configured authenticated identity and are checked against the session and record
owner before a write. A capability is an affordance, not authorization: a client may
show a control only after the owner and policy checks say it is available.

### Snapshot, stream, and journal

The initial read is one `session.snapshot` at a known sequence and generation. It
contains the session summary, agent summaries, notification summary, usage/context
when available, topology references, and the last journal cursor. The client then
subscribes to `session.events` or `session.journal.subscribe` from that cursor.

The event reducer applies only monotonic sequence numbers. A duplicate is harmless; a
gap or generation change marks the view as incomplete and triggers one bounded
resnapshot. Reconnect resumes from the last acknowledged cursor. The client keeps a
bounded activity ring for rendering and diagnostics, while the host remains the
source of truth for the full journal. Redaction is applied at the host boundary so a
viewer never receives tokens, credentials, secret values, or hidden prompt content
merely because it subscribed to activity.

`ControlSnapshot` is the Swift read-only projection used by CLI and UI queries. It is
published atomically after model settle and read off the main actor. The activity
view consumes the same projection and event reducer as status commands, preventing
separate implementations from drifting.

### Activity monitor

The monitor is a projection, not a second scheduler. It shows:

- session identity, host reachability, lifecycle, and last event sequence;
- agent identity, state, parent operation, current phase, and last meaningful update;
- pending permission or user-attention requests, with the safe response surface;
- usage/context and loaded capability summaries when the host provides them;
- child operations and their receipts, including queued, running, completed,
  cancelled, failed, and unknown-after-disconnect states;
- transport health, reconnect count, event gaps, and the cursor used for recovery.

Updates are event-driven. A one-shot deadline may wake a stale-state indicator, but
there is no periodic polling loop. The view can be rendered by the desktop app,
iOS, or another client without changing session ownership.

### Fan-out and follow-on work

Fan-out is a typed coordinator operation with a bounded child budget. The parent
records the requested capability, target session, child ids, and cancellation policy
before any child starts. Each child has an owner, origin, idempotency key, and parent
id; its lifecycle is represented in the event stream. A child cannot silently escape
its parent scope or inherit a stronger capability than the parent was granted.

Follow-on work uses the same operation record. Each operation ends in a completion
receipt containing the operation id, final state, result summary, and journal
sequence. This receipt is new work: no current method returns one, and
`_acpmux/complete` is unrelated (it is a one-shot text completion with no
operation record). The receipt is durable enough
for a reconnecting client to distinguish completed, cancelled, failed, and unknown
work. A parent completion is valid only after all required children have receipts or
an explicit cancellation/partial-result policy.

The coordinator applies backpressure: a bounded queue, per-parent child limit,
per-session concurrency limit, and cancellation propagation prevent a command center
from consuming all host capacity. A client may request a larger limit only through a
policy-controlled setting; the default is conservative and visible in capability
metadata.

## Control phases and safety boundaries

Every control feature follows five phases:

1. **Inspect**: read the current snapshot, capability declaration, ownership, and
   policy. No side effects.
2. **Propose**: construct a typed operation with stable ids, scope, expected
   revision, and an idempotency key. Show the affected sessions and child work.
3. **Confirm**: require a fresh user gesture for actions that can start work, write
   files, change policy, alter ownership, or spend capacity. A remote viewer cannot
   satisfy a local gesture requirement by replaying a request.
4. **Execute**: the owner validates and commits the operation through its reducer.
   Destructive decisions happen in that commit, not in a client diff.
5. **Observe**: return the transaction receipt and stream the resulting events until
   the operation reaches a terminal state or a bounded unknown state.

Read-only inspection and activity subscriptions are safe by default. A remote
connection cannot add MCP servers, pass arbitrary environment or harness arguments,
change another client's focus, or address an object outside its authorized scope.
Folder and resource references are canonicalized and owner-checked before execution.
All replies are redacted at the boundary, and protocol errors identify the missing
capability, policy, or ownership condition without exposing secret parameters.

## Capacity isolation

The command center has a separate resource budget from the sessions it observes.
Transport, snapshot reduction, and activity rendering use bounded queues and bounded
memory. Historical replay is paged on the bulk path and cannot block interactive
control or terminal bytes. Fan-out and follow-on workers have explicit per-parent,
per-session, and global limits, with queue depth and rejection reasons in the activity
stream.

A lightweight command-center client remains build-free and can run on a phone or a
small host. Native cmux compilation, integration tests, and other build-heavy checks
run on managed builders or explicitly enrolled hosts with reusable caches. A client
must never start an unbounded native build as a side effect of opening an activity
view. Resource reservations and limits are surfaced through capability metadata so a
user can see why work is queued or refused.

## Delivery phases

### P0: contract and fixtures

- Add a shared fixture set for snapshot, event, journal cursor, capability, ownership,
  fan-out, cancellation, gap, reconnect, and completion-receipt cases.
- Specify the typed fields and redaction rules in the ACPMUX protocol IR (building
  on the types #20894 adds for attach, events, view, and watch).
- Define the operation state machine and parent-child invariants in the reducer model.

### P1: read-only monitor

- Implement the snapshot-plus-stream client using `ControlSnapshot` and
  `ControlSessionInfo`.
- Add event-gap recovery, bounded activity history, lifecycle/usage/notification
  sections, and visible reconnect state.
- Expose the same monitor data through the CLI's JSON output and the MCP read surface,
  with action-surface declarations or explicit exemptions.

### P2: safe control

- Add inspect/propose/confirm/execute/observe receipts for one low-risk operation.
- Enforce origin, owner, expected revision, idempotency, and fresh-gesture rules.
- Add tests proving that automation does not change another client's focus or
  selection and that a rejected operation has no partial state.

### P3: bounded orchestration

- Add parent-child fan-out, cancellation propagation, bounded concurrency, and
  operation completion receipts.
- Show child progress and partial completion in every monitor surface.
- Add policy controls for per-session and per-parent capacity with safe defaults.

### P4: additional clients

- Reuse the same protocol and fixtures for iOS and other remote viewers.
- Add reconnect and background/foreground behavior without making a mobile client a
  session owner.
- Promote only the capabilities that have an owner, policy, redaction, and verified
  receipt path.

## Acceptance criteria

- A client can discover protocol and daemon capabilities, obtain a consistent
  `session.snapshot`, and resume `session.events` or `session.journal.subscribe`
  after reconnect without duplicate visible activity.
- A sequence gap or generation change is visible, causes one bounded resnapshot, and
  cannot silently produce a false "current" state.
- Agent, notification, usage, topology, and child-operation activity are rendered
  from typed events and remain attributable to a session, parent, child, and origin.
- Fan-out respects configured child and concurrency limits; cancellation reaches
  queued and running children; completion receipts distinguish success, cancellation,
  failure, and unknown-after-disconnect.
- Every write has an authenticated identity, owner check, expected revision, and
  idempotency key. Unauthorized objects and unsupported capabilities are refused with
  stable machine-readable errors.
- Remote and automated clients never steal focus, selection, or scroll; destructive or
  capacity-consuming actions require the documented confirmation phase.
- Secret-bearing fields are redacted before leaving the host, and journal retention is
  bounded and configurable.
- Idle clients use event subscriptions rather than polling; bounded memory and queue
  limits are observable in the monitor.
- Lightweight clients require no native build. Build-heavy verification receipts name
  the managed builder or enrolled host, source revision, daemon tree key, and checks
  run; no native build is required on a command-center client.

## Verification plan

Portable verification runs first:

- protocol schema/conformance fixtures for initialize, capability discovery, snapshot,
  events, journal cursors, fan-out, cancellation, and completion;
- pure reducer/property tests for sequence ordering, idempotency, ownership, parent
  and child invariants, and bounded capacity;
- Swift tests for `ControlSnapshot` publication, `ControlSessionInfo` identity,
  off-main reads, gap recovery, redaction, and no-focus-steal behavior;
- CLI/MCP contract tests for stable ids, `--json`, machine-readable errors, and
  action-surface coverage;
- static checks for no polling loops, no unbounded activity buffers, no private host
  details in public plans, and no unsupported capability references.

Then run the focused cmux Next package and daemon suites on managed builders or
explicitly enrolled hosts. A tagged end-to-end run should exercise snapshot, live
activity, a permission or attention event, one bounded follow-on, disconnect/reconnect,
and a completion receipt. Record the source revision, daemon capability set, event
sequences, redaction result, queue limits, and build receipt. Do not claim a native
build or live client verification from a lightweight command-center machine.

## Open decisions

- Which low-risk control operation is the first P2 pilot and which actions require a
  local fresh gesture even when requested by an authenticated account.
- Whether the activity ring is shared in the daemon or remains a per-client projection
  while the durable journal stays host-owned.
- The default child and session concurrency limits for each supported client class.
- Which completion results may be retained in the journal and for how long.
