# Persistent terminal backend and renderer isolation

Status: accepted for implementation

Baseline: `c9f2d8c4382e29db89a030d80d02d8174ef7f2ac`

Owners: cmux, cmux-tui, and the manaflow-ai/ghostty fork

## Outcome

cmux will use a persistent daemon built from the cmux-tui core as the only
authority for terminal sessions. The daemon owns PTYs, canonical terminal
state, scrollback, terminal metadata, and workspace topology. Swift, the TUI,
and cmux-browser are clients.

Ghostty GPU work will run in disposable renderer processes. A renderer process
will exist for each visible terminal workspace, not for every dormant
workspace. It will receive immutable render scenes, shape text, run shaders,
submit Metal work, and publish IOSurfaces. The Swift process will import and
composite those IOSurfaces without reading PTY output, parsing terminal bytes,
or shaping terminal text. It may submit exactly one full-surface Metal blit for
each admitted visible frame. Every terminal render encoder, draw call, glyph
atlas update, and shader pass remains in the renderer worker.

The resulting cost in Swift is proportional to visible presentation area and
refresh rate. It is independent of dormant terminal count. IOSurface sharing
does not copy the full pixel buffer through the CPU.

## Non-goals

- Surviving a machine reboot with a live PTY. A reboot restores launch recipes,
  not operating-system process state.
- Preserving a shell after the process that owns its PTY crashes. Renderer and
  Swift crashes must preserve shells. Daemon crash containment can be added by
  sharding terminal runtimes after measurement proves that it is needed.
- Making every Swift-native panel execute in cmuxd. Native panel runtimes remain
  in their natural process while their identity and placement are described by
  canonical topology records.
- Serializing Ghostty internal Zig structs as a cross-process ABI.
- Replaying PTY bytes into a second authoritative Ghostty parser.
- CPU readback of complete GPU frames.

## Options considered

### Persistent daemon plus passive renderer replicas

This is the selected architecture. cmuxd owns PTYs and canonical VT state.
Renderer workers own only disposable presentation caches.

Benefits:

- Swift and Chromium contain no terminal hot path.
- Swift and renderer restarts preserve exact shells and scrollback.
- Renderer crashes recover from a full snapshot.
- Cross-workspace moves change topology and renderer subscriptions without
  moving a PTY or terminal model.
- Dormant workspaces consume terminal state but no renderer-process memory.
- GUI, TUI, and browser clients observe one canonical terminal.

Costs:

- Ghostty needs a terminal-independent render scene and offscreen renderer.
- cmuxd remains the canonical parser failure domain until optional sharding.
- Selection, search, links, images, IME, and accessibility need explicit
  protocol contracts instead of direct surface calls.

### One full Ghostty process per terminal

This is a useful feasibility harness but not the product endpoint. It provides
full rendering fidelity quickly and naturally survives Swift restarts.

It is rejected as the final design because every renderer crash kills a shell,
100 terminals create 100 full Ghostty runtimes, and cmux-tui becomes a second
terminal authority or a proxy rather than the canonical backend.

### One full Ghostty process per workspace

This is rejected. A terminal moved between workspaces would require moving its
PTY, parser state, scrollback, images, search state, and pending input. Keeping
the terminal in its original process makes the claimed workspace ownership
false. Killing one worker would kill every shell in that workspace.

### PTY in cmuxd with byte-mirrored Ghostty replicas

This can prove process and frame transport, and existing prototypes do so. It
is rejected as the endpoint because the replica maintains a second parser,
terminal modes, scrollback, input encoder, and resize interpretation. Those
copies drift under dropped output, synchronized output, replies, and images.

## Process model

### cmuxd

cmuxd is a launchd-supervised per-user daemon built from cmux-tui core. It is
not a child whose lifetime is tied to a Swift connection.

cmuxd owns:

- daemon and session identities
- workspace, screen, pane, tab, panel, surface, and terminal identities
- canonical topology and its revision
- PTY masters, shell processes, and exit state
- canonical Ghostty VT state, modes, scrollback, and semantic marks
- ordered terminal input queues
- input and geometry leases
- titles, working directories, process metadata, activity, and notifications
- subscriptions, snapshots, and ordered deltas
- topology checkpointing and mutation-journal replay
- renderer-worker supervision and scene publication

cmuxd must not own:

- AppKit or SwiftUI views
- window-local navigation state
- fonts, glyph atlases, Metal command queues, or IOSurface pools
- browser engine state

### Renderer worker

