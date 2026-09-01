# cmux resource API v2

Status: normative, prelaunch, incompatible with every earlier control API.

## Model

The public hierarchy is:

```text
Machine
└── Session
    ├── Terminal
    ├── Workspace
    │   └── Screen
    │       └── Pane
    │           └── Tab
    │               └── Terminal view or Browser
    ├── Client
    ├── Notification
    ├── Agent
    ├── Projection
    └── SidebarView
```

A terminal is session-owned content with zero or more tab views. Every view
has its own tab ID and placement-local name; all views share one process,
ordered input stream, output history, and canonical grid. Closing a tab, pane,
screen, workspace, frontend projection, or client connection detaches views
without closing the terminal. `terminal.project` adds another view, and only
`terminal.close` terminates and tombstones the terminal. A browser remains
single-view tab content. Sidebar extensions are session-scoped auxiliary
resources and cannot become tabs.

One `cmux.protocol/2` endpoint describes exactly one local mux session. Its
machine and session resources provide stable routing handles for that local
session. Cross-machine discovery, aggregation, and provider lifecycle are
reserved for a later broker protocol.

All public IDs are JSON strings with one registered prefix and 128 bits of
lowercase hexadecimal entropy:

| Resource | Prefix |
| --- | --- |
| Machine | `machine_` |
| Session | `session_` |
| Workspace | `ws_` |
| Screen | `screen_` |
| Pane | `pane_` |
| Tab | `tab_` |
| Terminal | `term_` |
| Browser | `browser_` |
| Client | `client_` |
| Split | `split_` |
| Notification | `notification_` |
| Agent | `agent_` |
| Stream | `stream_` |
| Projection | `projection_` |
| Pairing request | `pairing_` |
| Sidebar view | `sidebar_view_` |
| Sidebar plugin | `sidebar_plugin_` |

IDs are immutable and never reused. A durable session stores IDs with the
logical resource and restores every ID for every resource that remains alive
after daemon restart. Mux implementation indexes are private and cannot appear
in a v2 request, response, event, error, CLI value, or high-level SDK.

Names are labels. They are preserved byte-for-byte, may be empty, and need
not be unique.

## Selectors

Every CLI instance selector accepts:

1. a typed opaque ID;
2. `current`;
3. an exact name.

`name:<value>` forces name interpretation. It is required for names equal to
`current`, names shaped like opaque IDs, and names containing `_`. The prefix
is syntax and is not part of the matched name.

An exact name with zero matches returns `selector.not_found`. More than one
match returns `selector.ambiguous` with every candidate ID. Resolution and
mutation use one snapshot, so an ambiguous request cannot partially mutate.
SDK `find_by_name` methods always return a list.

Session-resource requests always carry `machine` and `session` routing
selectors. Structural selectors after the session are flat fields named
`workspace`, `screen`, `pane`, and `tab`. An opaque nested target ID may omit
those ancestors. A `current` or name target requires the complete contiguous
structural chain through its parent, supplied by CLI or SDK context.

An opaque terminal ID resolves without a structural ancestor even when the
terminal has no tabs. Supplying a tab disambiguates one view for view
operations such as `terminal.move`; a terminal-only selector uses the first
durable view when one exists. Content operations, including input, history,
screen reads, projection, waiting, and explicit close, address the terminal
resource and continue to work with zero views.

Every supplied ancestor must contain the resolved descendant. A mismatch
returns `selector.wrong_parent` with the expected and actual parent before a
read or mutation runs. Selector resolution, containment validation, revision
validation, and mutation commit use one snapshot, so a failed containment
check cannot partially mutate.

## Protocol

Unix sockets use one UTF-8 JSON object per line. WebSockets use one UTF-8 JSON
object per text frame. Both transports carry identical envelopes.
`pairing_request.list` and `pairing_request.resolve` require a trusted local
Unix-socket connection and are unavailable over WebSocket. Request IDs are
connection-scoped and unique among pending requests. A caller may reuse an ID
only after consuming its response or completing the `request.cancel`
lifecycle.

Request:

```json
{
  "protocol": "cmux.protocol/2",
  "type": "request",
  "id": "request-owned-bounded-string",
  "operation": "workspace.list",
  "params": {
    "machine": "machine_…",
    "session": "session_…"
  }
}
```

