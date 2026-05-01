# iOS Dogfood Convex, SQLite, Tailscale Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a dogfood-ready iOS build where the main inbox shows live workspace rows, machine discovery is good enough for real use, terminal attach works over Tailscale, unread state syncs across clients, and APNS notifications route back into the correct workspace.

**Architecture:** Convex is the source of truth for machine presence, workspace summaries, unread state, and push-token registration. iOS keeps a local GRDB/SQLite cache for instant launch, offline fallback, and state restoration. Tailscale is used only for direct machine reachability and workspace attach, not as the source of truth for inbox ordering or unread state. A backend ingest route accepts authenticated machine heartbeats and workspace snapshots, writes them into new Convex tables, and triggers APNS when foreground realtime is unavailable.

**Tech Stack:** SwiftUI, ConvexMobile, GRDB, Stack Auth, Keychain, APNS, Hono, Convex, Tailscale.

**Testing Strategy:** iOS tests should use the existing `XCTest` harness, not `swift-testing`, and GRDB tests should use an in-memory database so they do not depend on simulator filesystem state. Convex module tests should run under `packages/convex/vitest.config.ts`, and Hono route tests should run under `apps/www/vitest.config.ts`. The dogfood gate is not just unit tests. It requires passing simulator tests, backend Vitest suites, `bun check` in `manaflow`, and a manual physical-device checklist covering cold launch, live updates, Tailscale attach, and APNS routing.

**Execution Status (2026-03-17):** Implementation is complete on `task-move-ios-app-into-cmux-repo` and `feat-ios-dogfood-convex`. Automated verification is green, tagged simulator installs succeed, and tagged device install succeeds when the phone stays connected. Physical-device launch still requires the phone to be unlocked, so the remaining step is the human dogfood pass, not additional implementation work.

---

## Chunk 1: Freeze The Dogfood Contract

### File Structure

**iOS repo:** `/Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo`

- Modify: `ios/project.yml`
- Modify: `ios/Sources/CMuxApp.swift`
- Modify: `ios/Sources/ContentView.swift`
- Modify: `ios/Sources/ConversationListView.swift`
- Modify: `ios/Sources/ViewModels/ConversationsViewModel.swift`
- Modify: `ios/Sources/Config/Environment.swift`
- Modify: `ios/Sources/Auth/AuthManager.swift`
- Modify: `ios/Sources/Notifications/NotificationManager.swift`
- Modify: `ios/Sources/Notifications/NotificationTokenStore.swift`
- Modify: `ios/Sources/Terminal/TerminalSidebarStore.swift`
- Modify: `ios/Sources/Terminal/TerminalServerDiscovery.swift`
- Modify: `ios/Sources/Terminal/TerminalWorkspaceIdentityService.swift`
- Modify: `ios/Sources/Terminal/TerminalWorkspaceMetadataService.swift`
- Modify: `ios/Sources/Terminal/TerminalModels.swift`
- Modify: `ios/Sources/Terminal/TerminalDaemonTicketService.swift`
- Create: `ios/Sources/Persistence/AppDatabase.swift`
- Create: `ios/Sources/Persistence/AppDatabaseMigrator.swift`
- Create: `ios/Sources/Persistence/InboxCacheRepository.swift`
- Create: `ios/Sources/Persistence/TerminalCacheRepository.swift`
- Create: `ios/Sources/Inbox/UnifiedInboxItem.swift`
- Create: `ios/Sources/Inbox/UnifiedInboxSyncService.swift`
- Create: `ios/Sources/Inbox/NotificationRouteStore.swift`
- Test: `ios/cmuxTests/AppDatabaseTests.swift`
- Test: `ios/cmuxTests/UnifiedInboxSyncServiceTests.swift`
- Test: `ios/cmuxTests/ConversationsViewModelTests.swift`
- Test: `ios/cmuxTests/TerminalServerDiscoveryTests.swift`
- Test: `ios/cmuxTests/NotificationManagerTests.swift`
- Test: `ios/cmuxTests/TerminalSidebarStoreTests.swift`

**Backend repo:** `/Users/lawrence/fun/manaflow`

