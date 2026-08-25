# Session journal, hooks, and restoration

The session journal is the ordered source of truth for extensibility and
restoration. A session has one journal sequence. State projections, hook
delivery state, search indexes, and UI snapshots are derived read models.

Storage v1 records durable resource mutations, schema-validated producer
events, hook manifests and delivery outcomes, checkpoints, and sealed history
segments. Resource mutations include workspace, screen, pane, and tab focus;
tab selection; split ratios; viewport column widths; topology; terminal and
browser lifecycle; continuous terminal output and geometry; frontend focus,
viewport, and geometry observations; frontend projections; explicit agent
reports; and normalized native agent-hook observations. A pure restoration
reducer can preview the state reconstructed from a checkpoint and its tail,
and a restarted server reconstructs the durable topology, representing
terminals whose processes died while it was down honestly as exited, with
their renderable content applied from the newest checkpoint and the reducible
output tail. Verified root ownership leases and post-restore respawn actions
remain pending.

## Invariants

1. Every accepted semantic fact has one immutable record and one session-local
   sequence. Producers do not maintain private authoritative event histories.
2. A state mutation appends its record in the same SQLite transaction as its
   materialized projection and idempotency receipt. Both commit or neither
   commits.
3. An accepted external effect gets exactly one durable outcome. A
   state-changing success uses its state record; a receipt-only success,
   definite failure, or indeterminate execution appends a non-replayable
   `effect` record in the receipt transaction.
4. Retrying one idempotency key returns the original result and does not append
   another record.
5. Logical records cannot be updated or deleted. SQLite triggers protect both
   active rows and sealed segments. Sealing moves a checkpoint-covered prefix
   into an immutable checksummed segment without changing its records.
6. The commit path performs one journal insert. It does not start a process,
   wait for a hook, render UI, or perform network I/O. Dispatchers tail only
   after commit.
7. Sequence is commit order. `occurred_at_ms` describes producer time and is
   never used to reorder records.
8. Every record names the stable public resources it concerns. Runtime slot
   numbers and frontend-local positions are not durable identities.
9. A record says whether restoration requires it. Observations and external
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
- `agent.child.spawned`
- `agent.child.completed`
- `agent.child.failed`
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
Storage v1 rejects `secret` producer schemas and ingress overrides because it
does not have encrypted retention. The enum reserves that future policy.

## Subscription API

Consumers subscribe through the versioned resource API, never by opening the
SQLite database. `session.journal.subscribe` returns ordinary bounded stream
envelopes and a durable cursor whose `generation` is the immutable session ID
and whose `revision` is the decimal journal sequence. Decimal strings avoid
loss in JavaScript and other runtimes with bounded integer representations.

With no starting position, a subscriber tails records committed after the
open request captures the current head. `start: "beginning"` first replays all
retained records. Reconnecting with the last delivered cursor resumes after
that record. A cursor from another session, or one ahead of the current head,
fails with `cursor.invalid`. A bounded subscriber that falls behind receives a
`gap` stream end with its last safe cursor and reconnects from that cursor.
Successful bounded replay queues its final `stream_end` after every admitted
record, so completion cannot overtake or discard the replay tail. Overflow and
cancellation remain destructive. `start` and `cursor` are mutually exclusive.

Each committed subject is also inserted into an append-only
`(kind, id, sequence)` index in the record transaction. Retained catch-up for
exact subjects, such as one `agent_tree`, reads only matching sequences. Live
delivery uses the bounded in-memory fanout and checks each new record once.

Filters are optional. Filter dimensions are ANDed, entries within one
dimension are ORed, and filtered records still advance the cursor:

- `kinds` accepts exact dotted kinds and terminal prefixes such as `pane.*`;
- `classes` accepts `state`, `observation`, `effect`, and `checkpoint`;
- `subjects` matches a subject kind, ID, or both, and every entry contains at
  least one of those fields;
- `max_sensitivity` accepts `public`, `metadata`, or `sensitive`, with each
  threshold including lower levels. Omission defaults to `metadata` on every
  transport. A trusted local Unix client can explicitly request `sensitive`;
- `regex` is compiled once and matches `kind`, `subjects`, `payload`, the
  complete record, or exact decoded `terminal_output` bytes after structured
  filters pass.