Success:

```json
{
  "protocol": "cmux.protocol/2",
  "type": "response",
  "id": "request-owned-bounded-string",
  "ok": true,
  "result": []
}
```

Failure:

```json
{
  "protocol": "cmux.protocol/2",
  "type": "response",
  "id": "request-owned-bounded-string",
  "ok": false,
  "error": {
    "code": "selector.ambiguous",
    "message": "more than one workspace is named \"api\"",
    "details": {"candidates": ["ws_…", "ws_…"]},
    "retryable": false
  }
}
```

Reads omit `idempotency_key`. Every mutation requires a key containing 1 to
128 UTF-8 bytes, at least one Unicode scalar outside the Unicode `White_Space`
property, and no Unicode `Cc` control scalar. Leading, trailing, and internal
non-control whitespace is preserved.
Repeating the same key, operation, and canonical parameters returns the
committed result. Reusing a key with different parameters returns
`idempotency.conflict`. Replay lookup runs before selectors and revision
checks. SDKs never retry mutations implicitly.

Completed pure mutations retain the newest 4096 ordinary replay records. A
running registry may retain at most 127 additional ordinary records between
batched pruning passes; startup removes that slack. The newest
`session.terminal_defaults.update` record remains pinned because it is the
current durable defaults projection. Records associated with pending,
executing, or indeterminate effect receipts, or prepared, executing, or
indeterminate creation receipts, remain pinned until those receipts reach a
terminal state. After an uncorrelated ordinary record leaves the window,
reuse of its key is a new mutation. Completed creation correlations and effect
outcomes remain authoritative in their separate receipt tables after a
mutation replay record expires, subject to the receipt retention policy below.

Interactive terminal, browser, and sidebar input payloads never enter durable
effect fingerprints or intents as plaintext. Their fingerprint uses
HMAC-SHA256 with a random 32-byte state-root pepper, the idempotency key,
operation, and canonical fields. SQLite stores only the digest, a redaction
marker, and the pepper identifier. The owner-only pepper file is shared by
sessions under one state root; a missing, corrupt, or mismatched pepper makes
the registry fail closed. `browser.navigate` is excluded because browser URLs
already persist as public browser topology, events, and outcomes.

Committed `terminal.input.*`, `terminal.viewport.scroll`, `browser.input.*`,
and `sidebar_view.input` receipts have a bounded replay window. The registry
retains the newest 4096 uncorrelated committed receipts, with at most 127
additional rows between batched pruning passes; startup removes that batching
slack. Pending, executing, indeterminate, and creation-correlated receipts are
never evicted. After a committed receipt leaves this window, reuse of its
idempotency key is treated as a new mutation. These finite retention windows
are the exceptions to the mutation replay guarantee above.

`agent.report` requires a live terminal and has no session-global or default
agent record. The registry stores one current projection row per live
terminal. Public `agent.report` and raw `report-agent` use the same durable
commit path, advance the public resource revision, and publish one agent
change to `session.events`. A hook report replaces socket state. A later
socket report retains the hook value but still commits the observed durable
order and publishes that retained value. Restart restores agents from the
current projection table rather than scanning report history. Tombstoning a
terminal deletes its projection in the same transaction, so historical
reports cannot resurrect it.

`terminal.viewport.scroll` changes the session's compatibility inspection
viewport. Interactive frontends keep scroll in their own terminal mirror and
must not call this operation for user scrolling. Its first success returns the
existing resource revision, inserts no resource mutation or event, and neither
advances nor wakes `session.events`. A real compatibility-viewport change
still emits the ordinary `scroll` item on `terminal.attach`. Same-key,
same-request replay returns the original value, generation, and revision with
`replayed: true` without applying the delta again. After bounded receipt
eviction, the key executes as a new mutation.

`sidebar_view.input` compares the complete public sidebar lifecycle snapshot
immediately before and after the PTY write. If the snapshot is unchanged,
success and replay return the current resource revision without inserting a
resource event or waking `session.events`. If `running`, `cols`, or `rows`
changes during the effect, the commit advances revision once and emits one
`sidebar_view` upsert containing the post-write snapshot. Failure to observe
the post-write snapshot returns `mutation.indeterminate`.