- Modify: `packages/convex/convex/schema.ts`
- Modify: `packages/convex/_shared/convex-env.ts`
- Create: `packages/convex/convex/mobileMachines.ts`
- Create: `packages/convex/convex/mobileWorkspaces.ts`
- Create: `packages/convex/convex/mobileInbox.ts`
- Create: `packages/convex/convex/mobileWorkspaceEvents.ts`
- Create: `packages/convex/convex/pushTokens.ts`
- Create: `packages/convex/convex/pushNotificationsActions.ts`
- Modify: `apps/www/lib/routes/index.ts`
- Modify: `apps/www/lib/hono-app.ts`
- Create: `apps/www/lib/routes/mobile-machine-session.route.ts`
- Create: `apps/www/lib/routes/mobile-heartbeat.route.ts`
- Create: `apps/www/lib/routes/mobile-push.route.ts`
- Test: `packages/convex/convex/mobileInbox.test.ts`
- Test: `apps/www/lib/routes/mobile-machine-session.route.test.ts`
- Test: `apps/www/lib/routes/mobile-heartbeat.route.test.ts`

### Task 1: Write The Dogfood Contract Down In Code

**Files:**
- Modify: `ios/Sources/Config/Environment.swift`
- Modify: `packages/convex/convex/schema.ts`
- Modify: `packages/convex/_shared/convex-env.ts`
- Test: `ios/cmuxTests/AppDatabaseTests.swift`

- [ ] **Step 1: Add a failing schema/caching test**

Add tests that expect these persisted concepts to exist:

```swift
func testUnreadStateRoundTripsThroughDatabase() throws {
    let db = try AppDatabase.inMemory()
    try db.writeWorkspace(
        id: "ws_123",
        title: "orb / cmux",
        latestEventSeq: 4,
        lastReadEventSeq: 2
    )
    let row = try db.readWorkspace(id: "ws_123")
    XCTAssertEqual(row?.isUnread, true)
}
```

```ts
// backend expectation
// mobileMachines, mobileWorkspaces, mobileWorkspaceEvents,
// mobileUserWorkspaceState, devicePushTokens all exist in schema
```

- [ ] **Step 2: Run the iOS database test and backend typecheck**

Run:

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo/ios && xcodebuild test -project cmux.xcodeproj -scheme cmux -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:cmuxTests/AppDatabaseTests
cd /Users/lawrence/fun/manaflow/packages/convex && bunx tsc --noEmit
```

Expected: FAIL because the GRDB layer and the new Convex tables do not exist yet.

- [ ] **Step 3: Add the shared contract**

Use these table shapes:

```ts
mobileMachines: {
  teamId, userId, machineId, displayName, tailscaleHostname,
  tailscaleIPs, status, lastSeenAt, lastWorkspaceSyncAt
}

mobileWorkspaces: {
  teamId, userId, workspaceId, machineId, taskId?, taskRunId?,
  title, preview, phase, tmuxSessionName, lastActivityAt,
  latestEventSeq, lastEventAt
}

mobileWorkspaceEvents: {
  teamId, userId, workspaceId, eventSeq, kind, preview,
  createdAt, shouldNotify
}

mobileUserWorkspaceState: {
  teamId, userId, workspaceId, lastReadEventSeq, pinned, archived, updatedAt
}