No subscription delivers `secret` records. Unix-socket clients may request up
to `sensitive`. WebSocket clients are capped at `metadata`; their authority,
causation, and correlation fields are redacted, and remote regex filters may
inspect only `kind` or `subjects`. WebSocket token authentication and the
explicit non-loopback bind policy remain the transport authorization boundary.
Producer, hook, checkpoint, restoration, and segment operations require the
trusted local Unix transport.

The CLI is the language-neutral hook boundary. Human output prints records;
`--jsonl` prints complete stream envelopes so a consumer can persist the
cursor before performing an external effect:

```bash
cmux --session main --jsonl session current journal read
cmux --session main --jsonl session current journal read \
  --kinds 'agent.*' --regex 'approval|question' --regex-field payload --ignore-case
cmux --session main --jsonl session current journal subscribe
cmux --session main --jsonl session current journal subscribe \
  --kinds agent.turn.completed
cmux --session main --jsonl session current journal subscribe \
  --from beginning --kinds 'agent.*,pane.*' --classes state,observation
cmux --session main --jsonl session current journal subscribe \
  --cursor-session session_... --sequence 42
cmux --session main --jsonl session current journal subscribe \
  --kinds 'agent.*' --regex 'approval|question' --regex-field payload --ignore-case
cmux --session main --jsonl session current journal subscribe \
  --kinds terminal.output --regex 'error|failed' --regex-field terminal_output --ignore-case
```

`journal read` prints retained history through the head captured when the
command opens, then exits. `journal subscribe` tails new events; add
`--from beginning` to replay retained history before following. Keep the final
cursor from each JSONL item and resume with
`--cursor-session <session-id> --sequence <sequence>`. A client connected to a
resident process that predates journal capability negotiation receives
`operation.unsupported` with an instruction to restart that named session,
instead of the older `validation.invalid` envelope error.

Quote kind prefixes containing `*` so shells such as zsh do not expand them.
Regex uses Rust's linear-time regex engine. Patterns are limited to 1024 bytes,
compiled once per subscription, and literal searches use the engine's
vectorized prefilters when available. A regex inspects only its selected field:
`--regex-field payload` does not inspect `kind`. Filter completions with
`--kinds agent.turn.completed`, or use `--regex-field record` when one regex
must inspect both kind and payload.

One session-local fanout tailer owns the persistent read-only WAL connection.
It decodes each live record once into a ring bounded by 8,192 records and a
128 MiB resident-size estimate, shared by every subscriber. Historical replay
opens a temporary bounded reader, then joins the
shared tail. Falling behind the ring reopens a catch-up reader by cursor, so a
slow consumer does not force every consumer to reread or reparse SQLite.
Structured and compiled-regex filters run off the mutation path. Idle
subscribers wait on the fanout signal instead of polling the database. A hook
process never runs synchronously inside the journal transaction.

## Producer ingress

A producer installs a versioned manifest before appending namespaced events:

```bash
cmux --session main --jsonl session current journal producer put \
  --idempotency-key demo-producer-v1 \
  --manifest-json '{
    "producer_id":"demo",
    "namespace":"plugin.demo",
    "manifest_version":1,
    "max_sensitivity":"metadata",
    "permissions":["journal.append.plugin.demo"],
    "events":[{
      "kind":"plugin.demo.task_finished",
      "schema_version":1,
      "class":"observation",
      "replay":"advisory",
      "sensitivity":"metadata",
      "payload_schema":{
        "type":"object",
        "required":["task_id"],
        "properties":{"task_id":{"type":"string"}},
        "additionalProperties":false
      }
    }]
  }'

cmux --session main --jsonl session current journal append \
  --idempotency-key demo-task-42-finished \
  --event-json '{
    "producer_id":"demo",
    "manifest_version":1,
    "kind":"plugin.demo.task_finished",
    "schema_version":1,
    "subjects":[{"kind":"workspace","id":"ws_..."}],
    "payload":{"task_id":"42"}
  }'
```

The manifest schema is compiled once and cached by the session journal kernel.
Ingress validates namespace, schema version, sensitivity authority, payload
size, subjects, and causation depth before the transaction. An idempotency key
returns the original event receipt on retry. A causation ID must name an
existing event and advances the bounded causal depth.

Trusted local journal mutations use the stable owner of the owner-only Unix
socket as their receipt principal, not a transient connection ID. Repeating a
CLI command after reconnect with the same key and payload therefore returns
the original receipt; reusing that key with different input is a conflict.

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

