# Daemon SSOT Refactor

## Goal

Make the zig daemon (`cmuxd-remote`) the single source of truth for all
workspace state. Mac and iOS become symmetric thin clients that mutate
state via incremental RPCs and render state from a subscribe stream.
Eliminates the entire class of dual-authority / timing-race bugs that
currently requires per-field ownership flags, pending-state
bookkeeping, and load-bearing initialization order.

## Non-goals

- Daemons peering with each other. Each mac runs its own siloed daemon;
  iOS is responsible for talking to multiple macs.
- CRDT / event sourcing. Single-writer SSOT is sufficient.
- Rewriting the daemon in Rust. Today's bugs are design problems, not
  memory safety problems.
- Cross-device scrollback or buffered PTY output. Too big, not needed
  for the current user stories.

## Target architecture

### Ownership

The daemon owns:
- Workspace identity (UUIDs, titles, colors, pinned, order, directory).
- Pane tree: splits, ratios, tab ordering, focused pane id.
- Session bindings: pane → PTY session id, session metadata.
- Unread counts + notification state.
- Port allocation (`CMUX_PORT` ordinals).
- Shell env baseline (`TERM`, `ZDOTDIR` pointing at daemon-bundled
  shell-integration).
- Working directory per pane, per workspace.
- Git probe state (branch, dirty, PR info) — daemon polls; clients
  subscribe.
- Workspace history log (lifecycle events: create, rename, close,
  reopen; tab history; split-layout snapshots so closed workspaces
  can be recreated on reopen).

Mac keeps as local state:
- Window frames, sidebar width, appearance prefs, keyboard shortcut
  bindings. (NSUserDefaults / plist, unchanged.)
- In-memory cache of the subscribe stream, purely for rendering.