`session.shutdown` requires a trusted local Unix-socket connection and is
unavailable over WebSocket. With `force: false`, another connected client whose
kind is `native-browser` blocks shutdown. `force: true` bypasses only that
ownership check; it does not bypass transport, selector, revision, or
idempotency validation. On success, the server commits the durable receipt,
queues its response, and requests process exit only after the queue succeeds.
If queueing fails, the server cancels the shutdown handoff and does not request
exit. Repeating the same key replays the durable receipt, reserves a new
handoff, and may request exit after the replay response is queued.

Requests are limited to 4 MiB. Server responses and stream envelopes are
limited to 16 MiB. Newlines are framing and do not count toward either limit.
Each stream queue holds at most 256 messages and 16 MiB, with a separate
control-message reserve. A slow stream ends with reason `gap`, the current
cursor, and recovery instructions without breaking other requests or streams.

The client generates a connection-scoped `stream_` ID in every stream-open
request. The router installs the tap and stream registry before acknowledging
the request, enqueues the success response, then releases the initial
snapshot. `stream.cancel` is connection-local and idempotent. It purges queued
items, cleans up taps and sizing leases exactly once, queues one
`stream_end(canceled)`, then returns its response. No item may follow an end.

An SDK accepts a stream open only after validating its successful response and
matching `stream_id`. If dispatch of a complete request was confirmed but no
valid acknowledgement was accepted, the SDK must release the provisional
route within a fresh bounded lifetime. A shared transport does so by sending
`stream.cancel`, validating its response, and forbidding connection reuse
until confirmation. A stream that owns a dedicated transport may instead
explicitly close that transport within the same bounded lifetime. Cleanup
failure closes the owning transport. The original open error remains the
caller-visible error.

A valid `ok: false` structured error conclusively rejects the open, so the SDK
removes its provisional route without cancellation and may reuse a
framing-safe transport. An open that was not dispatched sends no cancellation.
If an outgoing frame may be partial or framing is otherwise uncertain, the SDK
must append no cancellation and must close the transport. Failed-open cleanup,
explicit cancellation, and overflow cleanup share one per-stream claim so at
most one cancellation request is sent.

Explicit cancellation succeeds only after both the exact empty
`stream.cancel` response and the matching canonical
`stream_end(canceled)` arrive within one absolute deadline. They may arrive in
either order. Earlier queued items do not extend the deadline. A missing,
malformed, or differently terminated end fails cancellation and closes the
owning transport.

A request deadline is one absolute deadline covering connection, writer
admission, complete dispatch, and response, including a stream-open
acknowledgement. After acknowledgement, ordinary stream idleness has no
implicit deadline. A caller may use a bounded poll without closing the stream;
only cancellation, a `stream_end`, transport failure, or an explicit
application-owned lifetime ends it.

`terminal.wait` and `terminal.wait_exit` may remain pending without a protocol
deadline. After a completely dispatched wait reaches a caller-local timeout or
abort, an SDK sends `request.cancel` on the same connection with the original
public request ID and a fresh bounded cleanup deadline. `{canceled: true}` is
the cancellation linearization point and guarantees that the target request
will send no response; the worker and its admission permits are released
before confirmation. For a fully dispatched target on the same connection,
`{canceled: false}` means the request left the active registry only after its
response queue attempt. The SDK retains and drains that exact target response
before reusing a shared connection. An absent target response, or missing or
malformed cancellation confirmation, closes the transport before reuse.

The server registers each pending screen wait before reading the viewport.
Terminal output, resize, reconnect, clear-history, request cancellation, and
connection close wake that registration. An unbounded wait performs no
periodic screen polling.

Stream items use decimal strings for sequences and cursors:

```json
{
  "protocol": "cmux.protocol/2",
  "type": "stream_item",
  "stream_id": "stream_…",
  "sequence": "42",
  "cursor": {"generation": "opaque", "revision": "105"},
  "item": {"event": "terminal.output", "data": {}}
}
```