The built-in TUI submits focus paths, accepted outer geometry, and viewport
targets through an off-UI worker. Events use stable public resource IDs and one
frontend generation. Viewport animation records intent and settlement, not
every rendered frame.

Resize gestures append accepted layout mutations. A frontend may reduce raw
pointer samples before submitting them. It must append the final accepted
value, including a no-op outcome when an operation receipt needs to explain why
no state changed.

Terminal output is a high-volume content stream, not inline journal payload.
The PTY reader copies accepted output only when journaling is enabled, releases
the terminal lock, and sends it through a dedicated bounded terminal lane to
the single journal writer. That writer coalesces adjacent chunks up to 256 KiB,
assigns generation-local byte offsets, and stores the exact bytes accepted by
the authoritative terminal parser in SQLite BLOBs. JSON wire and sealed-segment
forms use base64; storage and regex matching use those parser input bytes.
Accepted geometry changes use the same FIFO terminal lane.

External producers and durable frontend observations use a second bounded
lane. One coalesced wake signal drives both lanes; each batch reserves capacity
for up to 4 MiB of terminal ingress and 8 MiB of resident producer payloads,
then gives both lanes another turn. Saturating the agent lane therefore cannot
occupy the terminal lane or block the PTY reader. Byte order is strict within
the terminal lane, durable producer order is strict within the producer lane,
and the writer assigns commit order when independent lanes race.

Lossless terminal capture can still backpressure the PTY after its own bounded
lane fills during a prolonged storage stall. Removing that final bound requires
an acknowledged durable output spool or an explicit loss policy at the
terminal-host boundary. Moving the same queue into another process does not
remove the storage bound.

The checkpoint writer captures each terminal under its terminal lock as a
bounded VT replay blob, compresses it with deterministic gzip, and stores it by
SHA-256 content ID. The checkpoint records terminal ID, grid, format, digest,
and byte count. Restoration applies later output chunks and geometry changes in
sequence after that checkpoint.

Raw keyboard input and paste contents are secret by default and are not
journaled. An audited opt-in recorder may store encrypted content references.
The ordinary record contains only the action kind, target, byte count, and
redacted outcome needed for diagnostics.

## Agent adapters and ownership

An agent adapter maps one agent runtime's native hooks into the semantic event
vocabulary. The built-in `cmux_agent` producer accepts native JSON through the
CLI, preserves only structural string fields and non-string structure before
it stores the provider shape under `payload.native`, and stores common session,
turn, directory, transcript, tool, and agent topology fields under
`payload.normalized`. Content strings and credential fields are redacted.
Unknown native events become `agent.state.changed`:

```bash
printf '%s\n' '{"session_id":"abc","message":"done"}' | \
  cmux --jsonl agent hook emit --source codex --event Stop
```

Terminal children inherit stable session and terminal IDs. The adapter adds
the terminal subject, and journal ingress resolves its tab, pane, screen, and
workspace ancestors transactionally. Agent hooks outside a TUI terminal may
omit the terminal subject while retaining their native session identity.

Agent topology is an incremental forest. A stable opaque `agent_tree_id`
groups one provider root session. `agent_node_id` identifies the emitting or
spawned agent, and `parent_agent_node_id` records an explicit parent when the
provider supplies one. The same values are indexed as `agent_tree`,
`agent_node`, and `agent_parent` subjects. `SubagentStart` and
`SubagentStop` normalize to `agent.child.spawned` and
`agent.child.completed`. A consumer updates the tree with constant work per
record and can fetch one tree through its indexed subject instead of scanning
payload JSON.

Native agent, parent, root, session, depth, name, and type fields remain in
the normalized projection. The provider object remains under `payload.native`
after recursive content and credential-field redaction. Adapters accept common
snake-case, camel-case, and nested event/context forms. When a provider
omits parent identity, the event is marked `agent_relation: "unknown"` and no
parent edge is invented. This keeps parallel or nested children as explicit
orphans until a later provider event supplies the relationship.

Provider contracts may supply a safe structural invariant. Claude Code, for
example, supplies a stable child ID but no parent ID and does not permit its
subagents to spawn subagents, so its adapter attaches those children to the
shared session root with `agent_relation: "provider_root"`. This inference is
adapter-owned and versioned. Providers without that guarantee remain
orphans; names or event order never become parent evidence.