One renderer worker serves the terminal presentations in one visible workspace.
If the same workspace is visible with incompatible scale, theme, or render
configuration, it may have multiple presentation targets in that worker.

The worker owns:

- decoded immutable render scenes
- presentation-local overlays and cursor animation
- Ghostty font, glyph, image, and shader caches
- Metal device, queue, textures, fences, and IOSurface pools
- frame sequence and release accounting

The worker does not own:

- a PTY
- canonical terminal state or scrollback
- workspace topology
- durable state
- permission to mutate synchronized output or scroll position

The worker starts when the first terminal presentation for a workspace becomes
visible. It exits after the final presentation detaches and all published
buffers are released. A new worker uses a new renderer epoch.

### Swift shell

Swift owns windows, native panel runtimes, AppKit input translation,
accessibility projection, and composition. Its terminal model is a revisioned
value projection backed by injected services. Persistent mode loads Ghostty
configuration without constructing `ghostty_app_t`; the Swift process contains
no Ghostty runtime app or local Ghostty surface.

Accessibility is fenced to presentation, renderer epoch, presentation
generation, and the exact terminal content sequence reported by the Metal
presented callback. Receipt of a newer IOSurface cannot advance accessibility.
The callback always records that bounded context in a lock-protected off-main
slot, even when accessibility is inactive. Late VoiceOver activation and OSC 8
link hit testing can therefore bind to already-visible pixels without waiting
for another frame or adding one main-actor hop per frame.
cmuxd retains a bounded sequence cache only after accessibility is requested,
so a displayed frame remains readable if canonical VT state advances before
Swift reports presentation. The cache is discarded when the semantic renderer
detaches.

Swift may request focus, input, selection, search, scrolling, and topology
mutations. It cannot mutate a second copy and later reconcile it. Optimistic UI
must carry a request ID and resolve against the authoritative revision.

`cmuxApp` resolves the backend gate once and is the only production composition
root. It injects one required `TerminalClientComposition` into `AppDelegate`,
every `TabManager`, `Workspace`, and `DockSplitStore`. None of those production
constructors has an optional composition or embedded default. The persistent
composition contains only `PersistentTerminalPanelFactory`; backend startup or
connection failure therefore remains visible and cannot instantiate a local
Ghostty surface, parser, or PTY. Unit-test convenience initializers live in the
test target and opt into `.embedded()` explicitly.

### TUI and browser clients

The TUI consumes canonical cell snapshots and deltas from cmuxd. The browser
client consumes terminal presentation frames when the platform supports shared
GPU buffers and canonical cell scenes otherwise. Neither client receives raw
PTY output as the normal rendering contract.

### Frontend-native browser panels

Browser identity, presentation mode, and placement are canonical. A
`frontend-native` browser keeps WebKit, profiles, requests, cookies, and page
rendering in Swift. Its current source URL is connection-private in-memory
daemon state because URLs may contain bearer credentials. The URL never enters
topology snapshots, mutation journals, checkpoints, idempotency digests, Swift
session snapshots, diagnostics, or logs.

The exact frontend connection claims each native browser with an owner
generation before projection. Navigation commits update that generation-fenced
claim without changing topology revision. Disconnect revokes ownership while
retaining the source for a later trusted frontend claim; panel close deletes the
source. The registry has per-source and aggregate byte limits. A daemon restart
loses this private source by design. A Swift hard kill can also lose the final
navigation if it occurs before the source update reaches cmuxd.

### Remote tmux and mobile compatibility

A remote tmux surface is a canonical parser-only external terminal in cmuxd.
Swift may own the SSH and tmux control transport, but it sends ordered remote
output into that external surface and forwards daemon-produced egress back to
the transport. Swift does not create a Ghostty parser, PTY, or terminal surface
for the mirror. Reconnect starts a new external-output generation and reseeds a
full remote snapshot before ordered deltas resume.

Mobile clients should consume canonical scenes or renderer frames when their
transport supports them. A byte-stream compatibility endpoint is explicitly
noncanonical: every message carries a terminal epoch, generation, and sequence,
and overflow or a sequence gap forces reopen plus full resnapshot. Compatibility
bytes may feed a mobile presentation parser, but that client cannot claim
canonical state parity and the desktop Swift process does not parse the stream.

## Authority model

### Durable identity

Every durable entity uses an opaque UUID. Numeric and short IDs remain display
aliases scoped to one daemon instance. A display alias must never be persisted
or used as an idempotency key.

Required identities:

- `daemon_instance_id`: changes for every cmuxd process lifetime
- `session_id`: stable for one persisted cmux session
- `client_id`: stable for one connected client lifetime
- `window_id`: stable for a client window
- `workspace_id`
- `pane_id`
- `tab_id`
- `panel_id`
- `surface_id`
- `terminal_id`
- `presentation_id`

A terminal identity is independent of workspace placement. Moving a terminal
does not change its `terminal_id`, shell PID, PTY, or canonical state.

### Durable acknowledgement boundary

cmuxd sends a canonical mutation success response only after the complete
snapshot, idempotency result, and topology revision have been appended and
synced. An append or checkpoint failure is fail-stop: cmuxd aborts while the
mutation lock is held, sends no response, and recovery exposes the last durable
revision. It does not attempt an in-process rollback after a storage failure.
Every topology-visible terminal launch first starts a same-PID internal helper
inside the candidate PTY. The helper authenticates its private Unix socket,
validates the requested executable, and waits without executing user code. An
append failure closes the gate and terminates that exact helper PID before any
success response. After the append is synced, cmuxd releases the helper into the
requested executable and then writes the complete initial input while retaining
exclusive input order. Release, exec, or input-delivery uncertainty after the
commit is fail-stop because returning an error could invite an ambiguous retry.
Recovery of a recipe committed by an earlier daemon is intentionally ungated;
that recipe already crossed this durable boundary.

### Generations and revisions

- `topology_revision` increases once for every committed topology transaction.
- `terminal_epoch` changes when a canonical terminal runtime is recreated.
- `terminal_sequence` orders canonical terminal mutations within an epoch.
- `renderer_epoch` changes when a renderer worker is recreated.
- `presentation_generation` changes when a presentation changes worker, size,
  scale, theme, or IOSurface pool.
- `frame_sequence` orders frames within a presentation generation.
- `geometry_revision` changes with canonical terminal rows and columns.

Clients reject messages from older epochs, generations, revisions, or frame
sequences. Sequence comparisons are valid only within their stated epoch.

### Canonical and client-local state

Canonical state includes topology, terminal state, titles, process metadata,
terminal activity facts, and leases.

Client-local state includes:

- the workspace viewed by each window
- the active screen, pane, and tab in each presentation
- pane zoom, terminal scroll position, selection, and search presentation
- hover and pointer capture
- transient command palette and settings state
- requested viewport and spectator pan position
- presentation theme and scale
- accessibility focus projection

Frontend-native browser source URLs are private runtime lease state. They are
neither canonical durable state nor ordinary client-local snapshot state.

One socket client may represent several windows, so presentation state is keyed
by `presentation_id`, not only `client_id`. Unread state is derived from
canonical activity facts plus durable receipts keyed by stable frontend reader
UUID and terminal UUID. It is not a mutable global boolean.

## Topology model

A workspace contains an ordered panel tree. A panel record describes type,
placement, identity, metadata, and an endpoint binding.

Terminal panels bind to a `terminal_id`. Browser panels bind to a browser
endpoint. Swift-native panels bind to a native endpoint whose runtime is owned
by the connected Swift client. cmuxd can therefore remain the topology
authority without pretending it executes every panel type.

Every topology command is a transaction with:

- `request_id`
- `idempotency_key`
- expected or minimum topology revision
- one or more typed mutations
- one authoritative result revision

Retries with the same idempotency key return the original result. Deleted
entities leave bounded tombstones so a retry cannot recreate or target a new
entity with a reused alias.

Closing a UI presentation, closing a panel, and terminating a terminal are
different operations:

- `presentation.detach` removes one client view.
- `panel.close` removes one topology binding.
- `terminal.terminate` sends a requested termination action to the shell.
- `terminal.destroy` is allowed only after no topology binding or retention
  policy keeps the terminal alive.

## Terminal input and geometry

### Input ordering

Each canonical terminal has one daemon-assigned ordered input actor shared by
GUI, TUI, and delegated automation clients. Every request carries
the holder-local `sequence`, `request_id`, and any `input_group_id`, group index,
and end marker. The receipt carries the daemon-assigned
`ordered_input_sequence`, which never resets across lease transfer.

Atomic input operations include:

- one physical key press, repeat, or release with its modifier state
- an IME commit
- one bracketed paste
- one mouse press, motion, or release event
- terminal protocol replies generated by canonical VT parsing

An invalid or stale geometry revision rejects coordinate input. It must not be
silently applied to new dimensions.

### Input lease

Only the holder of the terminal input lease may type, paste, or send mouse
events. The holder may grant a 10-second-or-shorter automation delegation to
one exact registered connection claim and a nonempty subset of text, key, and
mouse input. Delegations never include geometry. Disconnect revokes leases
held by that client and delegations issued to that connection.