devicePushTokens: {
  teamId, userId, token, environment, platform, bundleId, deviceId, updatedAt
}
```

Add env validation for:

```ts
APNS_TEAM_ID
APNS_KEY_ID
APNS_PRIVATE_KEY_BASE64
MOBILE_MACHINE_JWT_SECRET
```

- [ ] **Step 4: Re-run the tests**

Run the same `xcodebuild` and `bunx tsc --noEmit` commands.

Expected: PASS or progress to the next missing symbol only inside GRDB implementation work.

- [ ] **Step 5: Commit**

```bash
cd /Users/lawrence/fun/manaflow
git add packages/convex/convex/schema.ts packages/convex/_shared/convex-env.ts
git commit -m "convex: add mobile dogfood workspace schema"
```

## Chunk 2: Add The Local SQLite Cache

### Task 2: Replace JSON-Only Snapshot Storage With GRDB

**Files:**
- Modify: `ios/project.yml`
- Modify: `ios/Sources/CMuxApp.swift`
- Modify: `ios/Sources/Terminal/TerminalModels.swift`
- Create: `ios/Sources/Persistence/AppDatabase.swift`
- Create: `ios/Sources/Persistence/AppDatabaseMigrator.swift`
- Create: `ios/Sources/Persistence/InboxCacheRepository.swift`
- Create: `ios/Sources/Persistence/TerminalCacheRepository.swift`
- Test: `ios/cmuxTests/AppDatabaseTests.swift`

- [ ] **Step 1: Write the failing migration test**

```swift
func testImportsLegacyTerminalSnapshot() throws {
    let legacy = TerminalSnapshot(...)
    let store = InMemoryTerminalSnapshotStore(snapshot: legacy)
    let db = try AppDatabase.inMemory()
    try AppDatabaseMigrator.importLegacySnapshotIfNeeded(from: store, into: db)
    XCTAssertEqual(try db.fetchHostCount(), legacy.hosts.count)
}
```

- [ ] **Step 2: Run the focused test**

Run:

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo/ios && xcodebuild test -project cmux.xcodeproj -scheme cmux -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:cmuxTests/AppDatabaseTests
```

Expected: FAIL because `AppDatabase` and the migrator do not exist.

- [ ] **Step 3: Add GRDB and the database layer**

Use tables:

```swift
hosts
workspaces
inbox_items
workspace_user_state
machine_presence
app_metadata
```

Keep Keychain for SSH credentials and notification device token secrets. Store only durable UI state and cache rows in SQLite.
Use an in-memory GRDB database for unit tests and a dedicated app-support database path for app runtime.

- [ ] **Step 4: Boot the app through SQLite**

At app start:
- open the DB
- run migrations
- import `terminal-store.json` once
- hand repositories into `ConversationsViewModel` and `TerminalSidebarStore`

- [ ] **Step 5: Re-run the focused test**

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo
git add ios/project.yml ios/Sources/CMuxApp.swift ios/Sources/Terminal/TerminalModels.swift ios/Sources/Persistence ios/cmuxTests/AppDatabaseTests.swift
git commit -m "ios: add grdb workspace cache"
```

### Task 3: Add A Unified Inbox Read Model On Top Of SQLite

**Files:**
- Create: `ios/Sources/Inbox/UnifiedInboxItem.swift`
- Create: `ios/Sources/Inbox/UnifiedInboxSyncService.swift`
- Modify: `ios/Sources/ViewModels/ConversationsViewModel.swift`
- Modify: `ios/Sources/ConversationListView.swift`
- Test: `ios/cmuxTests/UnifiedInboxSyncServiceTests.swift`
- Test: `ios/cmuxTests/ConversationsViewModelTests.swift`

- [ ] **Step 1: Write the failing inbox merge test**

```swift
func testMergesConversationAndWorkspaceRows() throws {
    let items = UnifiedInboxSyncService.merge(
        conversations: [.fixture(updatedAt: 10)],
        workspaces: [.fixture(lastActivityAt: 20)]
    )
    XCTAssertEqual(items.first?.kind, .workspace)
}
```

- [ ] **Step 2: Run the focused test**

Run:

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo/ios && xcodebuild test -project cmux.xcodeproj -scheme cmux -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:cmuxTests/UnifiedInboxSyncServiceTests -only-testing:cmuxTests/ConversationsViewModelTests
```

Expected: FAIL because the unified inbox layer does not exist.

- [ ] **Step 3: Normalize the inbox shape**

Use one enum-backed model:

```swift
enum UnifiedInboxKind { case conversation, workspace }

struct UnifiedInboxItem: Identifiable {
    let id: String
    let kind: UnifiedInboxKind
    let title: String
    let preview: String
    let unreadCount: Int
    let sortDate: Date
}
```

Do not make `ConversationListView` understand raw Convex conversation pages anymore. Make it render `UnifiedInboxItem` rows from the view model.