Coding-agent hooks invoke the purpose-built `cmux-tui-hook` helper. It reads
at most 1 MiB, shares the core normalizer, sends one mutation over the resident
session socket, waits for the durable receipt with a bounded timeout, and
exits. It does not initialize the TUI frontend. The main terminal process owns
only the bounded socket handler and single-writer journal actor; provider hook
execution remains in the provider's external process.

The helper allows four seconds for the complete journal receipt. Installed
command providers allow at least five seconds, so their outer timeout cannot
cancel an event before the journal's two-second commit-admission window ends.

Install, inspect, or remove all detected provider adapters with:

```bash
cmux agent hook install
cmux agent hook status
cmux agent hook uninstall
```

Coding-agent hook management is supported only on Unix systems. Other
platforms reject these commands instead of installing provider files that
cannot run.

Providers load hook configuration at process start. After installation, launch
a new agent or restart an existing agent inside a cmux-tui terminal so it
inherits `CMUX_TUI_SOCKET` and `CMUX_TUI_TERMINAL_ID`. Hooks invoked outside a
cmux-tui terminal intentionally consume their provider input and exit without
appending to an arbitrary session.

An explicit provider list limits the operation, for example
`cmux agent hook install codex claude gemini`. The built-in set is Codex,
Claude Code, Gemini CLI, Cursor Agent, Grok, Hermes Agent, OpenCode, Amp, and Pi. Installation
copies the matching `cmux-tui-hook` beside the CLI into the stable user data
directory, then atomically merges command-hook configuration or installs one
owned plugin file. Existing unrelated hooks remain in place. Reinstallation is
idempotent, legacy cmux-tui journal shims are migrated, and an unrecognized
file at an owned plugin path is never overwritten.

Command-hook providers wait for only the helper's bounded durable receipt.
Plugin providers return from their callback immediately and let an external
helper child finish that same bounded receipt. Provider work, normalization,
SQLite writes, and downstream hook execution never run on the PTY reader,
terminal parser, render, or frontend input threads.

Plugin adapters subscribe to finite semantic transitions, not provider token
or message-part deltas. The terminal lane already retains the visible byte
stream, while a process per model token would duplicate content and create an
unbounded process fan-out. OpenCode's adapter also carries its observed session
ancestry beside the untouched native event so nested session trees retain root
and parent edges across arbitrary depth. Grok receives one native adapter;
guards on its Claude and Cursor compatibility imports prevent duplicate events
with misidentified providers.
Hermes uses a separately enabled, owned plugin; installation removes the
journal half of a recognized legacy cmux-irc tee while preserving cmux-irc's
native plugin.

A provider-specific adapter manifest declares:

- adapter ID and executable detection;
- native hook installation and payload decoding;
- semantic event mappings;
- upstream session ID and transcript reference extraction;
- resume command construction;
- required permissions and sensitivity;
- root-process and child-process identification rules.

The native hook performs authenticated local ingress, waits only for the
journal commit receipt, and exits. Each invocation gets a fresh idempotency key
unless the provider supplies a stable delivery identity explicitly, so two
byte-identical turn completions remain two records. Feed rendering,
notifications, user hooks, and indexing happen asynchronously from the journal
cursor.

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
  "hook_id": "notify-agent-question",
  "manifest_version": 1,
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

Install and inspect manifests through the local resource API:

```bash
cmux --session main --jsonl session current journal hook put \
  --idempotency-key notify-agent-question-v1 --manifest-json '<manifest-json>'
cmux --session main --jsonl session current journal hook list
```

The runner sends the complete envelope on stdin and sets only stable routing
variables for session ID, event ID, sequence, hook ID, hook version, attempt,
causation ID, and correlation ID. It does not flatten arbitrary payload fields
into the environment. Execution uses an absolute `argv`, an empty inherited
environment, no shell, and bounded timeout and concurrency. Shell evaluation
is not supported.

The hook process scope uses a kernel fence before any hook instruction runs.
Linux descendants inherit a seccomp rule that rejects `setsid` and `setpgid`,
so they cannot leave the scope's process group. macOS denies `process-fork`, so
a macOS hook executable must do its work in one process and cannot start a
subprocess. These restrictions make timeout and shutdown cleanup independent
of environment variables or inherited file descriptors that a hook can clear.

The dispatcher stores a materialized cursor per hook manifest version. It
appends these outcomes:

