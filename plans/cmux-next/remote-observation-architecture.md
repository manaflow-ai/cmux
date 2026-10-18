# Read-only remote observation architecture

This plan connects existing cmux transport, session identity, ACPMUX observation,
and durable receipt primitives. It does not create a second remote-control stack.

## Goals

- Inspect Codex or another app-server running on an SSH host without enrolling
  that process as a native cmux remote-control host.
- Give every observation a stable, reconnect-safe identity and sequence cursor.
- Persist coordination receipts through the existing ACPMUX mailbox contract.
- Keep UI work small: Swift owns SSH lifecycle and machine routing, Rust owns
  protocol normalization and durable receipts, and React renders normalized data.
- Preserve the existing no-polling, bounded-work, and frame-budget rules.

## Existing owners

| Concern | Existing owner | Reuse |
| --- | --- | --- |
| SSH host identity and lifecycle | `CmuxNextRemote/SSH/SSHHost.swift`, `SSHMachineLink.swift`, `SSHService.swift` | Probe, install, start, stop, and reconnect the SSH link |
| Paired server identity | `ServerReach.swift`, `ServerReachService.swift`, `ServerMachineSession.swift` | Keep paired servers separate from SSH machine sessions |
| Remote daemon socket | `cmux-tui remote connect ssh://...` and `DaemonConnection` | Continue using the normal remote cmux daemon path |
| Session/activity identity | `AgentActivitySocketSource.swift` | Machine/session IDs, sequence cursors, `after_seq` replay |
| Authenticated peer transport | `cmux-tui/crates/acpmux/src/peer.rs` | Bearer + peer token, `served_as`, generation, watch/delta stream |
| Read-only agent observation | PR #21258's `cmux-tui-core/src/server/agent_session_observe.rs` and attach wiring | `agent-session-observe-v1` and mutation refusal; land this capability before consuming it here |
| Durable receipts | `acpmux/src/mailbox.rs`, `src/protocol/mailbox.rs` | Idempotency, cursors, recipient-scoped ack, delivery receipts |

## Identity envelope

Every observation event and receipt carries:

```text
machine_id          SSHHost.machineID or the peer's machine identity
route_kind          ssh_app_server | acpmux_peer | local
remote_session_id   app-server or ACP session identifier
daemon_session_id   cmux daemon session identifier when available
source_epoch        durable producer/daemon epoch
source_sequence     producer sequence within that epoch
delivery_generation transport connection generation
mailbox_cursor      delivery cursor used for replay
observed_at         monotonic/local timestamp for diagnostics
```

The tuple `(machine_id, route_kind, remote_session_id, source_epoch,
source_sequence)` is the stable deduplication key. `delivery_generation` and
`mailbox_cursor` describe transport delivery only; they are not source identity.
A reconnect may replay from the last durable cursor, but an identical source key
must retain its original immutable payload and metadata.

## SSH app-server inspection

`SSHMachineLink` remains responsible for the cmux daemon link. An inspection
sidecar uses the same `SSHHost` and `SSHCommandLine`. When an existing app-server
control socket is available, it attaches through
`codex app-server proxy --sock PATH`; this is the live-observation route. A
separate `codex app-server --stdio` child is a fresh process and is limited to
history/status inspection unless the advertised capability explicitly supports
external live observation.

The sidecar may perform:

1. app-server initialize/capability negotiation;
2. read-only session and status inspection;
3. event framing, sequence assignment, and reconnect replay;
4. receipt publication through the Rust adapter.

It may not:

- reuse native remote-control enrollment or `ServerReach` state;
- send prompt, cancel, permission, filesystem, or workspace mutations;
- expose the app-server bearer token to the webview or mailbox body;
- silently turn an inspection route into an attached cmux daemon session.

The observed `remoteControl/status/changed` event is a capability/status signal.
`disabled` with a null environment ID means inspection is available only as far
as the app-server reports it; it is not proof of native remote-control access.

## ACPMUX bridge

