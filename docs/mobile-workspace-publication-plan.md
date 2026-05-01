# Mobile Workspace Publication Plan

Last updated: 2026-03-27
Owners: desktop app team, iOS app team

## Goal

Make every signed-in desktop cmux app publish:

- device presence
- live workspace catalog
- enough metadata for iPhone to group workspaces by device and attach over Tailscale

without making the iPhone scan the tailnet or scrape the desktop UI.

## Current State

The iOS app already expects two backend-facing shapes:

- [`MobileMachineRow`](/Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo/ios/Sources/Convex/ConvexMobileDogfoodModels.swift)
- [`MobileInboxWorkspaceRow`](/Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo/ios/Sources/Convex/ConvexMobileDogfoodModels.swift)

The current iOS readers are:

- [`TerminalServerDiscovery`]( /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo/ios/Sources/Terminal/TerminalServerDiscovery.swift)
  - subscribes to `mobileMachines:listForUser`
- [`ConvexWorkspaceLiveSync`]( /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo/ios/Sources/Mobile/ConvexWorkspaceLiveSync.swift)
  - subscribes to `mobileInbox:listForUser`
- [`UnifiedInboxSyncService`]( /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo/ios/Sources/Inbox/UnifiedInboxSyncService.swift)
  - merges live workspace rows into the iPhone inbox
- [`TerminalSidebarStore`]( /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo/ios/Sources/Terminal/TerminalSidebarStore.swift)
  - groups remote workspaces under device hosts

So the missing piece is not iPhone modeling. The missing piece is desktop publication.

## Where Publication Lives

Publication should live in the desktop app service layer.

It should not live in:

- `Workspace`
  - too low-level, too per-session, wrong place for account and device lifecycle
- `TabManager`
  - source of truth for UI state, not a backend sync client
- `cmuxd-remote`
  - knows terminal sessions, not enough app-level identity, titles, unread state, or account context

It should live in a new desktop sync layer owned by app startup, probably created from [`AppDelegate.swift`](/Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo/Sources/AppDelegate.swift).

## Desktop Components

### `TailscaleStatusProviding`

Responsibility:

- read local Tailscale status
- expose:
  - node ID
  - MagicDNS hostname
  - Tailscale IPs
  - connection state
  - last status refresh timestamp

This should be read-only. It should not own publishing.

Suggested file:

- `Sources/Sync/TailscaleStatusProvider.swift`

### `MobileDevicePresencePublishing`

Responsibility:

- publish the local machine as a `mobileMachines` record
- maintain heartbeat freshness
- mark offline or stale when app signs out or exits cleanly

Inputs:

- auth state
- current team scope
- Tailscale status
- app lifecycle

Suggested file:

- `Sources/Sync/MobileDevicePresencePublisher.swift`

### `WorkspaceCatalogSnapshotBuilding`

Responsibility:

- build a normalized app-level snapshot from desktop state
- convert `TabManager` workspaces into publishable workspace rows

Inputs:

- `TabManager`
- workspace titles
- selected or active surface
- unread or activity state
- Anchormux session identity
- machine metadata from `TailscaleStatusProviding`

Suggested file:

- `Sources/Sync/WorkspaceCatalogSnapshotBuilder.swift`

### `MobileWorkspaceCatalogPublishing`

Responsibility:

- publish the current desktop workspace catalog to Convex
- debounce noisy updates
- push initial full snapshot on connect
- push deltas for create, close, rename, activity, unread, session change

Inputs:

- auth state
- team scope
- `WorkspaceCatalogSnapshotBuilding`

Suggested file:

- `Sources/Sync/MobileWorkspaceCatalogPublisher.swift`

### `MobileWorkspacePublishingCoordinator`

Responsibility:

- own both publishers
- start and stop them when desktop app auth or team state changes
- avoid leaking publication into UI code

Suggested file:

- `Sources/Sync/MobileWorkspacePublishingCoordinator.swift`

## Desktop Source Of Truth

The publisher should observe state, not own it.

Canonical desktop sources:

- `TabManager`
  - workspace list
  - workspace ids
  - workspace titles
  - selected workspace
- workspace model objects
  - preview text or last visible prompt line
  - unread or activity flags
  - Anchormux session identity for the active surface
- auth service
  - current signed-in user
  - current team
- `TailscaleStatusProviding`
  - hostname and IPs

## Convex Data Model

### `mobileMachines`

One record per signed-in device per team.

Suggested fields:

```ts
{
  teamId: string,
  userId: string,
  machineId: string,
  displayName: string,
  platform: "macos",
  appVersion: string,
  tailscaleNodeId?: string,
  tailscaleHostname?: string,
  tailscaleIPs: string[],
  status: "online" | "offline" | "unknown",
  lastSeenAt: number,
  lastWorkspaceSyncAt?: number,
}
```

This matches what iOS already decodes in `MobileMachineRow`.

Recommended indexes:

- by `teamId`
- by `teamId + userId`
- unique by `teamId + machineId`

