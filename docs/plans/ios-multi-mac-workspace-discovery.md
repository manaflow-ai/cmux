# iOS Multi-Mac Workspace Discovery Plan

## Goal

Users signed in to cmux on multiple Macs should see all of their available cmux workspaces on iPhone and attach to any online workspace.

This plan intentionally keeps the first implementation narrow:

- multiple Macs per user/team
- iOS discovery across those Macs
- team-scoped access using Stack teams
- personal team as the default
- workspace metadata and online/offline presence kept current in Rivet/Hive
- terminal transport still over iroh

This plan does not require mixed-host workspaces yet. In this phase, each workspace is still owned by one Mac/node, and iOS discovers a team-scoped directory of node-owned workspaces.

## Product Requirements

1. A user who signs in to cmux on two Macs can open iOS and see workspaces from both Macs.
2. The default scope is the user's personal Stack team.
3. Settings on macOS and iOS let the user choose a different Stack team.
4. Workspaces published to a shared team are visible to other team members only when the Mac/user has opted in to that team scope.
5. Offline Macs and their workspaces remain visible but greyed out.
6. iOS has a main-page header filter for online/offline and node/team views.
7. Rivet/Hive is kept up to date with node presence and workspace metadata.
8. Terminal sessions still attach over iroh; Rivet/Hive is the control plane, not the terminal data plane.
9. `cmx` keeps a no-Rivet mode for SSH/Linux/tmux-style use.
10. Stack/Auth and pairing deep links support all app channels: `cmux://`, `cmux-nightly://`, and `cmux-dev://`.
11. iOS defaults to a recency-sorted workspace inbox across all machines, with filters/grouping available from the header.

## Resolved Decisions

- Scope the first milestone to a team-scoped directory of node-owned workspaces. Do not build mixed-host workspaces in this milestone.
- Rivet/Hive is authoritative for the iOS-visible discovery directory, not for terminal/browser runtime state.
- The owning Mac/`cmx` runtime remains authoritative for local workspace existence, PTYs, browser sessions, terminal replay, and restored shells.
- `cmx server` must keep a no-Rivet mode for SSH/Linux/tmux-style use.
- Node identity is a stable install-scoped cmux instance id, not a hostname, hardware id, or Stack user id.
- Node presence publishing runs only while cmux is running. There is no separate login helper just to keep presence alive.
- iOS defaults to a flat recency-sorted cross-machine workspace inbox. Node grouping and online-only views are filters.
- Workspace deletion uses explicit tombstones or confirmed full replacement after local restore is ready. Absence from one snapshot is not deletion.
- Local restore of workspace shells/layouts/agent sessions is required for macOS app use, SSH remotes, and standalone Rust `cmx` TUI/tmux-style use.
- Stale workspace records are not automatically deleted by age. They remain until the same cmux instance revives and publishes authoritative replacement/tombstone state.
- Settings should expose an explicit unlink action for old/lost Mac/node records whose local `nodeID` will never revive.
- iOS/macOS should expose a client-side hide action for unavailable workspaces from a Mac without deleting backend records.

## Ownership Model

Rivet/Hive is the source of truth for the team-visible discovery directory that iOS reads:

- selected team id
- node list
- node online/offline presence
- workspace list per node
- workspace name, description, color, activity, timestamps, and other display metadata
- pairing/attach metadata needed for iOS to open an iroh connection

The Mac app and local `cmx` runtime remain the source of truth for the actual local workspace runtime:

- PTYs and processes
- terminal replay/scrollback
- browser runtime
- local workspace lifecycle
- local socket/daemon state

iOS owns only client presentation state:

- selected team
- filters
- selected node/workspace
- local cache for fast launch

## Source Of Truth Boundaries

For this milestone, Rivet/Hive is authoritative for what iOS should show in the cross-machine workspace list. It is not authoritative for the actual workspace runtime.

The practical split is:

- iOS list/directory state: Rivet/Hive
- node online/offline state as seen by remote clients: Rivet/Hive leases
- local workspace existence and lifecycle: the owning Mac/`cmx` daemon
- terminal/browser processes and replay: the owning Mac/`cmx` daemon
- terminal data transport: iroh
- short-lived attach/pairing state: backend plus Rivet/Hive