- [ ] **Step 4: Re-run the focused tests**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo
git add ios/Sources/Inbox ios/Sources/ViewModels/ConversationsViewModel.swift ios/Sources/ConversationListView.swift ios/cmuxTests/UnifiedInboxSyncServiceTests.swift ios/cmuxTests/ConversationsViewModelTests.swift
git commit -m "ios: add unified inbox read model"
```

## Chunk 3: Make Convex The Source Of Truth

### Task 4: Add Mobile Machine And Workspace Modules

**Files:**
- Create: `/Users/lawrence/fun/manaflow/packages/convex/convex/mobileMachines.ts`
- Create: `/Users/lawrence/fun/manaflow/packages/convex/convex/mobileWorkspaces.ts`
- Create: `/Users/lawrence/fun/manaflow/packages/convex/convex/mobileWorkspaceEvents.ts`
- Test: `/Users/lawrence/fun/manaflow/packages/convex/convex/mobileInbox.test.ts`

- [ ] **Step 1: Write the failing Convex query test**

```ts
it("returns unread workspace rows ordered by latest workspace activity", async () => {
  // seed machine, workspace, event, and user state
  // expect listForUser to return unread workspace row first
})
```

- [ ] **Step 2: Run the test**

Run:

```bash
cd /Users/lawrence/fun/manaflow/packages/convex && bunx vitest run convex/mobileInbox.test.ts
```

Expected: FAIL because the modules and query do not exist.

- [ ] **Step 3: Implement machine/workspace CRUD**

Required public/authenticated queries:
- `mobileMachines:listForUser`
- `mobileWorkspaces:listForUser`
- `mobileInbox:listForUser`
- `mobileWorkspaces:markRead`
- `mobileWorkspaces:markUnread`

Required internal mutations:
- `mobileMachines:upsertHeartbeatInternal`
- `mobileWorkspaces:replaceMachineWorkspaceSnapshotInternal`
- `mobileWorkspaceEvents:appendInternal`

Unread should be computed from `latestEventSeq > lastReadEventSeq`, not from a boolean field.

- [ ] **Step 4: Run the test and repo typecheck**

Run:

```bash
cd /Users/lawrence/fun/manaflow/packages/convex && bunx vitest run convex/mobileInbox.test.ts && bunx tsc --noEmit
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/lawrence/fun/manaflow
git add packages/convex/convex/mobileMachines.ts packages/convex/convex/mobileWorkspaces.ts packages/convex/convex/mobileWorkspaceEvents.ts packages/convex/convex/mobileInbox.ts packages/convex/convex/schema.ts
git commit -m "convex: add mobile machine and workspace state"
```

### Task 5: Add Push Token And APNS Delivery For Workspace Events

**Files:**
- Create: `/Users/lawrence/fun/manaflow/packages/convex/convex/pushTokens.ts`
- Create: `/Users/lawrence/fun/manaflow/packages/convex/convex/pushNotificationsActions.ts`
- Modify: `/Users/lawrence/fun/manaflow/packages/convex/convex/mobileWorkspaceEvents.ts`
- Test: `/Users/lawrence/fun/manaflow/packages/convex/convex/mobileInbox.test.ts`

- [ ] **Step 1: Write the failing push token test**

```ts
it("upserts one device token per bundle and environment", async () => {
  // upsert same token twice
  // expect one row
})
```

- [ ] **Step 2: Run the focused backend test**

Run:

```bash
cd /Users/lawrence/fun/manaflow/packages/convex && bunx vitest run convex/mobileInbox.test.ts
```

Expected: FAIL because push-token mutations do not exist.

- [ ] **Step 3: Add token registration and notification dispatch**

Required mutations/actions:
- `pushTokens:upsert`
- `pushTokens:remove`
- `pushTokens:sendTest`
- `pushNotificationsActions:sendWorkspaceEvent`

Trigger APNS only when:
- the event is marked `shouldNotify`
- the workspace is unread for that user
- the event was not created by the same active device session

- [ ] **Step 4: Run the focused test and typecheck**

Run:

```bash
cd /Users/lawrence/fun/manaflow/packages/convex && bunx vitest run convex/mobileInbox.test.ts && bunx tsc --noEmit
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/lawrence/fun/manaflow
git add packages/convex/convex/pushTokens.ts packages/convex/convex/pushNotificationsActions.ts packages/convex/convex/mobileWorkspaceEvents.ts packages/convex/_shared/convex-env.ts packages/convex/convex/schema.ts
git commit -m "convex: add mobile push token and apns delivery"
```

## Chunk 4: Add Backend Ingest For Tailscale-Visible Machines

### Task 6: Add Machine Session Minting And Heartbeat Routes

**Files:**
- Create: `/Users/lawrence/fun/manaflow/apps/www/lib/routes/mobile-machine-session.route.ts`
- Create: `/Users/lawrence/fun/manaflow/apps/www/lib/routes/mobile-heartbeat.route.ts`
- Modify: `/Users/lawrence/fun/manaflow/apps/www/lib/routes/index.ts`
- Modify: `/Users/lawrence/fun/manaflow/apps/www/lib/hono-app.ts`
- Test: `/Users/lawrence/fun/manaflow/apps/www/lib/routes/mobile-machine-session.route.test.ts`
- Test: `/Users/lawrence/fun/manaflow/apps/www/lib/routes/mobile-heartbeat.route.test.ts`

- [ ] **Step 1: Write the failing route tests**

```ts
it("mints a machine session for an authenticated user", async () => {
  const response = await app.request("/api/mobile/machine-session", { method: "POST" })
  expect(response.status).toBe(200)
})