### `mobileWorkspaces`

One record per desktop workspace per device.

Suggested fields:

```ts
{
  teamId: string,
  userId: string,
  machineId: string,
  workspaceId: string,
  title: string,
  preview: string,
  phase: "live" | "catching_up" | "reconnecting" | "offline",
  tmuxSessionName: string,
  sessionId: string,
  lastActivityAt: number,
  latestEventSeq: number,
  lastReadEventSeq: number,
  unread: boolean,
  unreadCount: number,
  machineDisplayName: string,
  machineStatus: "online" | "offline" | "unknown",
  tailscaleHostname?: string,
  tailscaleIPs: string[],
  effectiveCols?: number,
  effectiveRows?: number,
  peerCount?: number,
  observerCount?: number,
}
```

This should back `mobileInbox:listForUser`.

Recommended indexes:

- by `teamId + userId + lastActivityAt`
- unique by `teamId + machineId + workspaceId`
- by `teamId + machineId`

## Queries And Mutations

Keep the existing iOS query names.

Recommended backend API:

- `mobileMachines:listForUser`
  - returns `MobileMachineRow[]`
- `mobileInbox:listForUser`
  - returns `MobileInboxWorkspaceRow[]`
- `mobileMachines:upsertPresence`
  - upserts one machine row
- `mobileInbox:publishWorkspaceSnapshot`
  - upserts all current workspaces for one machine
  - deletes stale workspace rows for that machine

The desktop app should publish snapshots, not append-only events, for the first version. Snapshot publication is simpler and matches the current iOS consumers.

## Publication Triggers

### Device presence

Publish immediately on:

- app launch
- sign in
- team switch
- Tailscale status change
- foreground

Refresh heartbeat on a timer, for example every 10 seconds while active.

### Workspace catalog

Publish immediately on:

- startup after device presence succeeds
- workspace create
- workspace close
- workspace rename
- workspace selection if preview or activity changes
- unread or activity change
- Anchormux session attach or detach
- Tailscale identity change

Debounce noisy updates, for example 250 to 500 ms, so typing does not cause a backend write per keystroke.

## New MacBook Detection Flow

When a user opens cmux on a new MacBook:

1. App starts.
2. User signs into the same cmux account.
3. `TailscaleStatusProviding` resolves current hostname and IPs.
4. `MobileDevicePresencePublishing` upserts the machine row.
5. `MobileWorkspaceCatalogPublishing` publishes the current workspace snapshot.
6. iPhone receives:
   - a new device section from `mobileMachines:listForUser`
   - its workspaces from `mobileInbox:listForUser`
7. When the user taps a workspace on iPhone, the app attaches directly to that Mac over Tailscale.

The iPhone should not discover new Macs by scanning the tailnet.

## Status Semantics

Device status and terminal sync status are different.

Device status:

- from machine heartbeat freshness
- drives section-level online or offline display

Workspace phase:

- from published session state
- drives row-level `Live`, `Catching up`, `Reconnecting`, `Offline`

Initial mapping:

- `live`
  - machine heartbeat fresh, session attachable
- `catching_up`
  - attached but rendered offset behind head offset
- `reconnecting`
  - machine heartbeat fresh, attach path failed recently
- `offline`
  - machine heartbeat stale or app not publishing

## Why Not Publish From The Daemon

The daemon alone does not know enough to own the product model.

Missing or awkward in daemon-only publication:

- user account and team scope
- human workspace titles
- unread semantics
- selected workspace context
- desktop-only UI metadata
- app lifecycle

The daemon can still be a data source for:

- session id
- peer count
- effective size
- controller vs observer attachment info

That should be fed into the desktop publisher, not replace it.

## Rollout

### Phase 1

- add desktop publishers
- publish `mobileMachines`
- publish `mobileWorkspaces`
- keep iOS readers unchanged

### Phase 2

- add better row status and per-device grouping polish
- include `peerCount`, `effectiveCols`, `effectiveRows`
- show observer vs controller in terminal details

### Phase 3

- add stronger terminal sync state from offsets
- add direct attach ticket issuance based on selected workspace

## File Placement Summary

Desktop:

- `Sources/Sync/TailscaleStatusProvider.swift`
- `Sources/Sync/MobileDevicePresencePublisher.swift`
- `Sources/Sync/WorkspaceCatalogSnapshotBuilder.swift`
- `Sources/Sync/MobileWorkspaceCatalogPublisher.swift`
- `Sources/Sync/MobileWorkspacePublishingCoordinator.swift`

Backend:

- `mobileMachines`
- `mobileWorkspaces`
- `mobileMachines:listForUser`
- `mobileMachines:upsertPresence`
- `mobileInbox:listForUser`
- `mobileInbox:publishWorkspaceSnapshot`

iOS:

- no architecture change required for the first rollout
- existing readers should continue to work:
  - `TerminalServerDiscovery`
  - `ConvexWorkspaceLiveSync`
  - `UnifiedInboxSyncService`
  - `TerminalSidebarStore`