Response, `stream_item`, and `stream_end` envelopes use exact field sets.
Responses require `protocol`, `type`, `id`, and `ok`, plus exactly one of
`result` or the exact structured `error` according to `ok`. Stream items
require `protocol`, `type`, `stream_id`, canonical decimal `sequence`, and an
object `item`; optional `cursor` is non-null and strict when present. Stream
ends require `protocol`, `type`, `stream_id`, and `reason`; optional `cursor`,
`recovery`, and `error` are non-null and strict when present, and `error` is
present exactly when reason is `error`.

`session.events` accepts an optional generation plus last-applied revision
cursor. With no cursor, it sends one snapshot then live batches. With a
covered cursor, it replays through the captured head before live delivery. A
generation mismatch or expired cursor sends a fresh snapshot with
`reset_reason`; a cursor ahead of head returns `cursor.invalid`. One atomic
transaction produces one `session.delta` batch with `previous_revision` and
the new revision. Durable resource batches are append-only. A registry upgraded
from the earlier bounded store preserves its oldest retained revision and sends
a fresh snapshot when a requested cursor predates that boundary. Transport
stream queues remain bounded independently.

`session.journal.subscribe` is the append-only feed. Omitting a cursor tails
from the captured head; `start:"beginning"` replays retained history first.
`follow:false` bounds replay to the head captured when the stream opens and
ends it with reason `completed`; this is the primitive behind CLI `journal
read`.
Its cursor generation is the immutable session ID and its revision is the
journal sequence. Structured and compiled-regex filters are server-side and
never alter cursor order. Unix clients may read through `sensitive`; remote
clients are capped at `metadata`, receive redacted authority and causal fields,
and may run regex only on kind or subjects. A slow subscriber receives
`stream_end` with reason `gap` and the last recoverable cursor, then reconnects
from that cursor. Producer, hook, checkpoint, restore-preview, and segment
operations require a trusted local connection.

Terminal and browser attachments have independent decimal-string sequences.
Their initial snapshot is delivered after the open response. Overflow
requires a fresh attachment snapshot.

Every `browser.attach` frame also carries a required nullable
`pointer_frame_seq`. A null token permits rendering but forbids pointer input.
`browser.input.mouse` and `browser.input.wheel` require the exact non-null
decimal token from the frame whose pixels supplied the coordinates. Repaint,
navigation, and geometry changes can invalidate earlier tokens; invalid input
fails closed instead of being retargeted to the latest frame.

Every domain stream item union is open for SDK decoding. `session.events`,
`terminal.attach`, `browser.attach`, and `sidebar_view.attach` expose an
`Unknown` variant that retains the unrecognized discriminator and complete
raw object. A recognized discriminator must decode against its exact known
schema; malformed known payloads are errors and never become `Unknown`.
Servers emit only cataloged known variants.

`terminal.attach` is the public server-rendered stream. Its snapshot and
patches contain styled rows and runs, cursor state, resolved default colors,
scrollback counts, resize metadata, and an atomic `full_reset` marker. Raw PTY
bytes remain in the raw protocol; `terminal.state.read` supplies VT replay for
raw clients. `sidebar_view.attach` reuses the same `RenderSnapshot`,
`RenderPatch`, and `RenderScroll` types so Ratatui/plugin sidebars preserve
styles, cursor state, wide-cell width hints, and palette changes. Styled
terminal history uses the same `RenderRow` and `RenderRun` model.

`session.events` sends typed ordered `ResourceChange` values. Upserts carry a
typed resource ID and matching snapshot; deletes carry the typed ID and no
value. A screen snapshot includes its complete typed layout. One transaction
produces one batch bounded by `previous_revision` and `revision`, so frontends
can apply it without parsing generic JSON or refetching layout.

`stream_end.error`, when present, is the full structured error object with
`code`, `message`, `details`, and `retryable`. End reasons retain optional
cursor and recovery instructions.

## Typed operation catalog

`resource-operations-v2.json` is normative for every transported operation's
class, flat selector scopes, parameter fields and requiredness, result type,
structured errors, and stream item/end types. `resource-operations-v2.schema.json`
defines the catalog format. Unknown parameter and result fields are rejected.