Add a Rust-only adapter over the existing authenticated `Peer::request` path and
the mailbox's storage/receipt primitives. The adapter should expose a typed
observation receipt, not a new transport. The current `_acpmux/mail/*` handlers
deny `Origin::Peer`/Web access by default, so this adapter must add an explicit,
peer-authenticated allowlist and sender/session binding; it must not bypass the
origin gate by forwarding ordinary mailbox RPCs:

- `observation.snapshot`
- `observation.delta`
- `observation.reconnect`
- `observation.capability`
- `observation.error`

Receipts are addressed to a stable recipient (`acp:<session-id>` or a named
observer role). The mailbox message ID is the idempotency key. The receipt
metadata contains the identity envelope and source cursor; message bodies remain
untrusted data.

Only a peer-authenticated connection with `served_as == peer` may publish or
read remote observation receipts through that adapter. Page relays, ordinary
bearer WebSockets, and unbound mailbox callers remain denied. A receipt sender
must map to the peer's machine/session identity and connection generation;
caller-supplied metadata cannot grant that mapping. Acknowledgement proves
transport acceptance, not that a model understood or acted on the receipt.

## Visual-inspection loop

Visual inspection is a consumer of the same observation contract, not a second
event or control format. Every inspection run writes one durable receipt with
these fields:

```text
source_head          exact source commit under inspection
source_path          repository/worktree or app artifact identity
hosted_url           canonical hosted preview or review URL, if any
browser_matrix       browser/engine, viewport, DPR, theme, and feature flags
state_transition_ids observation receipt IDs that produced the visible state
cases[]              row/state/transition IDs, artifacts, and per-case verdict
capture_dimensions   width x height; MP4 also records duration and frame rate
artifact_sha256      hash for every visual artifact
dom_artifact         optional serialized DOM/accessibility snapshot plus sha256
host_tag             machine, runner, and app/build tag used for capture
identity             the envelope above (machine/session/source key/delivery)
verdict              pass | fail | blocked | unverified
failure_class        product | runner | environment | missing-evidence
evidence_gap         optional missing-clickable-build or other explicit gap
```

Each `cases[]` entry contains the browser-matrix row, named state, transition
IDs, visual proof references, artifact hashes, and a per-case verdict. The
aggregate verdict is `pass` only when every required row is present and passes;
skipped or unavailable rows remain `unverified` and cannot be hidden by a
top-level pass.

The required handoff is deliberately small and reproducible:

1. Record the exact source head and hosted URL before opening the surface.
2. Declare the browser matrix before capture. A matrix row is one engine,
   viewport, DPR, theme, and relevant feature-flag tuple.
3. Apply one named state transition at a time. The transition ID is the
   observation receipt ID (or a deterministic child ID) and must be present in
   the screenshot and DOM artifact manifest.
4. Capture visual proof as either a verified before/after screenshot pair or a
   screencap MP4. Record dimensions for both; MP4 also records duration and
   frame rate. Hash every artifact. DOM/accessibility snapshots are optional
   diagnostic evidence, not a hard gate.
5. Prefer a clickable hosted build for dogfood. If no clickable build exists,
   retain the visual artifact and set `evidence_gap: missing-clickable-build`;
   do not silently call the run fully dogfooded.
6. Classify failures before proposing a fix. `product` means source/runtime
   behavior; `runner` means browser/host/CI harness; `environment` means auth,
   network, or unavailable backend; `missing-evidence` means the path was not
   actually exercised.
7. Publish the receipt through the existing mailbox/observation path. A retry
   reuses the same transition and message IDs and the same immutable artifact
   manifest, so a reconnect cannot create a second visual result or mutate the
   first payload.

The canonical browser matrix should start with Chromium and WebKit at the
standard and narrow composer widths, light and dark themes, and reduced-motion
on/off where motion is part of the acceptance criterion. Add Firefox or a
remote engine only when the surface claims support for it. A skipped matrix row
is recorded as `unverified`, never as a pass.

