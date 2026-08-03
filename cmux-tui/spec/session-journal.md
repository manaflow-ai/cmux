# Session journal, hooks, and restoration

The session journal is the ordered source of truth for extensibility and
restoration. A session has one journal sequence. State projections, hook
delivery state, search indexes, and UI snapshots are derived read models.

The storage v1 implementation records durable resource mutations. This already
includes workspace, screen, pane, and tab focus; tab selection; split ratios;
viewport column widths; topology; terminal lifecycle; browser lifecycle;
frontend projections; and explicit agent reports. Hook execution, native agent
adapters, content-stream references, and restoration reducers remain proposed.

## Invariants

1. Every accepted semantic fact has one immutable record and one session-local
   sequence. Producers do not maintain private authoritative event histories.
2. A state mutation appends its record in the same SQLite transaction as its
   materialized projection and idempotency receipt. Both commit or neither
   commits.
3. Retrying one idempotency key returns the original result and does not append
   another record.
4. Journal rows cannot be updated or deleted. SQLite triggers enforce this.
   Explicit session deletion removes the session as one lifecycle operation.
5. The commit path performs one journal insert. It does not start a process,
   wait for a hook, render UI, or perform network I/O. Dispatchers tail only
   after commit.
6. Sequence is commit order. `occurred_at_ms` describes producer time and is
   never used to reorder records.
7. Every record names the stable public resources it concerns. Runtime slot
   numbers and frontend-local positions are not durable identities.
8. A record says whether restoration requires it. Observations and external
   effects are never silently replayed as state mutations.

“Everything” means every accepted semantic transition and effect outcome. It
does not mean every mouse sample, paint invalidation, terminal byte, or raw
keystroke. Those are either reduced before acceptance or stored in a dedicated
content stream and referenced by the journal.

## Record envelope

Storage v1 uses this logical envelope:

```json
{
  "sequence": 42,
  "event_id": "event_resource_00000000000000000042",
  "schema_version": 1,
  "kind": "pane.focus",
  "class": "state",
  "replay": "required",
  "occurred_at_ms": 1785715200000,
  "committed_at_ms": 1785715200000,
  "producer": {"kind": "resource_operation", "id": "client_7"},
  "authority": null,
  "causation_id": null,
  "correlation_id": "focus-request-7",
  "causation_depth": 0,
  "subjects": [
    {"kind": "session", "id": "session_..."},
    {"kind": "workspace", "id": "ws_..."},
    {"kind": "screen", "id": "screen_..."},
    {"kind": "pane", "id": "pane_..."},
    {"kind": "tab", "id": "tab_..."}
  ],
  "sensitivity": "sensitive",
  "payload": {
    "idempotency_key": "focus-request-7",
    "result": {},
    "changes": []
  },
  "resource_revision": 42,
  "previous_resource_revision": 41
}
```

`sequence` is the journal cursor. `event_id` is stable within one session and
may be used in delivery receipts. A resource mutation also carries its resource
revision so existing `session.events` consumers retain their atomic delta
cursor while migration is in progress.

`kind` is a versioned dotted semantic name. Provider-native names belong in
the adapter payload, not in `kind`. The initial agent vocabulary is:

- `agent.session.started`
- `agent.turn.started`
- `agent.turn.completed`
- `agent.approval.requested`
- `agent.question.requested`
- `agent.plan_review.requested`
- `agent.error.reported`
- `agent.state.changed`
- `agent.session.ended`

`blocked` is a derived projection over approval, question, plan-review, and
error events. It is not the only durable fact.

`class` has four values:

| Class | Meaning |
| --- | --- |
| `state` | Deterministic state transition represented by the payload |
| `observation` | A fact useful to feeds or diagnostics but not authoritative state |
| `effect` | Attempt or outcome of an external side effect |
| `checkpoint` | Versioned reducer state and content offsets at one sequence |

`replay` is `required`, `advisory`, or `never`. Restoration applies required
state and checkpoints, may expose advisory observations to adapters, and never
re-executes effect records or `never` records.

`producer` identifies the ingress adapter, authenticated client, frontend, or
internal subsystem. `authority` is present only when a capability or lease
authorizes the event. It contains principal, lease, generation, and role.

`causation_id` points to the event that caused this record. `correlation_id`
groups one operation or flow. `causation_depth` bounds recursive automation.

`subjects` is a deduplicated set. A pane event includes the pane and every
known ancestor. A move includes source and destination subjects. Consumers
filter subjects rather than scraping IDs from payloads.

`sensitivity` is `public`, `metadata`, `sensitive`, or `secret`. Subscription
authority and export redaction use this field before payload delivery.
Storage v1 conservatively marks generic resource payloads `sensitive` because
whole-resource upserts may contain names, URLs, or upstream agent session IDs.
Producer-specific redacted event shapes may lower that classification later.