it("accepts a workspace heartbeat snapshot", async () => {
  const response = await app.request("/api/mobile/heartbeat", { method: "POST", body: JSON.stringify({...}) })
  expect(response.status).toBe(202)
})
```

- [ ] **Step 2: Run the route tests**

Run:

```bash
cd /Users/lawrence/fun/manaflow/apps/www && bunx vitest run lib/routes/mobile-machine-session.route.test.ts lib/routes/mobile-heartbeat.route.test.ts
```

Expected: FAIL because the routes do not exist.

- [ ] **Step 3: Implement the route pair**

`POST /api/mobile/machine-session`
- requires authenticated Stack session
- returns a short-lived JWT signed with `MOBILE_MACHINE_JWT_SECRET`
- payload includes `teamId`, `userId`, `machineId`

`POST /api/mobile/heartbeat`
- accepts machine identity, Tailscale host/IPs, and workspace snapshot list
- verifies the machine JWT
- writes through internal Convex mutations

- [ ] **Step 4: Run the route tests**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/lawrence/fun/manaflow
git add apps/www/lib/routes/mobile-machine-session.route.ts apps/www/lib/routes/mobile-heartbeat.route.ts apps/www/lib/routes/index.ts apps/www/lib/hono-app.ts apps/www/lib/routes/mobile-machine-session.route.test.ts apps/www/lib/routes/mobile-heartbeat.route.test.ts
git commit -m "www: add mobile machine session and heartbeat routes"
```

### Task 7: Keep Tailscale Discovery Backward Compatible During Dogfood

**Files:**
- Modify: `ios/Sources/Terminal/TerminalServerDiscovery.swift`
- Modify: `ios/Sources/Terminal/TerminalWorkspaceIdentityService.swift`
- Modify: `ios/Sources/Terminal/TerminalWorkspaceMetadataService.swift`
- Test: `ios/cmuxTests/TerminalServerDiscoveryTests.swift`

- [ ] **Step 1: Write the failing fallback test**

```swift
func testDiscoveryFallsBackToLegacyServerMetadata() {
    // seed zero machine rows + one team metadata host
    // expect one discovered host
}
```

- [ ] **Step 2: Run the focused test**

Run:

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo/ios && xcodebuild test -project cmux.xcodeproj -scheme cmux -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:cmuxTests/TerminalServerDiscoveryTests
```

Expected: FAIL because discovery only knows the legacy metadata path.

- [ ] **Step 3: Implement dual-source discovery**

Primary path:
- subscribe to `mobileMachines:listForUser`
- map each active machine row into a `TerminalHost`

Fallback path:
- keep parsing `teams:listTeamMemberships` `serverMetadata` until all dogfood machines publish heartbeats

Do not break current `localWorkspaces:reserve` or `tasks:getLinkedLocalWorkspace` calls yet. Keep them as compatibility shims until direct workspace rows are stable.

- [ ] **Step 4: Run the focused test**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo
git add ios/Sources/Terminal/TerminalServerDiscovery.swift ios/Sources/Terminal/TerminalWorkspaceIdentityService.swift ios/Sources/Terminal/TerminalWorkspaceMetadataService.swift ios/cmuxTests/TerminalServerDiscoveryTests.swift
git commit -m "ios: add convex-backed machine discovery with fallback"
```