- `hook.delivery.started`
- `hook.delivery.completed`
- `hook.delivery.failed`
- `hook.delivery.abandoned`

One session dispatcher schedules a fixed pool of 4 through 32 workers, derived
from available parallelism. Each worker owns one external child process at a
time, writes its bounded stdin without a helper thread, and returns its result
to a batched SQLite transition. Slow hooks therefore consume bounded child and
thread counts without running on the terminal, journal-ingress, or SQLite
writer threads. High-volume extensions should keep one `journal subscribe`
stream open instead of spawning one hook process per terminal-output record.

The scheduling identity is `(hook_id, manifest_version, event_id)`. This gives
exactly-once scheduling and at-least-once process execution. External effects
must use that identity as their idempotency key if they require exactly-once
behavior.

Hook delivery events are excluded from hook filters by default. Hook-invoked
`cmux ... journal append` commands automatically inherit the scoped causation
ID, correlation ID, and hook subject. The event index carries that hook marker
through later causal descendants, so the dispatcher excludes them with an
indexed lookup unless the manifest opts in. The dispatcher also enforces a
maximum causal depth, a per-hook concurrency bound, and a session-wide bound.

Manifests default to new events at installation time. `start: "beginning"`
enables full catch-up. Immutable sealed segments remain transparent to the
dispatcher and ordinary subscribers.

## Restoration

Restoration starts from the newest compatible checkpoint, then applies every
required record through the target sequence. The implemented v1 reducer is
pure and deterministic. A checkpoint contains its source sequence, reducer
version, public session projection, producer and hook manifests, and terminal
content references. `journal restore preview` returns the projected model,
digest, applied count, and every unsupported required record. It never mutates
the live session.

External effects are not repeated during replay. Their recorded outcomes
materialize state. Live-process adoption separately verifies process identity
and incarnation before reconnecting a terminal host.

Server startup applies the restored topology: workspace identity, order, and
names; screens; split trees with committed ratios and viewport column widths;
and tab placements. Startup rebuilds it from the transactional projections
that invariant 2 keeps equal to the journal head, so the applied state and a
restore preview at the same head agree. A terminal whose process died while
the daemon was down is latched as exited with the first observed outcome and
keeps its journaled placements: restoration never respawns a process, never
pretends to reattach a dead one, and never discards layout on behalf of a
process it did not observe exiting. An exit the daemon observes live still
detaches that terminal's views in the same transaction. Explicit close of a
restored exited terminal, and future respawn actions, are ordinary post-restore
mutations with their own journal outcomes.

Cold start also materializes each restored exited terminal as an inert
surface whose renderable content is applied from the journal: the terminal's
VT replay blob in the newest checkpoint, then the exact parser-accepted
`terminal.output` bytes and accepted `terminal.resized` geometry after that
checkpoint, validated with the same digests and per-generation offset
contiguity the preview reducer enforces. A `terminal.output.gap`, an offset
discontinuity, or an exceeded replay budget stops the applied tail at the
last provably complete event; the projection renders what is proven and never
guesses at missing bytes. A terminal absent from the newest checkpoint is
rebuilt from its full journaled output history when one exists. Each
materialization appends a `terminal.restore.applied` effect record (replay
`never`) naming the source checkpoint, applied tail counters, and any
degradation, so the post-replay action carries its own journal outcome
without changing what restoration must reduce.

Hosts created before the source-ordered detach protocol remain available in a
compatibility mode. Their live output is not added to the journal because an
old host cannot fence output at daemon shutdown. New protocol-v4 hosts use the
normal durable output path, and the compatibility mode ends when the old
terminal exits.

If a protocol-v4 host does not return its detach receipt before the shared
shutdown deadline, or an active parser update exceeds its shutdown grace, the
old daemon appends a required `terminal.output.gap` record after its reader
stops and before the terminal ingress barrier. The record names the terminal
runtime generation and uses `cmux.terminal-output-gap.v1` with reason
`detach_fence_failed` or `active_update_timeout`. A restore preview treats this
required kind as unsupported, so it cannot report a fully reducible tail that
can contain missing source bytes. The daemon always attempts the final terminal
barrier, closes both journal admission lanes, drains accepted records, and joins
the journal writer through a fixed shutdown deadline. If an already admitted
SQLite commit does not finish inside that final deadline, shutdown detaches the
writer instead of waiting without a limit. The transaction continues to own the
registry and its atomic idempotency receipt until SQLite returns; a later retry
therefore observes the committed receipt or performs the request once.