Coordination lanes C02, C14, C18, and C04 should consume this receipt shape
directly. They may add product-specific state names, but must not invent a
second screenshot manifest, transition ID, or runner-failure taxonomy.

## Visual evidence feed projection

The PR, bead, chat, and source-head feed (canonical bead `cx-4oa.1` under epic
`cx-4oa`) is a projection over the existing Beads/HQ/gallery records; it is not
a second database. The already-landed Linux gallery, diff, and sticky-comment
path remains authoritative for the rendered proof and its review link. A feed
item keeps the
authoritative record IDs and embeds the receipt cases needed to open or compare
evidence:

```text
bead_id             canonical bead/task ID
pull_request        repository and PR number
chat_id             Codex/Cmux chat or lane identity
source_head         exact commit, matching the receipt
hosted_url          clickable dogfood/review URL, when available
build               tag, host, artifact URL, sha256, and capture metadata
cases[]             visual cases and per-case verdicts
evidence_gap        explicit gap such as missing-clickable-build
receipt_id          immutable observation receipt ID
retry_message_id    mailbox idempotency key reused on retry
```

The projection reads authoritative state by these IDs and may cache only a
bounded, disposable index. A missing hosted URL or build artifact remains an
evidence gap; the feed must not synthesize a green state from a receipt alone.
Retries update delivery status under the same `receipt_id` and
`retry_message_id`, preserving the original artifact hashes and source head.
Consumers can therefore compare PRs, beads, and chats without inventing a
lane-specific manifest or mutating the source of truth.

Keep `cx-4oa.1` open until the Freestyle matrix has exact receipts for every
required row and the feed card exposes the corresponding stills or screencap,
downloadable artifact metadata, and clickable hosted URL (or an explicit
`missing-clickable-build` evidence gap). A card that only links a PR or reports
an aggregate pass is incomplete.

## Reconnect and backpressure

- Keep one in-flight read per `(machine, session, generation)`.
- Replay from the last acknowledged sequence/cursor before accepting live deltas.
- Cap event and receipt buffers. On overflow, emit a typed gap receipt and require
  a bounded snapshot refresh; never grow an unbounded queue.
- Treat push notifications as wake-up hints. The mailbox and source cursor remain
  authoritative after reconnect.
- Stop the sidecar on SSH disconnect, capability refusal, or auth failure; expose
  the reason as a typed receipt.

## Performance rules

- Decode app-server and ACPMUX JSON off the main actor.
- Coalesce observation deltas once per frame for UI projections only. Durable
  terminal, error, and conflict receipts remain individually ordered and are
  never dropped by visual coalescing.
- Keep Swift responsible for process/SSH lifecycle only; do not move AppKit
  sidebar layout or `Observation` models into Rust.
- Move pure Rust work first: framing, cursor reconciliation, receipt encoding,
  deduplication, and capability normalization.
- Keep React responsible for webview rendering and interaction, consuming typed
  snapshots/deltas rather than owning transport state.
- Add receipts for decode time, queue depth, replay count, gap count, and publish
  latency. Enforce bounded budgets before attempting larger rewrites.

## Delivery slices

1. **Contract:** define the identity envelope and observation receipt schema in
   the ACPMUX protocol spec; add Rust encode/decode and dedup tests.
2. **Peer path:** adapt existing `PeerNotice` and mailbox calls; test peer-token
   authorization, reconnect generations, cursor replay, and recipient-only ack.
3. **SSH sidecar:** add a read-only app-server stdio inspector behind
   `SSHMachineLink` credentials; test initialize, status changes, disconnect, and
   capability refusal.
4. **Durability:** persist the last acknowledged cursor and replay gap receipts;
   verify restart recovery without duplicate delivery.
5. **UI consumption:** expose normalized receipts to existing activity/session
   surfaces. Do not add a new remote-control UI until the transport receipts are
   stable and measured.

## Explicitly separate work

PR #21305's durable runs, attach tickets, run board, and UI tournament are a
separate product surface. They may consume observation receipts later, but they
do not own SSH transport, ACPMUX peer authorization, or session identity.