### Task 7A: Prefer Live Machine Rows Over Placeholder Server Pins

**Files:**
- Modify: `ios/Sources/Terminal/TerminalServerCatalog.swift`
- Modify: `ios/Sources/Terminal/TerminalServerDiscovery.swift`
- Modify: `ios/Sources/Convex/ConvexMobileDogfoodModels.swift`
- Modify: `ios/Sources/Terminal/TerminalSidebarStore.swift`
- Modify: `ios/Sources/Terminal/TerminalSidebarRootView.swift`
- Modify: `ios/Sources/Config/UITestConfig.swift`
- Modify: `ios/Sources/ContentView.swift`
- Test: `ios/cmuxTests/TerminalServerCatalogTests.swift`
- Test: `ios/cmuxTests/TerminalServerDiscoveryTests.swift`
- Test: `ios/cmuxTests/TerminalSidebarStoreTests.swift`
- Test: `ios/cmuxUITests/TerminalHomeUITests.swift`

- [ ] **Step 1: Write the failing shadowing tests**

Add tests that prove:

```swift
func testMergeReplacesPlaceholderCustomHostWithLiveMachine() {
    // placeholder "Mac mini" host with empty hostname/user
    // live machine row with a different machineId but the same tailscale hostname
    // expect one discovered host and no setup placeholder
}
```

```swift
func testDiscoveredFixtureOpensWorkspaceInsteadOfHostEditor() {
    // launch terminal home with a placeholder + live machine fixture
    // tap the machine pin
    // expect workspace detail, not terminal.hostEditor
}
```

- [ ] **Step 2: Run the focused tests**

Run:

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo/ios && xcodebuild test -project cmux.xcodeproj -scheme cmux -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:cmuxTests/TerminalServerCatalogTests -only-testing:cmuxTests/TerminalServerDiscoveryTests -only-testing:cmuxTests/TerminalSidebarStoreTests -only-testing:cmuxUITests/TerminalHomeUITests
```

Expected: FAIL because placeholder pins still survive discovery merge and the terminal home still routes some taps into the editor sheet.

- [ ] **Step 3: Implement placeholder shadowing and tap routing**

Make these rules explicit:
- live machine rows win over legacy metadata rows when hostname or server identity matches
- live machine rows also win over unconfigured custom placeholder hosts with the same display name
- discovered server pins never open the config sheet on tap
- only custom/manual hosts can enter the editor flow
- discovered machine rows should prefer the Tailscale hostname as their `serverID` so daemon ticket lookup and legacy dedupe converge on the same identifier

- [ ] **Step 4: Re-run the focused tests**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo
git add ios/Sources/Terminal/TerminalServerCatalog.swift ios/Sources/Terminal/TerminalServerDiscovery.swift ios/Sources/Convex/ConvexMobileDogfoodModels.swift ios/Sources/Terminal/TerminalSidebarStore.swift ios/Sources/Terminal/TerminalSidebarRootView.swift ios/Sources/Config/UITestConfig.swift ios/Sources/ContentView.swift ios/cmuxTests/TerminalServerCatalogTests.swift ios/cmuxTests/TerminalServerDiscoveryTests.swift ios/cmuxTests/TerminalSidebarStoreTests.swift ios/cmuxUITests/TerminalHomeUITests.swift
git commit -m "ios: prefer live machines over setup placeholders"
```

## Chunk 5: Wire The iOS App To Live Convex State

### Task 8: Subscribe To The Unified Inbox And Persist It Locally

**Files:**
- Create: `ios/Sources/Inbox/UnifiedInboxSyncService.swift`
- Modify: `ios/Sources/ViewModels/ConversationsViewModel.swift`
- Modify: `ios/Sources/ConversationListView.swift`
- Test: `ios/cmuxTests/UnifiedInboxSyncServiceTests.swift`
- Test: `ios/cmuxTests/ConversationsViewModelTests.swift`