Live restoration will consume this inert complete model. Process adoption,
fresh process spawning, browser reconnect, and agent resume are explicit
post-replay actions with their own journal outcomes. A partially supported
record fails with a compatibility error or becomes an explicit degraded
projection. It is never silently discarded.

Create and inspect checkpoints, preview a reduction, then seal a covered
prefix:

```bash
cmux --session main --jsonl session current journal checkpoint create \
  --idempotency-key checkpoint-1
cmux --session main --jsonl session current journal checkpoint list
cmux --session main --jsonl session current journal restore preview \
  --checkpoint latest
cmux --session main --jsonl session current journal segment seal \
  --through <checkpoint-source-sequence> --idempotency-key segment-1
cmux --session main --jsonl session current journal segment list
```

## Retention and storage

Append-only does not require one SQLite table to grow forever. The active tail
stays as indexed rows. `journal segment seal` moves only a checkpoint-covered
prefix into deterministic gzip JSON segments of at most 1,024 records or 16
MiB uncompressed, verifies their SHA-256 digests on read, preserves the causal
event index, and appends a segment-manifest record. Segment selection,
serialization, compression, and digesting happen before the writer transaction.
The short commit revalidates the prepared range, inserts immutable segments,
deletes the covered active rows, and appends the manifest atomically. Reads,
subscriptions, hooks, and reducers cross active
and sealed ranges transparently. Projection tables, hook cursors, and receipts
may be compacted because canonical records remain rebuildable.

SQLite is the durable ordering boundary because the journal record, state
projection, and idempotency receipt can commit in one transaction. WAL permits
the shared read tailer to run concurrently with the single serialized writer.
Concurrent durable producer requests enter that writer's bounded producer lane
and share a transaction while retaining one result and idempotency receipt per
request. A separate bounded terminal lane isolates parser ingress while the
same writer gives terminal output, frontend observations, and producer events
one commit-order boundary instead of competing SQLite writers.
The public stream is asynchronous, while blocking SQLite work stays on the
session writer or dedicated read workers. An async SQLite wrapper would move
the same synchronous SQLite calls onto another worker and add scheduling hops;
it would not make the database engine asynchronous.

Canonical segments are retained until explicit session deletion or an explicit
export-and-forget policy. Size pressure cannot silently delete history. Storage
v1 does not accept secret content. Encrypted secret retention and journaled
redaction markers are reserved for a later storage version.

## Migration state

| Producer or consumer | State |
| --- | --- |
| Durable resource mutations | Implemented in storage v1 |
| Focus, tab selection, split ratio, viewport width | Implemented through resource mutations |
| Explicit `agent.report` projection | Implemented through resource mutations |
| v8 bounded resource-event rows | Migrated with an explicit history-completeness checkpoint |
| Legacy workspace and terminal event tables | Compatibility projections, migration pending |
| Transient `MuxEvent` observations | Classification and ingress pending |
| Frontend focus, window geometry, and viewport target | Implemented as advisory observations |
| Checkpoint terminal VT content references | Implemented with content-addressed gzip blobs |
| Continuous terminal content chunks and geometry | Implemented with raw BLOBs and generation-local offsets |
| Built-in redacted agent-hook ingress, semantic normalization, and indexed agent forest | Implemented in storage v1; explicit parent session IDs form cross-process ancestry without provider agent IDs |
| Provider-specific agent hook installers | Implemented for Codex, Claude Code, Gemini CLI, Cursor Agent, Grok, Hermes Agent, OpenCode, Amp, and Pi |
| Verified agent root ownership leases | Pending |
| Schema-validated producer manifests and ingress | Implemented in storage v1 |
| Hook dispatcher and delivery projections | Implemented in storage v1 |
| Checkpoint writer and restoration preview reducer | Implemented in storage v1 |
| Checkpoint-aligned immutable segments | Implemented in storage v1 |
| Restart topology restoration with honest exited terminals | Implemented in storage v1 |
| Cold-start checkpoint content application to exited placeholders | Implemented in storage v1 |
| Post-restore respawn actions | Pending |

The in-memory `MuxEvent` broadcaster remains a lossy presentation mechanism.
It may wake consumers after commit, but it is never a journal or restoration
source.
