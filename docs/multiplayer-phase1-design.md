# cmux Multiplayer Phase 1: Collaborative Editing and Presence

## Status

This document is the implementation contract for Phase 1. It deliberately covers only actively shared file buffers and ephemeral cursor/selection presence. It does not design whole-repository sync, git automation, peer-to-peer transport, terminal sharing, real accounts/ACLs, or polished conflict UX.

## Repository Findings

cmux is a shipped macOS application whose primary client is Swift 6 with SwiftUI, AppKit, and Observation. The macOS app still has a large app target under `Sources/`, plus a growing Swift Package Manager graph under `Packages/macOS/`, `Packages/Shared/`, and `Packages/iOS/`. The build is Xcode-driven through `cmux.xcodeproj`/`cmux.xcworkspace`; local debug validation uses `./scripts/reload.sh --tag <tag>`. JavaScript/TypeScript exists for the web app, embedded webviews, and Cloudflare Workers. There is also Zig for Ghostty, Go for the remote daemon, Rust for native FFI, and Python for integration tests.

cmux already has an editable file-content surface: `FilePreviewTextEditor` and `SavingTextView` in `Sources/Panels/FilePreviewTextEditor.swift`, hosted by `FilePreviewPanel` and `MarkdownPanel`. This is a production plain-text `NSTextView` editor for file preview panels, not Monaco, CodeMirror, Ace, LSP, syntax highlighting, or a full IDE editor. Phase 1 therefore wires collaboration to the existing plain-text file editor and does not build cmux's first full code editor.

cmux already has a Unix-domain socket and CLI API. The preferred command surface is v2 line-delimited JSON RPC through `CmuxControlSocket` and the CLI in `CLI/cmux.swift`; `cmux rpc <method> <json>` already exposes new v2 methods. Phase 1 must not add a conflicting app-control transport. The collaboration relay is a separate outward WebSocket service used only for multiplayer document traffic, while local configuration/control should fit the existing socket/CLI conventions later.

cmux also has a Cloudflare Workers presence service in `workers/presence/`, backed by Durable Objects. That service is team/device presence, not document collaboration. Phase 1 follows its deployment style, but keeps document collaboration on a separate minimal relay so CRDT payloads remain opaque and the relay does not inherit device-registry semantics.

## CRDT Selection

### Options Considered

Automerge Swift (`automerge/automerge-swift`) is the strongest native fit. It wraps the maintained Automerge Rust core for Apple platforms, is MIT licensed, supports Swift Package Manager, exposes Automerge text/list/map CRDTs, and is designed for offline-first sync. It has credible multi-document support when paired with Automerge Repo Swift, but Phase 1 does not need Automerge Repo's full storage/network stack because cmux needs a dumb relay protocol and app-specific disk reconciliation. Integration cost is moderate: add an SPM dependency, wrap it in a cmux package, define binary update messages, and map `NSTextView` edits to Automerge text changes.

Yjs is extremely mature in JavaScript, MIT licensed, and has excellent editor ecosystem support. In this repo it would either require a JavaScript runtime/sidecar or YSwift/Yrs bindings. YSwift exists but is explicitly work-in-progress, brings a Rust/XCFramework binding path similar to Automerge, and naturally pairs with Yjs-specific WebSocket providers that are more opinionated than this relay-only design. Choosing Yjs would bias cmux toward a JS collaboration stack despite the host editor being Swift/AppKit.

Automerge via a Node or Rust sidecar would work technically, but adds process management, IPC, packaging, crash recovery, and socket security concerns. It also duplicates the app's existing native state-management direction. This is unjustified for Phase 1 because a native Swift binding exists.

A small in-repo text CRDT is possible for tests and prototyping, but it is a long-term maintenance burden. It would need years of edge-case hardening to match Automerge/Yjs, especially around large files, undo metadata, and cross-language interoperability.

### Decision

Use Automerge Swift as the intended CRDT library for the production Phase 1 client module. The cmux-facing API is a thin `CmuxCollaboration` package so the rest of the app never depends directly on Automerge types. The relay treats Automerge binary changes and snapshots as opaque base64 strings.

Undo/redo remains local-editor undo for Phase 1. Automerge preserves causal operations, but collaborative undo semantics are not polished here; remote changes clear or segment local undo groups rather than promising Google Docs-grade shared undo.

The first implementation may include a very small pure-Swift text CRDT test harness only where it keeps the package testable before the Automerge dependency is fully wired. That harness is not the selected production CRDT and must not leak into the public app integration contract.

## Document Model

Each actively co-edited file is one CRDT document. A document identity is:

- `sessionID`
- `repositoryID`, a user-visible stable label for the clone, normally the workspace root path normalized locally
- `filePath`, the repository-relative path

Absolute paths are never broadcast. Peers with different local clone roots map the same repository-relative path to their own filesystem.

A document is created when a peer explicitly shares a file in a multiplayer session. The first sharing peer reads its local file from disk, initializes an Automerge text object with that content, records the file's last observed metadata and content hash, then broadcasts a `document.snapshot` frame.