| Class | Semantics |
| --- | --- |
| `read` | Read only. No idempotency key. |
| `mutation` | Durable mutation. A non-empty idempotency key is required. |
| `stream_open` | Opens a stream. The client supplies stream_id. No idempotency key. |
| `connection_control` | Connection-local control. No idempotency key. |
| `local` | Filesystem-only sidebar plugin action. It never uses a protocol request envelope. |

| Class | Operations |
| --- | --- |
| read | `agent.list`, `browser.get`, `browser.list`, `client.get`, `client.list`, `frontend_projection.get`, `machine.get`, `machine.list`, `notification.list`, `pairing_request.list`, `pane.get`, `pane.list`, `pane.neighbor.get`, `screen.get`, `screen.layout.export`, `screen.list`, `session.creation.resolve`, `session.get`, `session.journal.checkpoint.list`, `session.journal.hook.list`, `session.journal.producer.list`, `session.journal.restore.preview`, `session.journal.segment.list`, `session.list`, `session.ping`, `session.snapshot`, `sidebar_view.get`, `tab.get`, `tab.list`, `terminal.copy`, `terminal.get`, `terminal.history.read`, `terminal.list`, `terminal.output_read`, `terminal.process.get`, `terminal.screen.read`, `terminal.state.read`, `terminal.wait`, `terminal.wait_exit`, `workspace.get`, `workspace.list` |
| mutation | `agent.report`, `browser.activate`, `browser.back`, `browser.close`, `browser.forward`, `browser.input.key`, `browser.input.mouse`, `browser.input.text`, `browser.input.wheel`, `browser.navigate`, `browser.reload`, `frontend_projection.put`, `notification.create`, `pairing_request.resolve`, `pane.close`, `pane.create`, `pane.focus`, `pane.focus_direction`, `pane.rename`, `pane.run`, `pane.split`, `pane.split_ratio.set`, `pane.swap`, `pane.viewport_width.set`, `pane.zoom`, `screen.close`, `screen.create`, `screen.focus`, `screen.layout.undo`, `screen.rename`, `session.journal.append`, `session.journal.checkpoint.create`, `session.journal.hook.put`, `session.journal.producer.put`, `session.journal.segment.seal`, `session.open`, `session.reload_config`, `session.shutdown`, `session.terminal_defaults.update`, `session.window.title.clear`, `session.window.title.set`, `sidebar_view.ensure`, `sidebar_view.input`, `sidebar_view.reload`, `sidebar_view.resize`, `tab.close`, `tab.create_browser`, `tab.create_terminal`, `tab.focus`, `tab.move`, `tab.rename`, `terminal.close`, `terminal.history.clear`, `terminal.input.focus`, `terminal.input.keys`, `terminal.input.mouse`, `terminal.input.write`, `terminal.move`, `terminal.project`, `terminal.viewport.scroll`, `workspace.close`, `workspace.create`, `workspace.focus`, `workspace.layout.apply`, `workspace.move`, `workspace.rename`, `workspace.run` |
| stream_open | `browser.attach`, `session.events`, `session.journal.subscribe`, `sidebar_view.attach`, `terminal.attach` |
| connection_control | `browser.viewer.release`, `browser.viewer.resize`, `client.cell_pixels.set`, `client.detach`, `client.metadata.update`, `client.sizing.release`, `client.sizing.set`, `request.cancel`, `stream.cancel`, `terminal.renderer_grant.create`, `terminal.viewer.release`, `terminal.viewer.resize` |
| local | `sidebar_plugin.install`, `sidebar_plugin.list`, `sidebar_plugin.remove`, `sidebar_plugin.update`, `sidebar_plugin.use`, `sidebar_plugin.use_builtin` |

A selector is a flat object of scope strings. A nested target includes every
ancestor scope alongside its target scope. Names are exact labels and are not
unique. Workspace names are required strings. Screen, pane, tab, and client
snapshots always carry `name`, using null for unnamed. Their rename parameter
uses null to clear and a string, including empty, whitespace, or Unicode, to
set that exact value. Create operations keep an optional non-null string.
Client metadata updates use omission for no change and null to clear. A
non-null `name` or `kind` preserves its exact value, including empty,
whitespace, and Unicode, and contains at most 64 Unicode scalars with no
Unicode `Cc` control scalar. Validation runs before mutation, so rejection
leaves both fields unchanged.