## Subscription API

Consumers subscribe through the versioned resource API, never by opening the
SQLite database. `session.journal.subscribe` is trusted-local in v1. It returns
the ordinary bounded stream envelopes and a durable cursor whose `generation`
is the immutable session ID and whose `revision` is the decimal journal
sequence. Decimal strings avoid loss in JavaScript and other runtimes with
bounded integer representations.

With no starting position, a subscriber tails records committed after the
open request captures the current head. `start: "beginning"` first replays all
retained records. Reconnecting with the last delivered cursor resumes after
that record. A cursor from another session, or one ahead of the current head,
fails with `cursor.invalid`. A bounded subscriber that falls behind receives a
`gap` stream end with its last safe cursor and reconnects from that cursor.

Filters are optional. Filter dimensions are ANDed, entries within one
dimension are ORed, and filtered records still advance the cursor:

- `kinds` accepts exact dotted kinds and terminal prefixes such as `pane.*`;
- `classes` accepts `state`, `observation`, `effect`, and `checkpoint`;
- `subjects` matches a subject kind, ID, or both;
- `max_sensitivity` accepts `public`, `metadata`, or `sensitive`.
- `regex` is compiled once and matches `kind`, `subjects`, `payload`, or the
  complete record after the structured filters pass.

V1 never delivers `secret` records. Authorization and redaction must be added
before this feed is exposed over a remote transport.

The CLI is the language-neutral hook boundary. Human output prints records;
`--jsonl` prints complete stream envelopes so a consumer can persist the
cursor before performing an external effect:

```bash
cmux --session main --jsonl session current journal subscribe
cmux --session main --jsonl session current journal subscribe \
  --from beginning --kinds 'agent.*,pane.*' --classes state,observation
cmux --session main --jsonl session current journal subscribe \
  --cursor-session session_... --sequence 42
cmux --session main --jsonl session current journal subscribe \
  --kinds 'agent.*' --regex 'approval|question' --regex-field payload --ignore-case
```

Quote kind prefixes containing `*` so shells such as zsh do not expand them.
Regex uses Rust's linear-time regex engine. Patterns are limited to 1024 bytes,
compiled once per subscription, and literal searches use the engine's
vectorized prefilters when available.

One session-local fanout tailer owns the persistent read-only WAL connection.
It decodes each live record once into an 8,192-record ring shared by every
subscriber. Historical replay opens a temporary bounded reader, then joins the
shared tail. Falling behind the ring reopens a catch-up reader by cursor, so a
slow consumer does not force every consumer to reread or reparse SQLite.
Structured and compiled-regex filters run off the mutation path. Idle
subscribers wait on the fanout signal instead of polling the database. A hook
process never runs synchronously inside the journal transaction.

## Focus, layout, resize, and content

The following are replayable user intent:

- active workspace, screen, pane, and tab;
- pane and tab ordering;
- split tree and committed split ratios;
- committed viewport column widths;
- zoom, stack, and other canonical layout modes;
- canonical terminal grid size when the terminal host accepts it.

A client window size, local mirrored viewport, hover, drag preview, selection,
and scroll position belong to that frontend unless promoted by an explicit
shared-state operation. They may be journal observations for analytics or
feeds, but restoration must not treat them as session authority.

Resize gestures append accepted layout mutations. A frontend may reduce raw
pointer samples before submitting them. It must append the final accepted
value, including a no-op outcome when an operation receipt needs to explain why
no state changed.

Terminal output is a high-volume content stream, not inline journal payload.
The terminal host writes immutable chunks. Journal records bind terminal ID,
incarnation, chunk range, terminal grid, and digest to the session sequence.
A checkpoint names the exact terminal content offsets it covers. This keeps
ordering and restoration complete without copying output into every event row.

Raw keyboard input and paste contents are secret by default and are not
journaled. An audited opt-in recorder may store encrypted content references.
The ordinary record contains only the action kind, target, byte count, and
redacted outcome needed for diagnostics.

## Agent adapters and ownership

An agent adapter maps one agent runtime's native hooks into the semantic event
vocabulary. Its versioned manifest declares:

- adapter ID and executable detection;
- native hook installation and payload decoding;
- semantic event mappings;
- upstream session ID and transcript reference extraction;
- resume command construction;
- required permissions and sensitivity;
- root-process and child-process identification rules.

The native hook performs authenticated local ingress, waits only for the
journal commit receipt, and exits. Feed rendering, notifications, user hooks,
and indexing happen asynchronously from the journal cursor.