- [ ] **Step 1: Write the failing live update test**

```swift
func testWorkspaceUpdateRewritesCachedRow() async throws {
    // subscribe, receive updated workspace preview, assert DB and published rows update
}
```

- [ ] **Step 2: Run the focused tests**

Run the same `xcodebuild` command used in Task 3.

Expected: FAIL because the sync service is not subscribed to Convex yet.

- [ ] **Step 3: Implement the sync loop**

`UnifiedInboxSyncService` should:
- subscribe to `mobileInbox:listForUser`
- translate rows into `UnifiedInboxItem`
- upsert them into GRDB
- publish cached rows immediately on launch, then overlay live Convex changes

`ConversationsViewModel` should stop owning Convex pagination details directly for the dogfood list page.

- [ ] **Step 4: Re-run the focused tests**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo
git add ios/Sources/Inbox/UnifiedInboxSyncService.swift ios/Sources/ViewModels/ConversationsViewModel.swift ios/Sources/ConversationListView.swift ios/cmuxTests/UnifiedInboxSyncServiceTests.swift ios/cmuxTests/ConversationsViewModelTests.swift
git commit -m "ios: sync unified inbox from convex"
```

### Task 9: Route Workspace Taps Into The Terminal Stack

**Files:**
- Modify: `ios/Sources/ContentView.swift`
- Modify: `ios/Sources/Terminal/TerminalSidebarStore.swift`
- Modify: `ios/Sources/Terminal/TerminalDaemonTicketService.swift`
- Test: `ios/cmuxTests/TerminalSidebarStoreTests.swift`

- [ ] **Step 1: Write the failing open-workspace test**

```swift
func testOpensWorkspaceFromInbox() async throws {
    // tap workspace row, assert markRead + selectedWorkspaceID
}
```

- [ ] **Step 2: Run the focused test**

Run:

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo/ios && xcodebuild test -project cmux.xcodeproj -scheme cmux -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:cmuxTests/TerminalSidebarStoreTests
```

Expected: FAIL because inbox rows are not yet linked to terminal workspace selection.

- [ ] **Step 3: Implement attach and read-side effects**

When a workspace row is opened:
- mark the Convex row read using `latestEventSeq`
- persist the new `lastReadEventSeq` in SQLite
- open or create the matching `TerminalWorkspace`
- fetch a daemon ticket using `apiBaseURL`
- connect over the machine’s Tailscale hostname or IP

- [ ] **Step 4: Re-run the focused test**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo
git add ios/Sources/ContentView.swift ios/Sources/Terminal/TerminalSidebarStore.swift ios/Sources/Terminal/TerminalDaemonTicketService.swift ios/cmuxTests/TerminalSidebarStoreTests.swift
git commit -m "ios: open convex workspaces in terminal sidebar"
```

## Chunk 6: Make Notifications Useful

### Task 10: Rewire APNS Registration To The New Convex Token Contract

**Files:**
- Modify: `ios/Sources/Notifications/NotificationManager.swift`
- Modify: `ios/Sources/Notifications/NotificationTokenStore.swift`
- Test: `ios/cmuxTests/NotificationManagerTests.swift`

- [ ] **Step 1: Write the failing token sync test**

```swift
func testSyncsDeviceTokenToConvex() async throws {
    // fake device token, authenticated session, expect pushTokens:upsert
}
```

- [ ] **Step 2: Run the focused test**

Run:

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo/ios && xcodebuild test -project cmux.xcodeproj -scheme cmux -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:cmuxTests/NotificationManagerTests
```

Expected: FAIL against the new contract until the manager is updated.

- [ ] **Step 3: Update `NotificationManager`**

Use the new `pushTokens` mutations only. Do not keep notification identity in `UserDefaults` beyond the raw device token cache.