### Geometry lease

One presentation owns canonical PTY rows and columns. Focused interactive GUI
presentations receive priority by policy. TUI and spectator clients crop,
letterbox, pan, or request lease transfer.

A lease grant records:

- lane kind (`input` or `geometry`)
- lease ID
- stable client, process, connection-claim, and presentation IDs
- terminal ID
- presentation generation
- lane-local generation, TTL, and revocation sequence

The current smallest-viewer-wins policy will be removed. A reconnect cannot
shrink the terminal unless it acquires the geometry lease.

## Snapshot and delta protocol

Protocol negotiation uses compatible version ranges and capabilities. Exact
Git SHAs are diagnostic metadata, not the compatibility contract.

Handshake fields include:

```json
{
  "protocol_min": 8,
  "protocol_max": 9,
  "capabilities": [
    "stable-entity-uuid-v1",
    "canonical-topology-snapshot-v1",
    "topology-resume-v1",
    "terminal-control-lease-v1",
    "terminal-split-leases-v1",
    "terminal-lease-transfer-v1",
    "terminal-input-delegation-v1",
    "terminal-input-groups-v1",
    "terminal-global-input-order-v1",
    "terminal-input-receipt-ack-v1",
    "terminal-nonrenderer-presentation-v1",
    "render-scene-v1",
    "iosurface-present-v1"
  ],
  "client_uuid": "stable uuid",
  "process_instance_uuid": "per-process uuid",
  "client_kind": "swift|tui|browser|automation"
}
```

Version 8 remains the connected read-only and topology baseline. A client must
explicitly register its stable logical identity and per-process identity before
using version 9 mutation capabilities. The identify-first client records an
explicit `readWrite` or `readOnly` result containing the client and server
ranges, mutually selected protocol, missing mutation capabilities, and a
localized update action. A non-overlapping range or a missing mutation
capability stays connected for identity, health, topology, list, process,
screen-text, accessibility, and projection diagnostics. The Swift protocol
client rejects every other command locally before request-ID allocation or
transport dispatch.

Read-write admission requires every command family used by the persistent
frontend, including terminal creation and reparenting, semantic-scene
rendering, worker supervision, terminal interaction, accessibility, hyperlink
hit testing, and protocol-v9 terminal control. Missing any one of these
capabilities keeps the connection read-only before the first mutation.

Registry subscription begins with one atomic snapshot:

```json
{
  "daemon_instance_id": "uuid",
  "session_id": "uuid",
  "topology_revision": 42,
  "workspaces": [],
  "panels": [],
  "terminals": [],
  "leases": []
}
```

Ordered deltas start after revision 42. A bounded subscriber queue reports
overflow with the newest available revision. The client discards partial
derived state and requests a fresh snapshot. It must not guess across a gap.

Daemon restart changes `daemon_instance_id`, closes subscriptions, and forces
every client to perform a new handshake and snapshot.

## RenderScene

`RenderScene` is an owned, versioned representation of everything Ghostty needs
to draw a terminal frame without access to a live terminal pointer.

The scene header contains:

- wire version
- terminal ID, epoch, and sequence
- full snapshot or delta marker
- grid rows and columns
- active screen and viewport anchor
- palette and default-color semantics
- cursor state
- changed-row and image generations

Each row contains:

- stable viewport row anchor
- wrap and semantic-prompt flags
- full replacement or unchanged marker
- exact cells
- link, selection, and search spans

Each cell contains:

- complete grapheme cluster
- narrow, wide, spacer-head, or spacer-tail kind
- foreground, background, and underline color semantics
- bold, faint, italic, blink, inverse, invisible, strike, and overline styles
- underline style
- semantic content flags
- stable link ID when present

Presentation state is sent separately:

- focus and cursor blink state
- hovered link
- selection and search query presentation
- IME preedit
- font and configuration generation
- target pixel size, scale, color space, and theme

Kitty image bytes are content-addressed and transported once per image hash
through bounded shared memory. Ordered scene mutations carry placements,
deletions, cropping, z-order, animation frame, and viewport relationships.

The wire format must not expose pointer-bearing rows, internal style-table
indices, allocator ownership, packed internal cell layout, or native endianness.

## Frame transport

Renderer control uses authenticated local IPC. The connection validates the
peer audit token and an unguessable per-worker capability minted by cmuxd.

Each presentation uses at least three IOSurfaces. A surface can be reused only
after GPU completion and an explicit consumer release. The worker may drop an
unpresented intermediate frame. It may never block terminal parsing waiting for
Swift to consume a frame.