Mac publishers write full snapshots and incremental updates into Rivet/Hive. If Rivet temporarily has stale data, the next node heartbeat or full snapshot repairs the directory. If a Mac disappears, the Rivet/Hive lease expires and iOS marks that node/workspace offline instead of treating the terminal runtime as available.

In the first implementation, iOS should treat workspace metadata as read-mostly discovery data. If iOS later supports editing names/descriptions/colors, those writes should become explicit metadata commands that are recorded in Rivet/Hive, delivered to the owning Mac, applied locally, and then acknowledged back into the directory state.

## Crash And Data-Loss Semantics

There are three different failure cases, and iOS should present them differently:

1. Mac app or publisher crashes, but `cmx` runtime is still alive.
   - Hive lease eventually expires if no helper is heartbeating.
   - iOS shows the node/workspaces as offline.
   - When the app/helper returns, it republishes the same node id and workspace snapshot.

2. Mac restarts and terminal processes are gone.
   - cmux should restore local workspace shells, layouts, and agent sessions from local persistence.
   - This restore behavior must exist for macOS app use, SSH remotes, and standalone Rust `cmx` TUI/tmux-style use.
   - Hive should keep the last-known workspace metadata as offline/recoverable history until the node republishes live attach metadata.
   - iOS should not offer terminal attach until the node has completed local restore and republished the restored workspace/session attach metadata.

3. Mac loses all local workspace state because of data loss or a broken local restore.
   - The first empty snapshot after a new boot must not immediately delete all known workspaces from Hive.
   - The publisher should include a node boot/session epoch and whether the local workspace restore completed.
   - Hive should only treat an empty snapshot as authoritative after the node reports a successful local restore and an explicit "replace snapshot" generation.
   - Otherwise, Hive keeps the last-known records as stale/offline so iOS can show "Unavailable on this Mac" instead of silently erasing the list.

Workspace deletion should use explicit tombstones or a confirmed full-snapshot generation, not absence from a single publisher update. This avoids a crash/reinstall bug wiping the user's iOS-visible workspace history.

Node publishing should run only while cmux is running. There should be no separate login helper whose sole purpose is to keep presence alive after the user quits cmux. If cmux is not running, the node eventually becomes offline through lease expiry.

Stale records should not be deleted by a retention timer. If a node has not been seen for a long time, iOS can filter or visually de-emphasize it, but the backend should keep the last-known records until the same `nodeID` returns and sends an authoritative restore-ready full replacement or explicit tombstones. The same cmux instance is the authority for whether its old workspace records still exist.

If the user knows a node identity is permanently gone, for example after deleting local cmux state or replacing a Mac, Settings should provide an explicit unlink action. Unlinking is an account/team management operation for a lost node, not a timeout-based cleanup. It can tombstone or archive the node's backend records after user confirmation.

iOS/macOS should also support hiding unavailable workspaces from a Mac as a client preference. Hide is reversible and does not delete backend records; it only removes those rows from the current client's default inbox/filter until the user chooses to show hidden/unavailable workspaces again. Hidden unavailable rows are device-local presentation state for this milestone, not synced account state.

## Identity And Keys

Hive state should be keyed by Stack team, not by Stack user:

```text
hive key: team:<stackTeamID>
```

Node and workspace ids must be composite because different Macs can have colliding local workspace ids:

```text
nodeID = stable id for this Mac/install
workspaceKey = <nodeID>:<localWorkspaceID>
```

`nodeID` should be an install-scoped cmux instance identity:

- generated randomly on first run
- stable across app restarts, reboots, app updates, and sign-in/sign-out
- shared by Swift app code, the local Rust `cmx` runtime, and the iroh bridge
- stored in cmux's local application data/state directory, not derived from hostname or hardware serial
- reset only when the user explicitly unlinks/resets the cmux instance or deletes cmux local state
- regenerated for cloned VM images unless the image intentionally bakes a node identity for a single-node appliance

Do not use hostname, MAC address, machine serial number, or Stack user id as `nodeID`. Hostnames change, hardware ids are sensitive, and user ids do not distinguish multiple Macs.

The preferred ownership is that the local `cmx` runtime owns or exposes the node identity, because the same identity model is needed for macOS, SSH remotes, and standalone TUI/tmux-style use. Swift publishers can read it through a local API or shared identity file.