A second peer joins when it opens the same relative file in the same session and opts into collaboration. It does not trust its local disk content as current state. It requests a snapshot and replaces the in-memory shared buffer with the received CRDT state. The peer's on-screen editor updates from the CRDT-resolved text.

A document is torn down locally when the peer closes the shared file or leaves the session. If this peer still has the document open only remotely, nothing is written for that peer. If this peer is closing its last local view of the document, the client writes the current CRDT-resolved text to that peer's real on-disk file.

Disk reconciliation is deterministic:

1. When opening, record `baseDiskHash` and file metadata.
2. While the CRDT document is live, watch or poll the file metadata at save/close boundaries.
3. On close, compute `currentDiskHash`.
4. If `currentDiskHash == baseDiskHash` or `currentDiskHash == lastWrittenHash`, write the CRDT text atomically and record the new hash.
5. If `currentDiskHash` differs, an out-of-band edit occurred, such as an external editor save or `git checkout`. Phase 1 does not merge that external file with the CRDT. It writes the CRDT text to a sibling conflict file named `<filename>.cmux-collab-conflict-<timestamp>` and leaves the externally changed original untouched. The user sees a clear conflict state. This avoids silent data loss.

Files not explicitly opened and shared are never read, watched, updated, or written by this system.

## Relay Protocol

Transport is WebSocket. Every peer connects outward to the relay. No peer accepts inbound connections. WebSocket is chosen because it is already the natural transport for Cloudflare Durable Objects, supports bidirectional low-latency messages, and avoids introducing a custom TCP framing protocol.

The relay stores only active sessions and connected peers in memory:

- `sessionID -> { tokenHash, peers }`
- `peerID -> websocket, display metadata, lastHeartbeatAt`

The relay does not parse, order, transform, or merge CRDT payloads. It validates envelope size and session membership, then forwards frames to other peers in the same session.

### Session Messages

Client to relay:

```json
{ "type": "session.create", "peer": { "peerID": "...", "displayName": "...", "color": "#7A5CFF" } }
{ "type": "session.join", "sessionCode": "ABCD-1234", "token": "...", "peer": { "peerID": "...", "displayName": "...", "color": "#7A5CFF" } }
{ "type": "peer.heartbeat" }
{ "type": "document.update", "documentID": "...", "updateID": "...", "payloadBase64": "..." }
{ "type": "document.snapshot.request", "documentID": "...", "requestID": "..." }
{ "type": "document.snapshot", "documentID": "...", "requestID": "...", "payloadBase64": "...", "textHash": "..." }
{ "type": "presence.update", "activeFile": "Sources/Foo.swift", "cursor": 128, "selection": { "anchor": 128, "head": 142 } }
```

Relay to client:

```json
{ "type": "session.created", "sessionID": "...", "sessionCode": "ABCD-1234", "token": "..." }
{ "type": "session.joined", "sessionID": "...", "peers": [...] }
{ "type": "peer.joined", "peer": {...} }
{ "type": "peer.left", "peerID": "...", "reason": "disconnect|timeout|leave" }
{ "type": "relay.error", "code": "invalid_token|session_not_found|too_large|rate_limited", "message": "..." }
```

Document and presence frames are forwarded unchanged except for relay-added `fromPeerID` and `receivedAt`.

### Catch-Up Strategy

Reconnect and join use full document state snapshots, not buffered replay. The relay is stateless with respect to document content and therefore cannot replay missed CRDT updates. On reconnect, the peer rejoins the session, announces the document IDs it has open, and sends `document.snapshot.request` for each live document. Existing peers respond with full snapshots. The reconnecting peer applies the first valid snapshot whose `documentID` matches and whose text hash is well-formed. Later duplicate snapshots are merged through Automerge if they represent the same document; if they decode to different histories but same text, the client keeps the first and logs a warning.

If no peer answers a snapshot request within five seconds, the document enters `resyncUnavailable`. Local editing may continue offline against the peer's current CRDT state, but the UI shows that collaboration is disconnected. The next successful snapshot/update merge clears the state.

## Bootstrapping a New Peer

When peer C joins a session where A and B are already editing file X, C's disk content is only its clone's current file. C must not broadcast that file as an update. It sends `document.snapshot.request` for X. Existing peers deterministically decide who answers:

1. The peer with the lexicographically smallest `peerID` among peers that have X open sends the snapshot after 50 ms.
2. Other peers schedule responses after 250 ms plus a peerID-derived jitter.
3. If C receives a valid snapshot before its timer fires, each later peer cancels its response.

If multiple snapshots race, C applies the first valid snapshot and then merges any later valid snapshot as a normal CRDT merge. Automerge convergence makes duplicate snapshots safe. C then displays the resolved text and records its local disk baseline for close-time reconciliation.

## Presence Protocol

Presence is ephemeral and not stored in the CRDT document. It includes:

- `peerID`
- display name
- color
- active repository-relative file path
- cursor UTF-16 offset for `NSTextView` compatibility
- selection anchor/head UTF-16 offsets
- monotonic sequence number
- sent timestamp

Presence is cleared on disconnect, session leave, or heartbeat timeout. It is never written to disk and never included in Automerge snapshots.

Rate limits:

- Cursor/selection moves: at most 20 updates per second, coalesced to the latest state.
- Active-file changes: immediate.
- Display metadata changes: at most 1 update per second.
- Document CRDT updates are not delayed by presence throttling. Presence and document messages share the WebSocket but have independent queues; document updates have priority when the send buffer is backed up.

## Client Module Interface

The Swift package exposes a UI-framework-agnostic actor and value model:

```swift
public actor CollaborationSession {
    public func connect(invite: CollaborationInvite) async throws
    public func disconnect() async
    public func open(file: SharedFileDescriptor) async throws -> CollaborationDocumentSnapshot
    public func close(file: SharedFileDescriptor) async throws -> DiskReconciliationResult
    public func applyLocalEdit(file: SharedFileDescriptor, range: Range<Int>, replacement: String) async throws
    public func setLocalSelection(file: SharedFileDescriptor, cursor: Int, selection: Range<Int>?) async
    public var events: AsyncStream<CollaborationEvent> { get }
}
```

The package has no SwiftUI or AppKit dependency. AppKit-specific range mapping and rendering remote cursors live in a small macOS adapter around `SavingTextView`.

## Failure Modes

Relay unreachable at session start: session creation/join fails fast with `relayUnavailable`. No local file is changed. The file preview editor continues as a normal local editor.

Relay drops mid-session: the client marks the session `disconnected`, clears remote presence after the heartbeat timeout, and keeps local CRDT editing available. It queues local CRDT changes in memory. On reconnect it rejoins and requests full snapshots for every open shared document, then merges queued local changes. If the app quits before reconnect, unsaved live CRDT state is reconciled to disk through the normal close/termination path.

Local file changes on disk while a CRDT doc is live: the CRDT buffer remains authoritative for the shared session. On close/save reconciliation, if the disk hash changed outside cmux, cmux writes the CRDT text to a conflict sibling and leaves the changed original untouched. This is the deterministic Phase 1 answer; it does not attempt a three-way merge.

Two peers both try to be first to share the same file: both create CRDT docs from their local file content and broadcast snapshots. The lower `peerID` snapshot is treated as the canonical bootstrap if histories are unrelated. The higher `peerID` peer discards its just-created doc and joins the canonical snapshot, then reapplies any local edits it made after the share attempt. This can briefly replace the higher peer's view. This is accepted in Phase 1 to avoid split-brain document IDs.

A peer closes their laptop for an hour and reopens: other peers see `peer.left` after heartbeat timeout and continue. The sleeping peer reconnects, clears stale remote presence, requests full snapshots for all open docs, merges any local offline edits, and then resumes live updates. If its local file was externally changed while asleep, the close-time conflict-file rule still applies.

Relay restarts: all sessions die because Phase 1 relay state is in memory only. Clients detect socket close, mark `relayRestarted`, and require the user or CLI to create/join a new session. Open local CRDT buffers remain usable and can be saved locally.

Malformed or oversized relay frame: the relay closes that peer's socket with an error and broadcasts `peer.left`. Other peers continue.

## Explicit Non-Guarantees

Phase 1 does not guarantee whole-repository consistency, branch consistency, or that every collaborator is on the same commit.

Phase 1 does not guarantee external disk edits are merged. It prevents silent overwrite by writing a conflict sibling when an out-of-band change is detected.

Phase 1 does not guarantee a peer will never see a brief revert during simultaneous first-share or reconnect snapshot races.

Phase 1 does not provide durable relay persistence. Relay restart kills active sessions.

Phase 1 does not provide authentication beyond an invite token. Anyone with the token can join.

Phase 1 does not share terminal I/O, shell state, git state, diagnostics, or agent sessions.

## Test Plan

Automated tests must cover:

- Concurrent overlapping text edits applied in different orders across three replicas converge to identical content.
- Offline/reconnect with independent edits on both sides converges after full snapshot exchange.
- Last-local-close writes CRDT-resolved text to disk when the disk baseline is unchanged.
- Out-of-band disk modification produces a conflict sibling and leaves the original file untouched.
- Relay unreachable and relay disconnect produce explicit client states rather than hanging.

Manual validation before trusting real sessions:

- Two tagged cmux app instances against two separate local clones, sharing one file through the relay.
- Remote cursor rendering in the plain-text file preview editor.
- Save/close/reopen behavior on both clones.
- Relay restart and app sleep/wake.

## Phase 2 and Later

Phase 2 can add whole-repository sync for explicitly saved but not co-edited files, richer conflict UI, durable relay/session persistence, stronger authentication/authorization, NAT traversal or P2P transport if relay-only becomes insufficient, and terminal sharing as a separate protocol. Git operations remain manual unless a later design explicitly changes that rule.