The Swift host may import the completed IOSurface and submit exactly one
full-surface Metal blit for each admitted visible frame. The host must not
create a terminal render encoder, issue a terminal draw, shape text, or inspect
terminal cells. It releases the exact worker surface only from the host Metal
command buffer's completion handler, after the GPU has finished reading the
source texture.

Mach receive, audit-token validation, frame admission, latest-frame coalescing,
drawable acquisition, and Metal submission run through a sendable compositor
ingress outside AppKit's main actor. The main actor only installs or replaces a
`CAMetalLayer`. A presented frame records one fixed-size semantic fence off-main
and schedules main-actor semantic work only after an accessibility client has
explicitly demanded terminal accessibility state.

Assigning an IOSurface directly to `CALayer.contents` is not an equivalent
release fence. Core Animation exposes no public callback that proves its render
server has stopped sampling that contents object. A `CATransaction` completion
waits for animations, not render-server consumption. Remote Core Animation
layers are public on macOS but documented as legacy. Either path may replace
the explicit blit only after a public, deterministic consumer-completion and
surface-reuse contract is proven.

Frame metadata includes:

- daemon instance ID
- renderer epoch
- terminal epoch and sequence represented by the frame
- presentation ID and generation
- frame sequence
- IOSurface identifier and dimensions
- pixel format and color space
- GPU completion fence value
- damage region when useful

Swift accepts only the newest completed frame for the active generation. A
late frame from a previous worker, terminal epoch, size, scale, or theme is
discarded before touching the layer.

No control path may wait forever for a Mach right, worker connection, fence, or
release acknowledgement. Deadlines are explicit and cancellation follows the
presentation lifecycle.

Renderer control queues have one supervisor-wide retained-memory envelope.
The coordinator admits at most 1,024 commands and 72 MiB. Each worker outbox
admits at most 128 messages and 72 MiB. Across the coordinator and every worker,
the supervisor admits at most 4,096 logical messages and 256 MiB. One message
slot and 1 KiB remain reserved for recovery. A 1,024-worker ceiling plus fixed
queue capacities gives queue objects and empty-but-previously-full storage a
fixed worst-case size; that full size is deducted from the 256 MiB envelope.
Owned `String` and `Vec` capacities are charged exactly. One worker read poll is
also capped at 1 MiB.

An oversized message is rejected from its validated encoded length before an
encoding buffer is allocated. Queue overflow never combines opaque scene
deltas. The supervisor drops only the affected workspace's pending renderer
state, terminates that worker, and increments its renderer epoch. After the new
process authenticates with `WorkerReady`, cmuxd sends current presentation state
and a full semantic scene. Other workspaces and topology commands remain live.

Released-presentation fences store only terminal, presentation, epoch, and
generation identity. Retired fences and generation tombstones each have an
8,192-entry and 512 KiB limit. Large configuration and capability buffers are
not retained after presentation removal.

Metal System Trace evidence must contain both exact process IDs. The renderer
PID must own command buffers labeled `cmux Ghostty worker semantic-scene
render`, render encoders labeled `Ghostty terminal glyph render pass`, and
textures labeled `Ghostty IOSurface terminal render target`. The Swift PID may
own command buffers labeled `cmux host compositor: one IOSurface blit` and blit
encoders labeled `cmux host compositor: no Ghostty rendering`; it must contain
no Ghostty render encoder or draw call. Host blit count must equal the
compositor's submitted-blit counter for the captured interval and must not
exceed the number of admitted visible frames.

## Ghostty refactor

Ghostty currently captures a renderer-oriented terminal state but the renderer
still reaches back into a live terminal for links, images, search, selection,
scroll-to-bottom, and synchronized output. The refactor separates two phases:

1. Capture an owned `RenderScene` from canonical terminal state.
2. Project `RenderScene` plus presentation state through the existing font and
   GPU renderer.

The existing in-process renderer will use the same scene projection path before
the external worker is enabled. This makes parity testable and prevents the new
path from becoming a forked renderer.

Terminal mutations currently hidden in rendering, including synchronized
output release and scroll-to-bottom decisions, move to canonical terminal
logic. Search anchors and link activation remain daemon commands. IME preedit
is presentation input; IME commit is terminal input.

The standalone renderer constructor must not create `Surface`, termio, a PTY,
or a canonical terminal. Its external Metal presenter publishes only after GPU
completion.