Node records should also carry a `nodeEpoch` or `bootID` that changes when the cmux runtime starts a new live publishing session. `nodeID` answers "which cmux instance is this"; `nodeEpoch` answers "which current run of that instance published this lease/snapshot."

Node records may also carry a display-only `machineGroupID` so iOS can visually group production, nightly, staging, and dev nodes that run on the same physical Mac. `machineGroupID` must not be used as an authority key for leases, snapshots, deletes, or attach authorization. It is only a UI grouping hint.

## Node Identity Storage

The node identity is not a secret, but it must be stable and shared by Swift, Rust, and the iroh bridge for the same cmux instance. Store it as a small JSON file, not in Keychain or UserDefaults.

Suggested payload:

```json
{
  "schemaVersion": 1,
  "nodeID": "node_...",
  "scope": "stable",
  "createdAt": "2026-05-07T00:00:00Z"
}
```

macOS channel scopes:

```text
Display-only physical Mac grouping:
  ~/Library/Application Support/cmux/machine-group.json

Production app:
  ~/Library/Application Support/cmux/node-identities/stable.json

Nightly app:
  ~/Library/Application Support/cmux/node-identities/nightly.json

Staging app:
  ~/Library/Application Support/cmux/node-identities/staging.json

Tagged DEV app:
  ~/Library/Application Support/cmux/node-identities/dev/<tag-slug>.json
```

Tagged dev builds already use bundle ids like `com.cmuxterm.app.debug.<tag>` plus tag-specific sockets. The node identity should follow the same tag scope. Two tagged dev builds running side by side must not publish as the same node, because their leases and workspace snapshots would overwrite each other.

Production, nightly, staging, and tagged dev builds can all read the shared `machine-group.json` for display grouping while keeping separate `nodeID` files. If `machine-group.json` is missing, it can be generated on first run. If it is deleted, grouping may change, but authoritative node identity remains intact.

Untagged debug builds should not publish to Hive by default. If a test harness explicitly enables publishing for an untagged debug build, it should provide an explicit node identity scope or node id file.

Standalone Rust `cmx` should use a platform state directory by default:

```text
Linux:
  $XDG_STATE_HOME/cmux/node-identity.json
  or ~/.local/state/cmux/node-identity.json

macOS CLI-only fallback:
  ~/Library/Application Support/cmux/node-identities/standalone.json
```

For tests, SSH remotes, cloud VMs, and dogfood runs, support explicit overrides:

```text
CMUX_NODE_ID
CMUX_NODE_ID_FILE
CMUX_STATE_DIR
cmx server --node-id-file <path>
```

Snapshot/baked-image hygiene matters. A clonable VM image should not bake a populated node identity file unless it is meant to represent one long-lived appliance. For quick-start VM snapshots, generate the identity on first boot/run in an instance-specific writable state directory, or clear the identity before snapshotting.

Dev builds should publish to their corresponding development backend/Rivet server, not production Hive. Tagged dev builds can have stable per-tag node identities for dogfood and tests, but those records belong in the dev server selected by the build's configured API/Hive endpoint, such as the `CMUX_API_BASE_URL`/dev origin set by `reload.sh`. This avoids polluting a user's production iPhone workspace list with every local agent tag while still allowing realistic dev discovery against dev Rivet.

Every workspace record published to Hive should include:

```text
teamID
nodeID
localWorkspaceID
workspaceKey
name
description
color
active terminal/browser summary
lastActivityAt
updatedAt
attach/pairing reference
```

`lastActivityAt` is the primary sort field for iOS. It should advance when the local Mac observes meaningful workspace activity, such as terminal input/output, workspace selection, surface creation, browser navigation, metadata edits, or attach activity. If `lastActivityAt` is missing, clients should fall back to `updatedAt`, then creation time, then a stable name/id order.

## iOS Presentation Model

The default iOS home view should be a flat, cross-machine workspace inbox sorted by:

1. `lastActivityAt` descending
2. `updatedAt` descending
3. node online/offline status as a tie-breaker only
4. node display name
5. workspace display name

Each row should show enough node context to disambiguate same-named workspaces from different Macs.
Offline rows remain in recency order and render disabled/greyed out. Online/offline status should not push a recent offline workspace below older online workspaces unless the user selects an online-only filter.