`Cursor` contains a generation string and decimal-string revision.
`MutationResult<T>` is the flat
`{value,generation,revision,replayed}` result. Every committed mutation
returns generation and revision; `replayed` reports an idempotency replay.
The request already owns its idempotency key, so results do not echo it.

External effects use a durable three-state intent record. The server persists
the intent, marks it executing before invoking the effect, then records the
outcome. After restart, a persisted pre-execution intent may resume. An
executing intent without a recorded outcome returns the same non-retryable
`mutation.indeterminate` error for every request with that key and is never
repeated automatically. Its details contain `idempotency_key`, `operation`,
and `recovery: inspect_state_then_retry_with_new_key`. The caller inspects
resource state, then uses a new key only when repeating the effect is
appropriate.

The eight operations that return a `CreatedPath` accept a 1 through 128 byte
`correlation_key`: `workspace.create`, `workspace.run`, `screen.create`,
`pane.create`, `pane.split`, `pane.run`, `tab.create_terminal`, and
`tab.create_browser`. Omission defaults the correlation key to the request
idempotency key. A durable intent binds the key to the operation plus a
canonical semantic fingerprint before any external effect. The fingerprint
excludes `expected_revision`, `correlation_key`, and idempotency metadata.
Reusing the key for different semantics returns non-retryable
`creation.conflict`.

Every mutation, including `workspace.create`, accepts `expected_revision`
against the session resource cursor. A prepared creation re-checks that guard
before executing; a committed replay returns its original result regardless
of a now-stale guard.

`session.creation.resolve` reports `pending`, `created`, `not_applied`, or
`indeterminate` with one exact recovery action. A created resolution includes
the committed path, generation, and revision. Callers retry only when the
reported recovery is `retry_same_idempotency_key` or
`retry_new_idempotency_key`.

`CreatedPath` has explicit workspace-only, terminal-path, and browser-path
variants. Snapshots use only opaque resource IDs, exact names, positions, and
revision metadata. They never expose private workspace identity data, mux
positions as identity, alternate ID forms, or internal storage nouns.

`terminal.wait` remains the regex screen-content wait.
`terminal.wait_exit` waits for process completion and returns either pending
state or an exited outcome. Outcomes are strict exit-code, signal with
`core_dumped`, or unknown-reason variants. The terminal snapshot retains the
same exit record while the durable terminal is exited; `terminal.close`
tombstones it. Its required lifecycle is `launching`, `running`, or `exited`;
the legacy `running` convenience is true exactly for `running`, and `exit` is
present exactly for `exited`.
Public results expose the stable terminal ID and never expose the private
terminal-host generation token.

Client snapshots carry required nullable `name` and `client_kind`, transport,
self status, attached terminal IDs, and one size/participation record per
terminal. All `uint64` runtime values use decimal strings. Notification and
agent timestamps are decimal millisecond values. Pairing requests carry peer,
sensitive code, and remaining seconds; SDK string rendering and logs redact
the code.

Layout documents round-trip leaf, split, stack, and horizontal viewport
structures. Viewport columns retain stable IDs and widths. The document also
retains active and zoomed pane IDs. Nested same-direction splits are not
flattened. A rightward `pane.split` may include `viewport_width` from 0.1
through 1.0 to create the terminal as a separate scrolling viewport column;
ordinary splits omit it. `screen.create` returns the complete created terminal
path.

`workspace.create` requires `initial_content: terminal|empty`.
`workspace.run` and `pane.run` accept exactly one of a nonempty `argv`
array or a `shell` script. Only `argv[0]` must be nonempty; later values,
including empty strings, preserve exact bytes. The server runs `shell` with
its platform default shell and `-lc`; SDKs never inspect or expand `$SHELL`.
To choose a specific executable, callers send
`argv: [executable, "-lc", script]`.

`machine.list` returns one local machine, and `machine.get` resolves only that
machine. Its origin is always `local`. `session.list`, `session.get`, and
`session.open` operate only on the mux session owned by this endpoint.

Sidebar plugin installation and selection are local filesystem operations.
Transported sidebar view operations never send a `sidebar_plugin_` ID.
Optional install names are filesystem slugs matching `[a-z0-9-_]+`.