Semantic-scene capture records terminal-lock duration in buckets ending at 100
microseconds, 250 microseconds, 500 microseconds, 1, 2, 4, 8, and 16
milliseconds, with a final overflow bucket. Captures over 8 milliseconds are
counted separately, along with encoded scenes and skipped backpressured
attachments. Ghostty's current API snapshots and encodes in one call, so moving
encoding outside the terminal lock requires a new owned snapshot API. Until
that API exists, bounded attachments are skipped before encoding and lock timing
remains an acceptance metric.

## Persistence and lifecycle

cmuxd writes a periodic atomic topology checkpoint and an append-only mutation
journal. The journal records topology, retention, metadata, and launch-recipe
changes. It does not record terminal output bytes.

Startup performs:

1. acquire the session lock
2. load and validate the latest checkpoint
3. replay valid later journal entries by idempotency key
4. quarantine an invalid trailing journal record
5. bind the private control socket
6. publish the new daemon instance ID
7. accept clients

Normal Swift termination detaches its presentations. It does not close panels
or terminals. Explicit Quit may offer a separate terminate-session action, but
the default app lifecycle must preserve cmuxd.

Frontend updates rely on protocol compatibility, not daemon process handoff. A
new app may connect to an already-running older daemon within the negotiated
range. An incompatible daemon reports the range and admits the frontend as
read-only without mutating state. Live daemon executable replacement and PTY
ownership transfer are not implemented. Explicitly restarting an incompatible
daemon terminates the shells it owns, so the experiment remains opt-in and the
production gate stays disabled. Upgrade and rollback behavior must be tested
before the legacy frontend path is removed.

## Failure behavior

| Failure | Required result |
| --- | --- |
| Swift crash or force quit | PTYs, shells, topology, and terminal state remain alive. |
| Swift relaunch | Reconnect to the same terminal IDs, PIDs, TTYs, cwd, scrollback, and metadata. |
| Renderer crash | Only its pixels freeze; shells and other workspaces remain interactive; a new worker receives a full snapshot. |
| Renderer stalls | cmuxd drops scene deltas for that worker, records overflow, and replaces them with a full snapshot after recovery. |
| Subscriber overflow | Client discards its projection and requests an atomic snapshot. |
| Client disconnect with lease | cmuxd revokes input and geometry leases immediately and emits ordered revocation events. |
| Stale frame | Swift rejects it by epoch, generation, sequence, or dimensions. |
| Malformed or oversized IPC | Receiver rejects the message without allocation amplification or state mutation. |
| cmuxd crash | Swift reports backend loss; renderer workers exit; shells owned by cmuxd terminate. This is an explicit current limitation. |
| Machine reboot | Persisted topology and launch recipes restore; previous PIDs are reported as dead, never reused as live identity. |

## Security

- Runtime directories use mode `0700`; sockets use mode `0600`.
- Local peer identity is checked before terminal contents or input authority are
  exposed.
- Remote WebSocket clients authenticate before protocol dispatch.
- Frame and scene sizes have hard limits before allocation.
- Image hashes, dimensions, decompressed byte counts, and placement counts have
  limits.
- Every input, geometry, close, terminate, and destroy command is authorized
  against the client role and current lease.
- Worker capabilities expire with renderer epoch and cannot attach to another
  workspace or session.
- Logs contain IDs, revisions, epochs, sizes, and PIDs, but redact terminal
  contents, pasted text, credentials, environment, and image bytes.

## Migration plan

### Stage 0: contract and baseline

- Land this architecture note and executable acceptance manifest.
- Record exact baseline process, CPU, memory, latency, and restart evidence.
- Create shared protocol conformance fixtures before adding new clients.

Exit gate: ownership and failure invariants have test IDs and evidence paths.

### Stage 1: durable daemon authority

- Add stable IDs, daemon instance ID, topology revisions, snapshots, deltas,
  detach versus destroy, idempotency, tombstones, checkpoint, and journal.
- Gate every new topology-visible PTY child before user exec, release it only
  after the journal sync, and fail-stop on post-commit launch uncertainty.
- Start cmuxd independently of Swift and reconnect after Swift termination.
- Use the existing styled-cell view only as a temporary authority migration
  proof. It is not a renderer-performance milestone.

Exit gate: the exact shell and canonical terminal survive Swift restart.

### Stage 2: multi-client leases

- Move active selection to per-client window state.
- Add input and geometry leases, ordered terminal input, stale-coordinate
  rejection, disconnect revocation, and resize coalescing.
- Attach GUI, TUI, browser, and automation clients concurrently.

Exit gate: different client sizes do not oscillate PTY geometry and concurrent
input follows one deterministic order.