Header filters should allow:

- all workspaces
- online only
- offline included
- grouped by Mac/node
- selected Mac/node

Filtering changes the visible subset or grouping, but the default product shape is "most recent workspaces across all my machines."

## Implementation Split

Rust should own runtime and transport code:

- local `cmx` daemon state and protocol
- PTY/session lifecycle
- local workspace/session snapshots needed by publishers
- activity timestamps derived from terminal/session events where practical
- iroh bridge client/server code
- HMAC/pairing proof and framed cmx transport
- no-Rivet `cmx server` mode for SSH/Linux/tmux-style use

The core Rust daemon should not depend on Stack or Rivet. If a cross-platform publisher is needed later, make it a separate node-agent process/library, not part of the no-cloud daemon core.

macOS Swift should own Mac app integration and publishing:

- Stack auth session access
- selected team setting
- shared-team opt-in
- stable Mac node id
- observing local workspace metadata changes
- building and sending Hive node/workspace snapshots
- heartbeat/lease scheduling while cmux is running
- supervising the local iroh bridge/helper process

iOS Swift should own mobile product state:

- Stack auth and callback handling
- selected team setting
- Hive discovery fetches
- local cache for fast launch
- recency sorting and header filters
- offline/disabled presentation
- workspace selection and attach flow
- rendering terminal UI through Ghostty/GhosttyKit
- calling the Rust iroh FFI for terminal transport

The web/TypeScript backend should own authenticated Hive access:

- Stack membership validation
- default personal-team resolution
- team-scoped Hive actor/store keys
- REST endpoints for teams, nodes, workspaces, pairings, and secrets
- server-side validation of publisher payloads

## Team Selection

Both macOS and iOS should use the same team-selection behavior:

1. Fetch available Stack teams through a cmux backend endpoint.
2. Resolve the default team to the personal team.
3. Store the selected team locally.
4. Include the selected team id in Hive REST calls.
5. Backend verifies membership before reading or writing team Hive state.

macOS may use its already-loaded Stack team list for the Settings picker as long as the backend still validates the selected team before publishing to Hive.

The backend should avoid trusting a raw client-provided team id without membership validation.

## URL Scheme Routing

The multi-Mac iOS path depends on auth and pairing callbacks reaching the app build the user is actually running.

Supported schemes:

```text
cmux://auth-callback
cmux-nightly://auth-callback
cmux-dev://auth-callback
```

Production should prefer `cmux://`. Nightly should prefer `cmux-nightly://`. Development builds should prefer `cmux-dev://`.

The web auth return flow should preserve an explicit native return URL when present instead of hardcoding one scheme for all app channels. If no explicit return URL is provided, it should fall back to production `cmux://`.

App-side callback parsing should accept all three schemes for shared callback handling, but app registration should remain channel-specific where possible so production, nightly, and development builds do not steal each other's auth callbacks. Development routing is allowed to be best-effort; `cmux-dev://` should be the preferred target for debug/dev builds.

## Phase 1: Team-Scoped Hive Directory

Implement team-keyed Hive discovery without changing workspace runtime ownership.

Scope:

- add or update backend team-resolution endpoint
- key Hive actor/store by `teamID`
- validate Stack team membership on Hive routes
- keep personal team as default
- add macOS selected-team setting if missing
- add iOS selected-team setting
- support `cmux://`, `cmux-nightly://`, and `cmux-dev://` auth/pairing callbacks
- keep existing user-keyed discovery behavior only as a migration fallback if needed

Exit condition:

- iOS can request Hive state for the selected team and receive nodes/workspaces across that team.

## Phase 2: Mac Node Publisher

Each signed-in Mac publishes its local workspace snapshot into the selected team Hive.

Scope:

- stable node id per Mac/install/channel/tag scope
- node display name and platform metadata
- online lease/heartbeat
- full workspace snapshot on startup/sign-in/team change
- incremental metadata updates for workspace create/rename/description/color/activity
- restore state in publisher payloads: `starting`, `restoring`, `ready`
- boot/session epoch so stale updates from an older process cannot overwrite a newer lease
- tombstone or absent-workspace handling for closed/deleted local workspaces
- periodic full repair snapshot to recover missed events
- no login helper; presence expires when cmux is not running