- [ ] **Step 4: Re-run the focused test**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo
git add ios/Sources/Notifications/NotificationManager.swift ios/Sources/Notifications/NotificationTokenStore.swift ios/cmuxTests/NotificationManagerTests.swift
git commit -m "ios: sync push tokens to convex"
```

### Task 11: Deep Link APNS Notifications Back Into The Correct Workspace

**Files:**
- Create: `ios/Sources/Inbox/NotificationRouteStore.swift`
- Modify: `ios/Sources/CMuxApp.swift`
- Modify: `ios/Sources/ContentView.swift`
- Test: `ios/cmuxTests/NotificationManagerTests.swift`

- [ ] **Step 1: Write the failing route test**

```swift
func testNotificationRouteSelectsWorkspace() throws {
    // seed route payload, launch content tree, assert selected workspace/inbox item
}
```

- [ ] **Step 2: Run the focused test**

Run the same `NotificationManagerTests` command.

Expected: FAIL because there is no route handoff object.

- [ ] **Step 3: Implement the route store**

Route payload should include:

```json
{
  "kind": "workspace",
  "workspaceId": "ws_123",
  "machineId": "machine_123"
}
```

`CMuxApp` receives the push response and stores it. `ContentView` consumes it and selects the matching inbox item or terminal workspace.

- [ ] **Step 4: Re-run the focused test**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo
git add ios/Sources/Inbox/NotificationRouteStore.swift ios/Sources/CMuxApp.swift ios/Sources/ContentView.swift ios/cmuxTests/NotificationManagerTests.swift
git commit -m "ios: route workspace notifications into app state"
```

## Chunk 7: Get It Ready To Dogfood

### Task 12: Add A Manual Dogfood Checklist And Run It

**Files:**
- Test: `ios/cmuxTests/ConversationsViewModelTests.swift`
- Test: `ios/cmuxTests/TerminalServerDiscoveryTests.swift`
- Test: `ios/cmuxTests/NotificationManagerTests.swift`

- [ ] **Step 1: Verify local automated checks**

Run:

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo/ios && xcodebuild test -project cmux.xcodeproj -scheme cmux -destination 'platform=iOS Simulator,name=iPhone 16'
cd /Users/lawrence/fun/manaflow && bun check
cd /Users/lawrence/fun/manaflow/packages/convex && bunx tsc --noEmit
cd /Users/lawrence/fun/manaflow/packages/convex && bunx vitest run convex/mobileInbox.test.ts
cd /Users/lawrence/fun/manaflow/apps/www && bunx vitest run lib/routes/mobile-machine-session.route.test.ts lib/routes/mobile-heartbeat.route.test.ts
```

Expected: PASS.

- [ ] **Step 2: Verify the dogfood flow manually**

Checklist:
- install on both simulator and physical iPhone
- sign out and sign back in to verify cold auth/bootstrap path
- sign in on iPhone with production auth
- cold launch shows cached inbox within 1 second
- live workspace row appears when a machine heartbeat arrives
- unread dot increments when a workspace event is inserted
- opening the workspace clears unread locally and in Convex
- machine offline transitions within heartbeat timeout
- terminal attach succeeds over Tailscale
- APNS notification arrives when app is backgrounded
- tapping the notification opens the exact workspace
- kill and relaunch the app, then confirm cached inbox and unread state restore from SQLite before the first live Convex update
- disconnect network briefly, confirm cached inbox stays visible, then reconnect and confirm live rows converge without duplicates

- [ ] **Step 3: Record blockers before rollout**

If any of the above fails, stop and fix before broadening dogfood.

- [ ] **Step 4: Commit any final dogfood-only fixes**

```bash
git add <files>
git commit -m "ios: finish dogfood workspace sync rollout"
```

## Notes

- This plan supersedes `2026-03-16-ios-rivetkit-notifications-workspace-sync.md`. Do not start new Rivet actor work for the iOS inbox unless the product decision changes again.
- Keep existing `localWorkspaces:reserve` and `tasks:getLinkedLocalWorkspace` alive during dogfood. Remove those only after the new Convex workspace tables have proved stable.
- Do not let the iOS app talk to Tailscale for inbox truth. Use Tailscale only for machine attach and last-mile terminal transport.
- If Convex module tests need a dedicated helper, add one under `packages/convex/convex/testHelpers/` rather than mocking Convex internals ad hoc in each test file.