### Stage 3: Ghostty render scene

- Capture `RenderScene` from the existing terminal renderer state.
- Make the existing renderer consume the same owned scene.
- Add full snapshot, row deltas, presentation state, and image side channel.
- Add a standalone external Metal renderer and parity fixtures.

Exit gate: pixel and interaction metadata parity passes the full fixture set.

### Stage 4: renderer workers

- Integrate authenticated worker launch and teardown.
- Add IOSurface pools, fences, generation checks, deadlines, latest-frame-wins
  backpressure, release accounting, and full-resnapshot recovery.
- Spawn workers only for visible terminal workspaces.

Exit gate: renderer kill and restart preserve the shell and recover pixels.

### Stage 5: thin Swift terminal client

- Introduce injected daemon service and immutable domain projections.
- Replace local Ghostty views with remote presentation views.
- Route input, IME, mouse, resize, scrolling, selection, search, copy, links,
  accessibility, and notifications through shared backend actions.
- Remove local PTY, parser, terminal shaping, terminal render encoders, and
  terminal draw submission. Retain only the bounded compositor blit.

Exit gate: process traces prove the Swift PID performs none of the removed
operations and submits at most one compositor blit per admitted visible frame.

### Stage 6: topology and persistence migration

- Represent terminal, browser, and native panels with endpoint bindings.
- Route split, close, move, focus, and metadata actions through cmuxd.
- Import existing Swift session files once, then use daemon persistence.
- Move a live terminal across workspaces during output without changing its
  identity or displaying an old presentation frame.

Exit gate: one canonical mutation stream drives Swift, TUI, and browser.

### Stage 7: remove dual authority

- Delete local terminal creation and restore paths.
- Delete byte-mirror renderer paths and duplicate parser state.
- Delete global active-workspace and smallest-client resize assumptions.
- Keep protocol negotiation and migration import, not a second live authority.

Exit gate: no supported launch path creates a Swift-owned PTY or Ghostty terminal.

### Stage 8: hardening and rollout

- Run failure, scale, security, compatibility, performance, accessibility,
  localization, screenshot, video, and long-duration output tests.
- Bind every artifact to the final commit and repeat verification after the last
  code change.
- Build and exercise a unique tagged app through its tagged socket.

Exit gate: all P0 acceptance checks pass and no evidence predates the PR head.

## Acceptance matrix