iOS keeps as local state:
- Paired-mac list (manual entry, reuses today's "find servers" flow).
- Per-mac connection credentials (none needed beyond Tailscale).
- In-memory cache of merged workspace lists, purely for rendering.

### Storage

- System sqlite (`/usr/lib/libsqlite3.dylib`) linked into the daemon.
- DB path: `~/Library/Application Support/cmux/cmuxd/state.db`.
  WAL journal mode. Single-writer (the daemon process).
- No Swift sqlite dependency. The daemon is the only process that
  opens the handle. Clients always go through RPC.
- Schema: workspaces table, panes table, history table. See
  [Schema](#sqlite-schema) below.

### RPC surface

Transport stays as-is: Unix socket for mac client, WebSocket for iOS.

New incremental mutation RPCs (one per field):
- `workspace.rename { id, title }`
- `workspace.setColor { id, color }`
- `workspace.setPinned { id, pinned }`
- `workspace.setUnread { id, unread_count }`
- `workspace.setDirectory { id, directory }`
- `workspace.reorder { ordered_ids[] }`
- `workspace.setFocusedPane { id, pane_id }`
- `pane.split { parent_pane_id, direction, ratio }`
- `pane.close { id }`
- `pane.setTitle { id, title }`
- `pane.resize { id, ratio }`

Kept as-is:
- `workspace.create { title?, directory? } → { id }`
- `workspace.open_pane { workspace_id, command, cols, rows } → { pane_id, session_id }`
- `workspace.close { id }`
- `workspace.subscribe`, `workspace.changed` broadcast
- `session.attach/detach/resize/read/write` (iOS & mac transport layer)

Deleted:
- `workspace.sync` (the push-replace RPC). All callsites migrate to
  incremental ops.

### Change notifications

`workspace.changed` becomes an incremental diff:

```json
{
  "change_seq": 42,
  "workspaces": {
    "updated": [{ "id": "...", "fields": { "title": "new" } }],
    "created": [{ "id": "...", "title": "...", "directory": "..." }],
    "deleted": ["..."]
  },
  "panes": {
    "updated": [...], "created": [...], "deleted": [...]
  }
}
```

Clients apply the patch to their in-memory cache. On reconnect, clients
can send `change_seq` and receive only events after that cursor; if the
cursor is too old the daemon returns a full snapshot.

### Surface creation path

There is no Exec fallback. Every terminal surface (mac or iOS) goes
through `workspace.open_pane` and runs in Ghostty Manual I/O mode
against a daemon-owned PTY. If the daemon is unreachable, the surface
shows a "daemon reconnecting" banner and does not render a shell.

### Multi-attach semantics

When mac and iOS both attach to the same pane, the daemon multiplexes:
both see the same PTY output, keystrokes from either land in the shell.
Matches tmux `-a` attach semantics. No detach-steal behavior.

### iOS detach behavior

Brief disconnect (< 30s, phone backgrounded, WiFi blip): daemon holds
the attachment open and buffers a small ring (e.g. 256 KiB) of output.
Hard detach after 30s timeout; PTY itself stays alive until workspace
close or explicit user action.

### Multi-mac topology

iOS keeps one WebSocket per paired mac (manual entry via existing
"find servers" flow). iOS's sidebar merges workspaces from all
connected macs, grouped by machine. Daemons are siloed — mac A never
sees mac B's workspaces.

### Auth

Tailnet-only. The daemon's WebSocket listens on the Tailscale
interface; any tailnet peer can connect. Users who share a tailnet
accept the implication. No app-level secret or pairing ceremony in
Release (removes the DEBUG-era shared-secret file).

### Supervision

Mac owns the daemon lifecycle:
- `MobileDaemonBridgeInline` becomes a proper supervisor.
- Health check: ping RPC every 5s; if no reply in 3 attempts, assume
  dead.
- Auto-restart with exponential backoff (1s, 2s, 4s, capped 30s).
- If the daemon crashes 3 times in 60s, stop restarting and show a
  persistent error banner — don't loop.
- Daemon dies with the mac app (existing behavior).

### Offline UX

When the daemon is unreachable, the sidebar shows last-known workspaces
greyed out with a "Daemon reconnecting" banner. Mutations fail loudly
(toast or inline error); no queueing, no optimistic updates. Reading
works from the in-memory cache; terminals pause input/output.

### Observability

Sentry in the daemon. On panic or uncaught error, the daemon POSTs to
Sentry (same DSN as mac app, tagged `source=daemon`).

**Strict PII scrubbing.** No workspace titles, no directory paths, no
shell command arguments, no PTY output, no user env vars. Only
daemon version, platform, stack trace, daemon-internal log lines
(which are already PII-free), and the RPC method name that was in
flight when the crash happened. Scrubbing is enforced by
allowlisting fields, not blocklisting.

## sqlite schema

```sql
CREATE TABLE workspaces (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  directory TEXT NOT NULL DEFAULT '',
  color TEXT,
  pinned INTEGER NOT NULL DEFAULT 0,
  order_index INTEGER NOT NULL,
  focused_pane_id TEXT,
  created_at INTEGER NOT NULL,
  last_activity_at INTEGER NOT NULL,
  closed_at INTEGER              -- null for open workspaces
);

CREATE TABLE panes (
  id TEXT PRIMARY KEY,
  workspace_id TEXT NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  parent_pane_id TEXT,           -- null for root
  split_direction TEXT,          -- 'horizontal' | 'vertical' | null (leaf)
  split_ratio REAL,              -- null for leaf
  position INTEGER NOT NULL,     -- child ordering under parent
  title TEXT NOT NULL DEFAULT '',
  directory TEXT NOT NULL DEFAULT '',
  session_id TEXT,               -- null when detached
  unread_output INTEGER NOT NULL DEFAULT 0,
  port_ordinal INTEGER           -- CMUX_PORT assignment
);

CREATE TABLE workspace_history (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  workspace_id TEXT NOT NULL,
  event_type TEXT NOT NULL,      -- 'created' | 'renamed' | 'closed' | 'reopened' | 'pane_split' | ...
  payload_json TEXT NOT NULL,    -- event-specific details
  at INTEGER NOT NULL
);

CREATE INDEX idx_panes_workspace ON panes(workspace_id, position);
CREATE INDEX idx_history_workspace ON workspace_history(workspace_id, seq);
CREATE INDEX idx_workspaces_open ON workspaces(closed_at) WHERE closed_at IS NULL;
```

History retention: keep forever. Provide a Settings action "Clear
workspace history" that truncates `workspace_history` and VACUUMs.
No automatic pruning.

## Migration (existing users)

On first launch of the new build:

1. Daemon starts normally with an empty sqlite DB.
2. Mac reads its existing `SessionPersistenceStore` snapshot.
3. For each persisted workspace, mac calls
   `workspace.create` + `workspace.open_pane` per leaf pane,
   applies title/color/pinned via the new incremental RPCs.
4. Mac flips a `legacy_snapshot_imported` flag in NSUserDefaults.
5. Mac **does not delete** the legacy snapshot file for the first few
   releases (user's explicit ask: "in case we have bug"). A later
   release with high confidence in the new path deletes it.

From then on, mac stops writing the legacy snapshot. All workspace
state lives in the daemon's sqlite.

## Rollout

Single big-bang cutover in the next release (not 1.0.0, just the next
minor bump). No feature flag, no dual-write. The legacy Exec path and
`workspace.sync` RPC are deleted in the same release that introduces
the daemon SSOT.

## What changes in which directories

### Zig (`daemon/remote/zig/src/`)
- New: `persistence.zig` — sqlite wrappers, schema migrations,
  atomic writes.
- New: `history.zig` — history log append + query.
- New: `port_alloc.zig` — CMUX_PORT ordinal allocation per pane.
- New: `shell_env.zig` — baseline env + bundled shell-integration path.
- New: `sentry.zig` — minimal HTTP POST to Sentry on panic, PII-stripped.
- Extended: `workspace_registry.zig` — incremental mutations replace
  `syncAll`; add `changeBroadcaster` emitting diffs.
- Extended: `server_core.zig` — new RPC handlers; delete
  `handleWorkspaceSync`.
- Extended: `session_service.zig` — multi-attach multiplexing,
  detach-with-timeout.

### Shell integration
- Move `shell-integration/` bundle from mac app Resources to daemon
  resources (or teach daemon to locate it via a known path). Daemon
  exports `ZDOTDIR` pointing at its own copy so release builds don't
  depend on mac bundle layout.

### Swift mac (`Sources/`)
- Deleted: `Sources/Sync/WorkspaceDaemonBridge.swift`,
  `hasPendingDaemonSessionAssignments`, `customXxxOwnedByDaemon`
  flags, the local-Exec branch in
  `GhosttyTerminalView.createSurface`.
- Extended: `MobileDaemonBridgeInline` becomes the daemon supervisor
  (health check + auto-restart + error banner).
- Extended: `TabManager` becomes a read-through cache of daemon state,
  driven by the subscribe stream.
- New: `DaemonClient.swift` — wraps the control socket with the new
  incremental RPC methods and subscribe stream decoding.

### Swift iOS (`ios/Sources/`)
- Deleted: `tmuxSessionName: "local-<remoteId>"` fallback;
  `SubscribeRoundWaiter` kick machinery;
  `applyDaemonMintedIdentity`.
- Extended: `TerminalDaemonConnection` maintains N simultaneous
  connections (one per paired mac) and merges the streams.
- New: multi-mac sidebar grouping.

## Testing

All four strategies, in priority order:

1. **Zig daemon unit tests** — per-module tests in
   `daemon/remote/zig/src/`. Cover persistence round-trip, history
   append + query, port allocation uniqueness, diff broadcast
   correctness, detach-timeout behavior.
2. **Python socket tests** (`tests_v2/`) — cover the new RPC surface
   from a third client. Language-agnostic regression catch for the
   mac + iOS teams.
3. **E2E XCUITests** — workspace create-rename-propagate flows
   (mac → daemon → iOS simulator). Existing harness; add 5-8 test
   classes.
4. **RPC fuzzer** — feeds random JSON payloads against a running
   daemon. One CI job that runs for N minutes.

## Performance gate

Before cutting the release, add a keystroke-latency benchmark
comparing Manual I/O (daemon path) vs Exec (current release default).
Ship criterion: Manual I/O must be within 5ms of Exec at p99 on a
reference machine. If not, block the release and optimize
(batch writes, kqueue PTY pump, pipe vs socket).

## Open questions / risks

- Shell integration bundling: does the daemon ship the
  `shell-integration` dir as a sibling of the binary, or as embedded
  resources? Affects daemon binary layout and Release packaging.
- Sentry DSN in release: is Sentry configured to accept daemon events
  with a different tag, or do we need a second project? Coordinate
  before first release.
- Daemon autostart on mac boot: today the daemon dies with the mac
  app. Post-refactor, do we want a LaunchAgent so the daemon stays
  alive across mac app quits? (Opens the "what data survives app
  quit" question.) **Tentatively: no LaunchAgent; daemon stays
  coupled to mac app lifecycle.**
- Data loss during crash-mid-write: sqlite WAL handles durability.
  Confirm with a fsync-on-commit test that a SIGKILL mid-RPC leaves
  a consistent DB.

## Phasing (PR-sized chunks)

1. **PR 1 — sqlite persistence skeleton.** ✅ **Shipped.** `persistence.zig`
   + `workspace_persistence.zig` landed. System sqlite linked via
   `linkSystemLibrary("sqlite3")`. Schema: `workspaces`,
   `workspace_history`, `selection` tables (WAL mode). `Service.attachDb`
   hydrates on boot, `Service.persistWorkspaces` saves on every mutation
   (hooked through `notifyWorkspaceSubscribers`). `--db-path` flag on
   `serve --unix`. Mac passes `<socket>.db` derived path. Pane tree
   serialized as JSON blob per workspace row (matches existing
   `PaneNode` union shape without requiring a registry refactor).
   Regression test covers: save + hydrate, closed workspaces kept out
   of reload, history append+query, SQL-injection hardening
   (`'); DROP TABLE workspaces; --` round-trips verbatim), split-tree
   session bindings survive restart.

2. **PR 2 — incremental RPCs.** ✅ **Shipped** (diff broadcaster
   deferred). New mutation RPCs on the daemon:
   `workspace.setUnread/setDirectory/setPreview/setPhase/reorder/select/setColor/setPinned`,
   `pane.setTitle/resize/setFocused/close`, plus camelCase aliases for
   existing ones. Every mutation handler now fires
   `on_workspace_changed` (persistence + broadcast). Swift
   `DaemonConnection` has matching `send*` helpers. The broadcaster
   still emits full snapshots via `workspace.changed` rather than
   field-level diffs; deferred because the eventual PR 7 design is
   cleaner from scratch than retrofitted on top.

3. **PR 3 — daemon supervisor + Sentry.** ✅ **Shipped**
   (Sentry deferred). `MobileDaemonBridgeInline` is a proper
   supervisor: 5s ping-based health check over the Unix socket,
   3-consecutive-failure threshold triggers restart, circuit breaker
   gives up after 3 crashes in 60s → `.failed`. `DaemonHealthState`
   enum + `Notification.Name.cmuxDaemonHealthChanged` notification.
   `DaemonHealthBanner` SwiftUI view rendered in ContentView overlay;
   hidden while healthy, slides in with orange/red bar when
   reconnecting/failed. Zig-side Sentry panic reporter not wired
   (needs DSN config + HTTP client in zig).

4. **PR 4 — mac becomes a thin client.** 🟡 **Partial.** Landed:
   workspace.sync is no longer destructive — daemon's `syncAll`
   rewritten as an UPSERT that preserves pane session_ids when the
   payload omits them, and leaves unmentioned workspaces alone.
   Regression tests pin both behaviors. `surface.checkDaemon.exec_fallback`
   tripwire log in `GhosttyTerminalView.createSurface` shows which
   surfaces missed the daemon window. Deferred: deleting the Exec
   fallback path itself (needs surface-level "daemon is down, no
   shell backing right now" state with recovery), turning
   `TabManager` into a pure projection of daemon state, one-shot
   legacy `SessionPersistenceStore` migration.

5. **PR 5 — iOS multi-mac + symmetric client.** 🟡 **Partial.**
   Landed: the phantom-shell `"local-<remoteId>"` session-name
   fallback is deleted. iOS workspaces without a daemon session id
   now show `"Waiting for Mac to finish starting this workspace…"`
   in `.connecting` phase, and `connectIfNeeded` refuses to attach
   with a `pending-` prefix (no more silently-spawned fresh shells).
   Deferred: N-WebSocket multi-mac connection handling + merged
   sidebar grouping.

6. **PR 6 — workspace history API + UI.** ✅ **Shipped** (UI
   deferred). Daemon: `workspace.history.list/.query/.clear` RPCs
   backed by the sqlite `workspace_history` table. Events (`created`,
   `renamed`, `closed`, `pane_split`) are appended from every mutation
   handler via `Service.appendHistory`. Swift client:
   `DaemonConnection.fetchWorkspaceHistory/clearWorkspaceHistory`.
   A user-facing history view (sidebar section or Settings pane)
   still needs building.

7. **PR 7 — delete workspace.sync.** 🟡 **Unblocked** (not yet
   shipped). Every field that workspace.sync pushes now has an
   incremental RPC equivalent (including the newly-added
   `setPreview` and `setPhase`). `WorkspaceDaemonBridge.performSync`
   hasn't been rewritten yet; the switchover is a pure refactor at
   this point, no missing fields blocking it. Once done, delete
   `sendWorkspaceSync` and the daemon-side `handleWorkspaceSync` +
   `syncAll`.

8. **PR 8 — perf gate.** ⏳ **Deferred.** Needs a real keystroke
   benchmark that drives the PTY pump path
   (`terminal.write → read round trip`), not a ping-RPC microbenchmark.
   Manual I/O has been shipping in DEBUG for months without
   complaints, so the regression risk without the gate is low.
   Revisit when the Swift-side SSOT work (PR 4/5) is closer to
   done and we're approaching release cut.

**Test coverage now:** 32 zig unit + integration tests passing. Covers
persistence round-trip, pane tree JSON, upsert-not-destructive syncAll,
SQL injection hardening, split tree + session-binding hydration across
simulated daemon restart.

**Live diff:** ~11 Swift + zig files modified; 2 new zig files
(`persistence.zig`, `workspace_persistence.zig`). No commits yet —
the working tree holds the whole refactor for user review.

Each PR should land tagged reloads so the rollout can be dogfooded
incrementally.