The ownership flow uses one root lease per agent session and surface:

1. Process identity resolution records PID, start time, ancestry, foreground
   process group, terminal, and surface off the UI thread.
2. Child processes may append observations and chat metadata. They never gain
   restore, hibernate, finalize, or forget authority.
3. A verified root acquires or validates the surface lease generation.
4. Hibernate appends an immutable continuation checkpoint before revalidating
   and terminating the exact root process tree.
5. Restore creates a new surface generation from the checkpoint. Its verified
   root hook reclaims the lease. Timeout preserves manual resume data.
6. Fork copies continuation intent, never the lease or inherited upstream
   session identity. The destination root acquires a new lease.
7. Finalize or forget requires explicit permanent intent and the exact lease
   generation.

Ambiguous ancestry, stale generations, and timeouts append a rejected outcome
and preserve the continuation. They do not guess.

## Hook subscriptions

A hook is a durable subscription, not an event-specific config key. A
versioned manifest contains:

```json
{
  "id": "notify-agent-question",
  "version": 1,
  "filter": {
    "kinds": ["agent.question.requested"],
    "subject_kinds": ["workspace", "pane"],
    "max_sensitivity": "sensitive"
  },
  "exec": {
    "argv": ["/usr/local/bin/notify-agent-question"],
    "timeout_ms": 5000,
    "max_parallel": 4
  },
  "delivery": {
    "start": "tail",
    "retry": {"max_attempts": 5, "backoff_ms": 250}
  },
  "permissions": ["journal.read.sensitive"]
}
```

The runner sends the complete envelope on stdin and sets only stable routing
variables such as session ID, event ID, sequence, hook ID, and attempt. It does
not flatten arbitrary payload fields into the environment. Direct `argv`
execution is the default. Shell evaluation requires a separate explicit
permission.

The dispatcher stores a materialized cursor per hook manifest version. It
appends these outcomes:

- `hook.delivery.started`
- `hook.delivery.completed`
- `hook.delivery.failed`
- `hook.delivery.abandoned`

The scheduling identity is `(hook_id, manifest_version, event_id)`. This gives
exactly-once scheduling and at-least-once process execution. External effects
must use that identity as their idempotency key if they require exactly-once
behavior.

Hook delivery events are excluded from hook filters by default. A hook cannot
receive its own causal descendants unless its manifest opts in. The dispatcher
also enforces a maximum causal depth and per-hook concurrency bound.

Manifests default to new events at installation time. Explicit `beginning` or
checkpoint cursors enable catch-up. A missing archived segment pauses delivery
with a durable gap outcome instead of silently skipping records.

## Restoration

Restoration starts from the newest compatible checkpoint, then applies every
required record through the target sequence. Reducers are versioned, pure, and
deterministic. A checkpoint contains its source sequence, reducer versions,
topology projection, agent continuations, process outcomes, terminal content
offsets, and compatibility requirements.

External effects are not repeated during replay. Their recorded outcomes
materialize state. Live-process adoption separately verifies process identity
and incarnation before reconnecting a terminal host.

Restoration should first produce an inert complete model. Process adoption,
fresh process spawning, browser reconnect, and agent resume are explicit
post-replay actions with their own journal outcomes. A partially supported
record fails with a compatibility error or becomes an explicit degraded
projection. It is never silently discarded.

## Retention and storage

Append-only does not require one SQLite file to grow forever. The active tail
stays in SQLite. Closed ranges may be sealed into immutable, checksummed
segments and replaced by an appended segment-manifest record. Checkpoints make
startup proportional to the tail after the checkpoint. Projection tables,
indexes, hook cursors, and receipts may be compacted because they can be
rebuilt.

Canonical segments are retained until explicit session deletion or an explicit
export-and-forget policy. Size pressure cannot silently delete history. Secret
content has a separate encrypted retention policy and journaled redaction
markers.

## Migration state

| Producer or consumer | State |
| --- | --- |
| Durable resource mutations | Implemented in storage v1 |
| Focus, tab selection, split ratio, viewport width | Implemented through resource mutations |
| Explicit `agent.report` projection | Implemented through resource mutations |
| v8 bounded resource-event rows | Migrated with an explicit history-completeness checkpoint |
| Legacy workspace and terminal event tables | Compatibility projections, migration pending |
| Transient `MuxEvent` observations | Classification and ingress pending |
| Terminal content chunk references | Pending |
| Agent adapter manifests and root leases | Pending |
| Hook dispatcher and delivery projections | Pending |
| Restoration reducers and checkpoint writer | Pending |

The in-memory `MuxEvent` broadcaster remains a lossy presentation mechanism.
It may wake consumers after commit, but it is never a journal or restoration
source.