| ID | Priority | Observable | Pass condition | Evidence |
| --- | --- | --- | --- | --- |
| PROC-1 | P0 | Swift terminal ownership | Swift PID has no PTY master owned for local terminals and no lifetime Ghostty runtime-app constructor, canonical-surface constructor, or PTY-master allocation. | Kernel-visible PID-scoped process census plus an Allocations trace containing a final in-library Ghostty process-census signpost snapshot. |
| PROC-2 | P0 | GPU ownership | Swift PID has no terminal CoreText shaping, render encoder, or draw call and submits at most one labeled full-surface blit per admitted visible frame; worker PID owns shaping, terminal render encoders, and draws. | Time Profiler plus Metal System Trace for exact PIDs, stable labels, and frame-to-blit count correlation. |
| PROC-3 | P0 | Frame provenance | Every accepted frame records worker audit identity, renderer epoch, presentation generation, and frame sequence. | Structured logs correlated with Metal trace. |
| LIFE-1 | P0 | GUI restart persistence | Force-kill and relaunch Swift; shell PID, TTY, cwd, terminal ID, topology, scrollback sentinel, and unread activity remain identical. | Automated restart test plus before/after protocol snapshots. |
| LIFE-2 | P0 | Renderer recovery | Kill a worker during output; shell PID remains alive, unrelated workspaces remain interactive, replacement worker shows a full snapshot, and no stale frame appears. | Failure-injection log, screenshots, and video. |
| MOVE-1 | P0 | Cross-workspace move | Move a terminal during numbered output; PID and terminal ID remain stable, all sequence numbers appear once, and the destination never presents the old generation. | Protocol transcript and captured screen. |
| MULTI-1 | P0 | Geometry arbitration | GUI and TUI attach at different sizes for 10 minutes; PTY dimensions follow only the lease holder and do not oscillate. | Lease event transcript and PTY size samples. |
| MULTI-2 | P0 | Input ordering | Concurrent GUI, TUI, and delegated automation input for one canonical terminal shares one daemon-assigned order without split paste, lost release, blocked key rollover, or duplicate command. | Deterministic integration test. |
| STATE-1 | P0 | Single topology authority | Every visible topology mutation corresponds to one daemon transaction and revision; client projections converge after reconnect and overflow. | Cross-client conformance trace. |
| STATE-2 | P0 | No dual terminal authority | Renderer workers alone consume semantic scenes and shape terminals. Swift consumes authenticated IOSurface frames, while cmux-browser consumes daemon-authored styled rows or a renderer-frame endpoint. Neither receives raw PTY output or instantiates a canonical parser; explicitly identified byte-stream compatibility clients cannot claim canonical parity. | Protocol capture and source/runtime linkage audit. |
| FID-1 | P0 | Text parity | Existing and external scene renderers match for ASCII, ligatures, emoji, CJK, combining text, wide cells, styles, cursor, palette, and OSC colors. | Golden frame corpus with documented tolerance. |
| FID-2 | P0 | Advanced parity | Links, selection, search, Kitty images, custom shaders, synchronized output, and IME behave equivalently. | Behavior tests, screenshots, and video. |
| PERF-1 | P0 | Sidebar responsiveness | Sustained active and background output causes no visible sidebar hitch and does not regress measured interaction latency beyond the approved baseline budget. | Signposted interaction trace and video. |
| PERF-2 | P0 | Dormant scale | 100 dormant workspaces create no renderer workers; worker count follows visible terminal workspaces. | Process census and memory report. |
| PERF-3 | P1 | Presentation overhead | Swift frame acceptance and layer update remain bounded per visible frame with no terminal-cell iteration. | Main-thread trace and signpost distribution. |
| FLOW-1 | P0 | Backpressure | Slow or stopped clients cannot block PTY parsing, topology mutations, or other clients; overflow forces a full resnapshot. | Saturation integration test. |
| SEC-1 | P0 | IPC rejection | Unauthenticated, stale-capability, malformed, and oversized requests are rejected before state mutation or unbounded allocation. | Negative protocol tests and memory trace. |
| COMPAT-1 | P0 | Upgrade behavior | Protocol v9 with every required mutation capability is read-write; v8, incompatible ranges, and missing capabilities connect read-only with an actionable update diagnostic and no mutation dispatch. | Command-log and fake-state-digest version matrix. |
| A11Y-1 | P0 | Accessibility | VoiceOver text, cursor, selection, links, and focus match the canonical terminal while rendering is remote. | Accessibility integration test and manual screen-reader pass. |
| CLEAN-1 | P0 | Legacy removal | Production code has one terminal authority and no local fallback that can own the same terminal. | Linkage audit, runtime assertions, and code review. |

Performance budgets will be finalized from Stage 0 measurements on the same
hardware and workload. Structural P0 checks are absolute and cannot be waived
by a favorable aggregate benchmark.

## Browser alignment

cmux-browser PR <https://github.com/manaflow-ai/cmux-browser/pull/4> contains
useful detach-versus-close behavior, atomic snapshot registration, bounded
queues, resnapshot recovery, reconnect generations, resize and input
coalescing, sparse palette overrides, and real-daemon tests.

Shared work should move to one generated protocol contract and fixture set.
The browser implementation must migrate away from raw byte replay,
browser-local canonical Ghostty state, exact build-SHA compatibility, and full
GPU-to-CPU frame readback. A coordination comment should link the implemented
protocol and conformance fixtures rather than propose an unanchored rewrite.

## Existing prototype disposition

- cmux PR <https://github.com/manaflow-ai/cmux/pull/8320> is a transport source,
  not a merge base. Reuse its external presenter, authenticated IOSurface path,
  frame metadata, generation checks, and nonblocking frame drop after resolving
  its lifecycle, buffering, size validation, and bootstrap findings.
- cmux PR <https://github.com/manaflow-ai/cmux/pull/8328> proves per-workspace
  worker launch and frame transport. Its byte mirror and Swift-owned PTY are
  explicitly temporary and must not survive the migration.
- Ghostty PR <https://github.com/manaflow-ai/ghostty/pull/122> is the preferred
  external Metal foundation after its public ABI size and cross-thread target
  size issues are fixed.

## Evidence layout

Final evidence is written under a commit-keyed artifact directory outside the
source tree:

```text
artifacts/terminal-backend/<commit>/
  manifest.json
  builds/
  tests/
  protocol/
  process-census/
  time-profiler/
  metal-system-trace/
  screenshots/
  video/
  accessibility/
  security/
```

`manifest.json` records commit, submodule commits, build tag, OS, hardware,
protocol versions, process IDs, commands, timestamps, artifact hashes, and the
acceptance IDs each artifact proves. Any code change invalidates prior runtime
evidence.