Presence should use leases/epochs. If a Mac crashes or loses network, Hive marks it offline after the lease expires.

Exit condition:

- two running Macs signed into the same personal team publish distinct nodes and workspace lists.
- after restart, a Mac republishes restored workspaces under the same node id with a new node epoch.

## Phase 3: iOS Multi-Node Home

Replace demo/disconnected home state with team-scoped Hive discovery.

Scope:

- fetch teams and selected/default team
- fetch nodes and nested workspaces
- render a flat recency-sorted inbox across all machines by default
- show node context on each workspace row
- offer grouped-by-Mac/node as a header filter
- grey out offline nodes/workspaces
- add header filter for online/offline and all/current-node views
- preserve local cache for fast app launch
- refresh from Hive on foreground and pull-to-refresh

Exit condition:

- iOS shows all workspaces from all online/offline Macs in the selected team, sorted by most recent activity across machines.

## Phase 4: Attach From iOS

Use Hive metadata to attach iOS to a selected workspace over iroh.

Scope:

- workspace rows expose attach/pairing reference
- iOS fetches short-lived pairing secret through Stack-authenticated backend
- iOS connects to the Mac/node iroh bridge
- iOS opens the selected workspace/session in the existing terminal detail
- offline workspace tap shows disabled/offline state instead of attempting attach

Exit condition:

- from iPhone, a user can tap a workspace from either of two Macs and reach the correct terminal session over iroh.

## Phase 5: Multi-Daemon Coverage

Add behavior-level coverage for the multi-Mac discovery contract.

Test shape:

1. Start two independent `cmx`/bridge publishers with different node ids.
2. Publish both to the same team Hive.
3. Create or rename workspaces on both nodes.
4. Verify Hive discovery returns both node records and all workspace records.
5. Verify iOS presentation model includes both nodes and greys out expired/offline nodes.
6. Verify workspace keys remain distinct when local workspace ids collide.
7. Verify an empty snapshot while restore is not ready does not delete previous workspace records.
8. Verify a confirmed full replacement after restore is ready can tombstone deleted workspaces.

Do not add source-text or project-file grep tests. Tests should exercise the runtime/backend presentation behavior.

## Implementation Notes

No product-blocking questions remain for the multi-Mac iOS discovery milestone.

Confirmed UI choices:

- Settings exposes an explicit unlink action for old/lost node records.
- Unavailable rows can be hidden from the current client without deleting backend records.
- Hidden unavailable rows are device-local presentation state in this milestone.

Attach implementation boundary:

- `attach_ticket` is node metadata, not terminal data. It points iOS at an iroh bridge and iOS still fetches the short-lived pairing secret through the Stack-authenticated Hive backend.
- The existing macOS automation socket remains newline JSON/text and is not protocol-compatible with `cmx bridge`.
- For current macOS app workspaces, the app starts a private local adapter socket that speaks the Rust native MessagePack protocol shape (`HelloNative`, `NativeSnapshot`, `NativeInput`, `PtyBytes`) and proxies terminal text/input into the Swift/Ghostty runtime. Bundled `cmx bridge` then exposes that adapter over iroh.
- `CMUX_HIVE_CMX_SOCKET_PATH` remains an escape hatch for a real Rust `cmx` native socket. `CMUX_HIVE_ATTACH_TICKET` / `CMUX_HIVE_ATTACH_TICKET_FILE` remain external ticket overrides.
- Once the macOS runtime is fully backed by the Rust daemon, the adapter can collapse into the normal app-managed Rust daemon socket.

## Later Design Notes

The broader SSH/Rust-daemon discussion is intentionally out of scope for the first multi-Mac iOS milestone, but the direction is:

- replace the Go remote daemon with the Rust `cmx` daemon
- keep `cmx server` usable with no Rivet for SSH/Linux/tmux-style mode
- introduce an `ExecutionTarget` model: local Mac, SSH host, cloud VM, enrolled node
- eventually move "remote/local" from workspace-level state to surface-level state
- allow one app/team workspace to contain terminal/browser surfaces from different nodes
- keep direct enrolled SSH nodes opt-in with scoped node credentials, not raw user Stack sessions

The important boundary for this milestone: do not redesign workspaces around mixed-host composition yet. First ship the team-scoped directory of node-owned workspaces so iOS can see and attach to all of a user's Macs.