`screen.layout.undo` accepts `confirm_close`, default false, and an optional
opaque `confirmation_token` of 1 through 128 UTF-8 bytes. If the undo would
close created panes, false returns `confirmation.required` with the token,
global revision, and pane IDs without changing revision, layout, topology,
journal, or idempotency state. A confirmed retry uses that exact token,
revision, and a new mutation key.

The token is deterministic over the session generation, screen public ID,
layout revision, created pane IDs, and every closing pane's live tab IDs in
displayed order. Under the mutation lock, the server re-evaluates the undo and
accepts only an exact token for the locked state. A missing or stale token
returns a fresh read-only preview and closes nothing. The token is a
stale-state fence, not authentication.

Fields marked `sensitive: true` must be redacted from SDK Debug, `toString`,
exceptions, and logs. Pairing codes and renderer grant tokens are sensitive.
Renderer grants expose endpoint, terminal ID, token, rights, and TTL. They are
connection-bound, one-use capabilities.

`JsonValue` is limited to audited extension points: explicit snapshot `extra`
maps, frontend projection payloads, structured error details, and
operation failure extras. Core resource, stream, layout, render, and session
change shapes never use generic JSON.

Input modifiers are `shift|control|alt|meta`; terminal transport maps public
`meta` to its raw `super` bit. Browser coordinates and wheel deltas must be
finite. Browser down/up require a typed button and move omits it. Terminal
mouse down/up, move, and wheel enforce their distinct button/delta fields.

## CLI

The executable starts or attaches when no resource scope is supplied. Control
commands are noun-first:

```text
cmux workspace list
cmux workspace create --name api
cmux workspace api show
cmux workspace ws_… run -- cargo test
cmux workspace ws_… screen current pane current split --right
cmux terminal term_… screen read
cmux terminal term_… keys ctrl-c
cmux sidebar plugin list
```

Root control scopes are `machine`, `session`, `client`, `workspace`, `screen`,
`pane`, `tab`, `terminal`, `browser`, `notification`, `agent`, `sidebar`,
`pairing`, `projection`, `provider`, and `raw`. Sidebar resources
use the nested `sidebar view` and `sidebar plugin` grammars.
Hyphenated action-first commands are usage errors with exit code 2.

Global routing flags are `--machine`, `--session`, and advanced `--socket`.
They select the one local machine and mux session exposed by the endpoint.

Human output follows the selected locale, currently English and Japanese.
`--json` prints one result object. `--jsonl` prints one object per result or
event. `--quiet` suppresses success output. Results use stdout. Diagnostics
use stderr. Exit codes are 0 success, 1 operation failure, 2 usage, and 3
transport.

Local filesystem actions are `sidebar plugin install|update|remove|use` and
configuration discovery. Their results use the same output modes but they do
not cross the session protocol.

## SDK boundary

Generated wire models and codecs are available only under `raw`. High-level
resource handles are handwritten and dependency-light. A handle contains a
typed ID and client reference. Copying a handle performs no I/O. Dropping a
handle never deletes the resource. `refresh` is explicit. `close` is explicit.

Language contracts:

| Language | Contract |
| --- | --- |
| Rust | blocking `Result`, owned iterator streams |
| Python | synchronous client plus standard-library `asyncio` adapter |
| TypeScript | `Promise`, `AsyncIterable`, `AbortSignal`, browser-safe WebSocket export |
| Go | `context.Context` on every I/O method |
| Java | immutable values, builders, `AutoCloseable` streams |
| C++20 | `result<T>`, move-only RAII streams |
| Zig | caller allocator, explicit `deinit` |

Protocol errors retain `code`, `message`, `details`, and `retryable` in every
language. All seven SDKs implement the same fake-server and live-server
conformance cases.

Client, Stream, Notification, Agent, PairingRequest, FrontendProjection, and
SidebarView are typed session auxiliary resources. They are not inserted into
the workspace tree. Split IDs appear only in raw layout documents.

## Separate protocols

Terminal-host, machine-agent, and machine-provider transports keep separate
version numbers. The machine-provider protocol remains an internal transport.
A future cross-machine broker must define a later public protocol instead of
extending this one-session endpoint implicitly.
