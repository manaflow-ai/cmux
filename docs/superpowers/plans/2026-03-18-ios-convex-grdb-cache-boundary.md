# Convex Mobile Workspace Boundary With GRDB Cache Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the mobile workspace experience on top of Convex now, while keeping the iOS GRDB cache as a first-class local store and introducing a strict backend contract so we can migrate off Convex later without rewriting the iOS terminal and inbox layers again.

**Architecture:** Convex remains the operational source of truth for machine presence, workspace summaries, unread state, push-token registration, and direct-daemon metadata. iOS must boot and render from GRDB first, then reconcile with live Convex subscriptions and authenticated backend routes. The mobile boundary is defined by shared contract types and service protocols, not raw Convex function names scattered through Swift. PostHog is the analytics sink only. There is no second operational database on the hot path.

**Tech Stack:** SwiftUI, GRDB, ConvexMobile, Stack Auth, Hono, Convex, PostHog, Tailscale, Keychain, XCTest, Vitest.

**Testing Strategy:** iOS tests stay in `XCTest` and use in-memory GRDB. Convex modules are tested with Vitest under `packages/convex`. Hono routes are tested under `apps/www`. Mac app tests remain focused unit tests for heartbeat publishing and machine-session flows. The dogfood gate requires green unit tests on iOS and macOS, green Vitest in `manaflow`, a tagged simulator build, a tagged macOS build, and a manual physical-device checklist for cache-first launch, live updates, and direct terminal attach.

**Scope Guard:** This plan keeps Convex for mobile workspace state on purpose. It does not add Rivet, does not add Postgres, and does not migrate ACP conversations off Convex. The point is to stabilize the current backend choice and make it reversible later.

---

## Chunk 1: Freeze The Contract And The Cache-First Rule

### File Structure

**iOS repo:** `/Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo`

- Modify: `ios/Sources/Config/Environment.swift`
- Modify: `ios/Sources/Persistence/AppDatabase.swift`
- Modify: `ios/Sources/Persistence/AppDatabaseMigrator.swift`
- Modify: `ios/Sources/Persistence/InboxCacheRepository.swift`
- Modify: `ios/Sources/Persistence/TerminalCacheRepository.swift`
- Modify: `ios/Sources/Inbox/UnifiedInboxSyncService.swift`
- Modify: `ios/Sources/Inbox/UnifiedInboxItem.swift`
- Modify: `ios/Sources/ViewModels/ConversationsViewModel.swift`
- Modify: `ios/Sources/Terminal/TerminalSidebarStore.swift`
- Modify: `ios/Sources/Notifications/NotificationManager.swift`
- Create: `ios/Sources/Mobile/MobileContractModels.swift`
- Create: `ios/Sources/Mobile/ConvexWorkspaceLiveSync.swift`
- Create: `ios/Sources/Mobile/MobileAnalyticsClient.swift`
- Test: `ios/cmuxTests/AppDatabaseTests.swift`
- Test: `ios/cmuxTests/UnifiedInboxSyncServiceTests.swift`
- Test: `ios/cmuxTests/ConversationsViewModelTests.swift`
- Test: `ios/cmuxTests/TerminalSidebarStoreTests.swift`
- Test: `ios/cmuxTests/NotificationManagerTests.swift`

**Backend repo:** `/Users/lawrence/.config/superpowers/worktrees/manaflow/feat-ios-dogfood-convex`

- Create: `packages/shared/src/mobile-contracts.ts`
- Create: `packages/shared/src/mobile-analytics.ts`
- Modify: `packages/shared/src/index.ts`
- Modify: `packages/convex/convex/schema.ts`
- Modify: `packages/convex/convex/mobileMachines.ts`
- Modify: `packages/convex/convex/mobileWorkspaces.ts`
- Modify: `packages/convex/convex/mobileInbox.ts`
- Modify: `packages/convex/convex/mobileWorkspaceEvents.ts`
- Modify: `packages/convex/convex/pushTokens.ts`
- Modify: `packages/convex/convex/mobileMachineConnections.ts`
- Modify: `apps/www/lib/routes/mobile-machine-session.route.ts`
- Modify: `apps/www/lib/routes/mobile-heartbeat.route.ts`
- Modify: `apps/www/lib/routes/daemon-ticket.route.ts`
- Create: `apps/www/lib/routes/mobile-push.route.ts`
- Create: `apps/www/lib/routes/mobile-mark-read.route.ts`
- Create: `apps/www/lib/routes/mobile-analytics.route.ts`
- Create: `apps/www/lib/analytics/track-mobile-event.ts`
- Modify: `apps/www/lib/routes/index.ts`
- Test: `packages/convex/convex/mobileInbox.test.ts`
- Test: `apps/www/lib/routes/mobile-machine-session.route.test.ts`
- Test: `apps/www/lib/routes/mobile-heartbeat.route.test.ts`
- Test: `apps/www/lib/routes/daemon-ticket.route.test.ts`
- Test: `apps/www/lib/routes/mobile-push.route.test.ts`
- Test: `apps/www/lib/routes/mobile-mark-read.route.test.ts`
- Test: `apps/www/lib/routes/mobile-analytics.route.test.ts`

**macOS cmux repo:** `/Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in`

- Modify: `Sources/MobilePresence/MachineSessionClient.swift`
- Modify: `Sources/MobilePresence/MobileHeartbeatPublisher.swift`
- Test: `cmuxTests/MachineSessionClientTests.swift`
- Test: `cmuxTests/MobileHeartbeatPublisherTests.swift`

### Task 1: Lock The Cache-First Behavior In Tests

**Files:**
- Modify: `ios/cmuxTests/AppDatabaseTests.swift`
- Modify: `ios/cmuxTests/UnifiedInboxSyncServiceTests.swift`
- Modify: `ios/cmuxTests/ConversationsViewModelTests.swift`
- Modify: `ios/cmuxTests/TerminalSidebarStoreTests.swift`

- [ ] **Step 1: Write the failing GRDB cold-launch test**

Add a test that proves the app can render terminal and workspace state before any network call:

```swift
func testUnifiedInboxBootsFromCacheBeforeLiveSync() throws {
    let db = try AppDatabase.inMemory()
    try db.writeWorkspaceInboxRow(
        workspaceID: "ws_123",
        machineID: "machine_123",
        teamID: "team_123",
        title: "cmux",
        preview: "running tests",
        tmuxSessionName: "cmux-1",
        lastActivityAt: Date(timeIntervalSince1970: 100),
        latestEventSeq: 4,
        lastReadEventSeq: 2
    )

    let repository = InboxCacheRepository(database: db)
    let service = UnifiedInboxSyncService(
        inboxCacheRepository: repository,
        workspaceLiveSync: NeverConnectingWorkspaceLiveSync()
    )

    XCTAssertEqual(service.workspaceItemsPublisher.currentValue.first?.workspaceID, "ws_123")
    XCTAssertEqual(service.workspaceItemsPublisher.currentValue.first?.unreadCount, 2)
}
```

- [ ] **Step 2: Write the failing stale-cache reconciliation test**

```swift
func testLiveWorkspaceSnapshotReconcilesIntoExistingCache() throws {
    let db = try AppDatabase.inMemory()
    let repository = InboxCacheRepository(database: db)
    let liveSync = StubWorkspaceLiveSync(rows: [[
        MobileWorkspaceInboxRow.fixture(
            workspaceID: "ws_123",
            latestEventSeq: 5,
            lastReadEventSeq: 3
        )
    ]])

    let service = UnifiedInboxSyncService(
        inboxCacheRepository: repository,
        workspaceLiveSync: liveSync
    )

    service.connect(teamID: "team_123")

    XCTAssertEqual(try repository.load().first?.unreadCount, 2)
}
```

- [ ] **Step 3: Write the failing terminal-open-from-cache test**

```swift
func testTerminalSidebarCanOpenCachedRemoteWorkspaceWithoutNetwork() {
    let snapshot = TerminalStoreSnapshot.fixtureRemoteWorkspace(
        workspaceID: "ws_123",
        machineID: "machine_123",
        tmuxSessionName: "cmux-1"
    )
    let store = TerminalSidebarStore(
        snapshotStore: InMemoryTerminalSnapshotStore(snapshot: snapshot),
        workspaceIdentityService: nil,
        workspaceMetadataService: nil,
        serverDiscovery: nil,
        eagerlyRestoreSessions: false
    )

    XCTAssertNotNil(store.workspace(with: snapshot.workspaces[0].id))
}
```

- [ ] **Step 4: Run the focused iOS tests to verify failure**

Run:

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo/ios
xcodebuild test -project cmux.xcodeproj -scheme cmux -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:cmuxTests/AppDatabaseTests \
  -only-testing:cmuxTests/UnifiedInboxSyncServiceTests \
  -only-testing:cmuxTests/TerminalSidebarStoreTests
```

Expected: FAIL because the cache-first seams and helpers do not exist yet.

- [ ] **Step 5: Commit**

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo
git add ios/cmuxTests/AppDatabaseTests.swift ios/cmuxTests/UnifiedInboxSyncServiceTests.swift ios/cmuxTests/TerminalSidebarStoreTests.swift
git commit -m "test: lock cache-first mobile workspace behavior"
```

### Task 2: Lock The Backend Contract In Tests

**Files:**
- Create: `packages/shared/src/mobile-contracts.ts`
- Test: `apps/www/lib/routes/mobile-machine-session.route.test.ts`
- Test: `apps/www/lib/routes/mobile-heartbeat.route.test.ts`
- Test: `apps/www/lib/routes/mobile-push.route.test.ts`
- Test: `apps/www/lib/routes/mobile-mark-read.route.test.ts`
- Test: `apps/www/lib/routes/daemon-ticket.route.test.ts`

- [ ] **Step 1: Write the failing route contract tests**

Add route tests that decode bodies through a single shared schema and reject drift:

```ts
it("accepts a heartbeat payload that matches the shared contract", async () => {
  const payload: MobileHeartbeatPayload = {
    machineId: "machine_123",
    displayName: "Mac Mini",
    tailscaleHostname: "macmini.tailnet.ts.net",
    tailscaleIPs: ["100.64.0.10"],
    status: "online",
    lastSeenAt: 1000,
    lastWorkspaceSyncAt: 1000,
    directConnect: {
      directPort: 45123,
      directTlsPins: ["pin_a"],
      ticketSecret: "secret_a",
    },
    workspaces: [],
  };

  const response = await app.request("/api/mobile/heartbeat", {
    method: "POST",
    body: JSON.stringify(payload),
    headers: { authorization: "Bearer token", "content-type": "application/json" },
  });

  expect(response.status).toBe(202);
});
```

- [ ] **Step 2: Write the failing mark-read route test**

```ts
it("marks a workspace read through the HTTP boundary", async () => {
  const response = await app.request("/api/mobile/workspaces/mark-read", {
    method: "POST",
    body: JSON.stringify({
      teamSlugOrId: "team_123",
      workspaceId: "ws_123",
      latestEventSeq: 6,
    }),
    headers: { authorization: "Bearer user-token", "content-type": "application/json" },
  });

  expect(response.status).toBe(200);
});
```

- [ ] **Step 3: Run the focused backend tests to verify failure**

Run:

```bash
cd /Users/lawrence/.config/superpowers/worktrees/manaflow/feat-ios-dogfood-convex
bunx vitest run \
  apps/www/lib/routes/mobile-machine-session.route.test.ts \
  apps/www/lib/routes/mobile-heartbeat.route.test.ts \
  apps/www/lib/routes/mobile-push.route.test.ts \
  apps/www/lib/routes/mobile-mark-read.route.test.ts \
  apps/www/lib/routes/daemon-ticket.route.test.ts
```

Expected: FAIL because the shared contract package and mark-read route do not exist yet.

- [ ] **Step 4: Commit**

```bash
cd /Users/lawrence/.config/superpowers/worktrees/manaflow/feat-ios-dogfood-convex
git add packages/shared/src/mobile-contracts.ts apps/www/lib/routes/*.test.ts
git commit -m "test: lock mobile HTTP contract"
```

## Chunk 2: Make GRDB The Mandatory Local Read Model

### Task 3: Harden The GRDB Schema And Migrations

**Files:**
- Modify: `ios/Sources/Persistence/AppDatabase.swift`
- Modify: `ios/Sources/Persistence/AppDatabaseMigrator.swift`
- Modify: `ios/Sources/Persistence/InboxCacheRepository.swift`
- Modify: `ios/Sources/Persistence/TerminalCacheRepository.swift`
- Test: `ios/cmuxTests/AppDatabaseTests.swift`

- [ ] **Step 1: Add the failing migration test**

```swift
func testMigrationPreservesUnreadAndRemoteWorkspaceMetadata() throws {
    let db = try AppDatabase.inMemory()
    try AppDatabaseMigrator.migrate(db)
    try db.writeWorkspaceInboxRow(
        workspaceID: "ws_123",
        machineID: "machine_123",
        teamID: "team_123",
        title: "cmux",
        preview: "running tests",
        tmuxSessionName: "cmux-1",
        lastActivityAt: Date(timeIntervalSince1970: 100),
        latestEventSeq: 9,
        lastReadEventSeq: 6
    )

    let row = try db.readWorkspaceInboxRow(workspaceID: "ws_123")
    XCTAssertEqual(row?.unreadCount, 3)
    XCTAssertEqual(row?.tmuxSessionName, "cmux-1")
}
```

- [ ] **Step 2: Run the focused migration test**

Run:

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo/ios
xcodebuild test -project cmux.xcodeproj -scheme cmux -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:cmuxTests/AppDatabaseTests
```

Expected: FAIL because the schema does not yet guarantee these fields round-trip cleanly.

- [ ] **Step 3: Make the GRDB schema explicit**

Ensure the schema cleanly persists:

```swift
hosts
workspaces
machine_presence
workspace_user_state
inbox_items
app_metadata
```

Required persisted fields:

- `workspace_id`
- `machine_id`
- `team_id`
- `remote_workspace_id`
- `tmux_session_name`
- `latest_event_seq`
- `last_read_event_seq`
- `last_activity_at`
- `preview`
- `tailscale_hostname`
- `tailscale_ips_json`

Add indexes for:

- `inbox_items(last_activity_at DESC)`
- `workspace_user_state(workspace_id)`
- `machine_presence(machine_id)`

- [ ] **Step 4: Import legacy data deterministically**

`AppDatabaseMigrator` must still import `terminal-store.json` once, but after that GRDB is canonical. The JSON file is only a bootstrap source, never the steady-state store.

- [ ] **Step 5: Re-run the migration tests**

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo
git add ios/Sources/Persistence ios/cmuxTests/AppDatabaseTests.swift
git commit -m "ios: harden grdb mobile workspace schema"
```

### Task 4: Route All Inbox Rendering Through GRDB First

**Files:**
- Create: `ios/Sources/Mobile/ConvexWorkspaceLiveSync.swift`
- Modify: `ios/Sources/Inbox/UnifiedInboxSyncService.swift`
- Modify: `ios/Sources/ViewModels/ConversationsViewModel.swift`
- Modify: `ios/Sources/Inbox/UnifiedInboxItem.swift`
- Test: `ios/cmuxTests/UnifiedInboxSyncServiceTests.swift`
- Test: `ios/cmuxTests/ConversationsViewModelTests.swift`

- [ ] **Step 1: Add the failing “cache first, live second” test**

```swift
func testConversationsViewModelUsesCachedWorkspaceRowsBeforeSubscriptionCompletes() throws {
    let cache = try makeRepositoryWithWorkspaceRow()
    let liveSync = BlockingWorkspaceLiveSync()
    let viewModel = ConversationsViewModel(
        autoLoad: false,
        inboxCacheRepository: cache,
        workspaceSyncService: UnifiedInboxSyncService(
            inboxCacheRepository: cache,
            workspaceLiveSync: liveSync
        )
    )

    XCTAssertEqual(viewModel.inboxItems.first?.kind, .workspace)
}
```

- [ ] **Step 2: Run the focused inbox tests**

Run:

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo/ios
xcodebuild test -project cmux.xcodeproj -scheme cmux -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:cmuxTests/UnifiedInboxSyncServiceTests \
  -only-testing:cmuxTests/ConversationsViewModelTests
```

Expected: FAIL because live sync is still too coupled to the current Convex path.

- [ ] **Step 3: Add a dedicated live-sync seam**

`ConvexWorkspaceLiveSync` should own:

- query name strings
- Convex argument encoding
- mapping `MobileInboxWorkspaceRow` into local models

`UnifiedInboxSyncService` should own:

- loading cached rows
- publishing cached rows immediately
- writing live rows into GRDB
- emitting merged rows after cache write

Do not let `ConversationsViewModel` talk to raw `ConvexClientManager` for workspace rows anymore.

- [ ] **Step 4: Re-run the inbox tests**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo
git add ios/Sources/Mobile ios/Sources/Inbox ios/Sources/ViewModels/ConversationsViewModel.swift ios/cmuxTests
git commit -m "ios: make grdb the primary inbox read model"
```

## Chunk 3: Hide Convex Behind A Stable Mobile Boundary

### Task 5: Define Shared Mobile Contracts In `packages/shared`

**Files:**
- Create: `packages/shared/src/mobile-contracts.ts`
- Modify: `packages/shared/src/index.ts`
- Test: `apps/www/lib/routes/mobile-machine-session.route.test.ts`
- Test: `apps/www/lib/routes/mobile-heartbeat.route.test.ts`
- Test: `apps/www/lib/routes/mobile-mark-read.route.test.ts`
- Test: `apps/www/lib/routes/daemon-ticket.route.test.ts`
- Create: `ios/Sources/Mobile/MobileContractModels.swift`
- Test: `ios/cmuxTests/NotificationManagerTests.swift`

- [ ] **Step 1: Add the failing decode-parity test**

Add one JSON fixture-driven test on each side that proves the same shape decodes:

```ts
export const MobileHeartbeatPayloadSchema = z.object({
  machineId: z.string(),
  displayName: z.string(),
  tailscaleHostname: z.string().optional(),
  tailscaleIPs: z.array(z.string()),
  status: z.enum(["online", "offline", "unknown"]),
  lastSeenAt: z.number(),
  lastWorkspaceSyncAt: z.number(),
  directConnect: z.object({
    directPort: z.number(),
    directTlsPins: z.array(z.string()),
    ticketSecret: z.string(),
  }).optional(),
  workspaces: z.array(MobileWorkspaceHeartbeatRowSchema),
})
```

```swift
func testHeartbeatPayloadFixtureDecodes() throws {
    let payload = try JSONDecoder().decode(MobileHeartbeatPayload.self, from: heartbeatFixture)
    XCTAssertEqual(payload.machineID, "machine_123")
}
```

- [ ] **Step 2: Run the parity tests**

Run:

```bash
cd /Users/lawrence/.config/superpowers/worktrees/manaflow/feat-ios-dogfood-convex && bunx vitest run apps/www/lib/routes/mobile-heartbeat.route.test.ts
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo/ios && xcodebuild test -project cmux.xcodeproj -scheme cmux -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:cmuxTests/NotificationManagerTests
```

Expected: FAIL until the shared contract types exist.

- [ ] **Step 3: Define the shared payloads**

Put these in `packages/shared/src/mobile-contracts.ts`:

- `MobileMachineSessionRequestSchema`
- `MobileMachineSessionResponseSchema`
- `MobileHeartbeatPayloadSchema`
- `MobileWorkspaceHeartbeatRowSchema`
- `MobileInboxWorkspaceRowSchema`
- `MobilePushRegisterRequestSchema`
- `MobilePushRemoveRequestSchema`
- `MobilePushTestRequestSchema`
- `MobileMarkReadRequestSchema`
- `DaemonTicketRequestSchema`
- `DaemonTicketResponseSchema`

Mirror those shapes in `ios/Sources/Mobile/MobileContractModels.swift` using `Codable` structs. Keep them small and hand-maintained for now. Do not add codegen in this plan.

- [ ] **Step 4: Re-run the parity tests**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/lawrence/.config/superpowers/worktrees/manaflow/feat-ios-dogfood-convex
git add packages/shared/src/mobile-contracts.ts packages/shared/src/index.ts
git commit -m "shared: add mobile workspace contracts"

cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo
git add ios/Sources/Mobile/MobileContractModels.swift ios/cmuxTests/NotificationManagerTests.swift
git commit -m "ios: mirror mobile workspace contracts"
```

### Task 6: Move Mutations And Side Effects Behind HTTP Routes

**Files:**
- Create: `apps/www/lib/routes/mobile-push.route.ts`
- Create: `apps/www/lib/routes/mobile-mark-read.route.ts`
- Modify: `apps/www/lib/routes/mobile-machine-session.route.ts`
- Modify: `apps/www/lib/routes/mobile-heartbeat.route.ts`
- Modify: `apps/www/lib/routes/daemon-ticket.route.ts`
- Modify: `apps/www/lib/routes/index.ts`
- Modify: `ios/Sources/Notifications/NotificationManager.swift`
- Modify: `ios/Sources/Terminal/TerminalSidebarStore.swift`
- Modify: `cmux/Sources/MobilePresence/MachineSessionClient.swift`
- Test: `apps/www/lib/routes/mobile-push.route.test.ts`
- Test: `apps/www/lib/routes/mobile-mark-read.route.test.ts`
- Test: `ios/cmuxTests/NotificationManagerTests.swift`
- Test: `ios/cmuxTests/TerminalSidebarStoreTests.swift`
- Test: `cmuxTests/MachineSessionClientTests.swift`

- [ ] **Step 1: Add the failing mark-read and push tests**

```ts
it("routes mark-read through HTTP and not direct client-side Convex mutation", async () => {
  const response = await app.request("/api/mobile/workspaces/mark-read", {
    method: "POST",
    headers: authHeaders,
    body: JSON.stringify({ teamSlugOrId: "team_123", workspaceId: "ws_123", latestEventSeq: 9 }),
  })
  expect(response.status).toBe(200)
})
```

```swift
func testNotificationManagerRegistersPushTokenThroughServerRoute() async throws {
    let api = RecordingMobileServerAPI()
    let manager = NotificationManager(
        pushSyncer: APIPushSyncer(api: api),
        ...
    )
    try await manager.syncTokenIfPossible()
    XCTAssertEqual(api.lastPath, "/api/mobile/push/register")
}
```

- [ ] **Step 2: Run the focused tests**

Run:

```bash
cd /Users/lawrence/.config/superpowers/worktrees/manaflow/feat-ios-dogfood-convex && bunx vitest run apps/www/lib/routes/mobile-push.route.test.ts apps/www/lib/routes/mobile-mark-read.route.test.ts
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo/ios && xcodebuild test -project cmux.xcodeproj -scheme cmux -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:cmuxTests/NotificationManagerTests -only-testing:cmuxTests/TerminalSidebarStoreTests
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in && xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit -destination 'platform=macOS' -derivedDataPath /tmp/cmux-convex-mobile-boundary -only-testing:cmuxTests/MachineSessionClientTests test
```

Expected: FAIL until the HTTP boundary is complete.

- [ ] **Step 3: Make the routes canonical**

Rules:

- machine session, heartbeat, mark-read, push register/remove/test, and daemon ticket all go through Hono routes
- routes may call Convex internally
- iOS and macOS apps do not call Convex mutations directly for these side effects

Keep live workspace list subscription on Convex for now, but all side effects cross the HTTP boundary.

- [ ] **Step 4: Re-run the focused tests**

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/lawrence/.config/superpowers/worktrees/manaflow/feat-ios-dogfood-convex
git add apps/www/lib/routes
git commit -m "www: add canonical mobile workspace routes"

cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo
git add ios/Sources/Notifications ios/Sources/Terminal/TerminalSidebarStore.swift ios/cmuxTests
git commit -m "ios: use mobile workspace HTTP boundary"

cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in
git add Sources/MobilePresence cmuxTests/MachineSessionClientTests.swift
git commit -m "cmux: publish mobile presence through server contract"
```

## Chunk 4: Add PostHog Analytics Without Adding Another Database

### Task 7: Instrument The Questions We Will Actually Want To Answer

**Files:**
- Create: `packages/shared/src/mobile-analytics.ts`
- Create: `apps/www/lib/analytics/track-mobile-event.ts`
- Create: `apps/www/lib/routes/mobile-analytics.route.ts`
- Modify: `apps/www/lib/routes/mobile-machine-session.route.ts`
- Modify: `apps/www/lib/routes/mobile-heartbeat.route.ts`
- Modify: `apps/www/lib/routes/daemon-ticket.route.ts`
- Modify: `apps/www/lib/routes/mobile-push.route.ts`
- Modify: `apps/www/lib/routes/mobile-mark-read.route.ts`
- Create: `ios/Sources/Mobile/MobileAnalyticsClient.swift`
- Modify: `ios/Sources/ViewModels/ConversationsViewModel.swift`
- Modify: `ios/Sources/Terminal/TerminalSidebarStore.swift`
- Test: `apps/www/lib/routes/mobile-analytics.route.test.ts`
- Test: `ios/cmuxTests/ConversationsViewModelTests.swift`

- [ ] **Step 1: Add the failing analytics route test**

```ts
it("captures a mobile workspace opened event with team and workspace dimensions", async () => {
  const response = await app.request("/api/mobile/analytics", {
    method: "POST",
    headers: authHeaders,
    body: JSON.stringify({
      event: "mobile_workspace_opened",
      properties: {
        teamId: "team_123",
        teamKind: "personal",
        machineId: "machine_123",
        workspaceId: "ws_123",
        source: "inbox",
      },
    }),
  })

  expect(response.status).toBe(202)
})
```

- [ ] **Step 2: Define the event taxonomy**

Put the canonical event names in `packages/shared/src/mobile-analytics.ts`:

- `mobile_machine_session_issued`
- `mobile_heartbeat_ingested`
- `mobile_workspace_snapshot_ingested`
- `mobile_workspace_opened`
- `mobile_workspace_mark_read`
- `mobile_push_registered`
- `mobile_push_removed`
- `mobile_push_test_sent`
- `mobile_push_opened`
- `mobile_daemon_ticket_issued`
- `mobile_daemon_attach_result`
- `ios_grdb_boot_completed`

Shared properties:

- `teamId`
- `teamKind` (`personal` or `shared`)
- `userId`
- `machineId`
- `workspaceId`
- `platform`
- `bundleId`
- `source`
- `result`
- `errorCode`
- `latencyMs`
- `cacheAgeMs`
- `workspaceCount`
- `unreadCount`

- [ ] **Step 3: Track only useful questions**

Instrument enough data to answer these later:

1. How long after Mac sign-in does the machine appear on iOS?
2. What percentage of daemon tickets turn into successful attaches?
3. How often do push notifications lead to workspace open?
4. How often does iOS boot from cache with stale data older than 5 minutes?
5. Are personal teams or shared teams using the feature more?
6. Which machines churn between online and offline most often?
7. How many unread workspaces are opened versus ignored?

Do not track raw terminal content or scrollback. Do not send secrets, TLS pins, ticket secrets, or repo paths.

- [ ] **Step 4: Re-run the analytics tests**

Run:

```bash
cd /Users/lawrence/.config/superpowers/worktrees/manaflow/feat-ios-dogfood-convex && bunx vitest run apps/www/lib/routes/mobile-analytics.route.test.ts
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo/ios && xcodebuild test -project cmux.xcodeproj -scheme cmux -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:cmuxTests/ConversationsViewModelTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/lawrence/.config/superpowers/worktrees/manaflow/feat-ios-dogfood-convex
git add packages/shared/src/mobile-analytics.ts apps/www/lib/analytics apps/www/lib/routes/mobile-analytics.route.ts
git commit -m "analytics: add mobile workspace posthog events"

cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo
git add ios/Sources/Mobile/MobileAnalyticsClient.swift ios/Sources/ViewModels/ConversationsViewModel.swift ios/Sources/Terminal/TerminalSidebarStore.swift
git commit -m "ios: track mobile workspace analytics"
```

## Chunk 5: Dogfood The Convex Path And Keep It Reversible

### Task 8: Run The Dogfood Gate And Update The Docs

**Files:**
- Modify: `ios/README.md`
- Modify: `docs/superpowers/plans/2026-03-18-ios-convex-grdb-cache-boundary.md`
- Modify: `docs/superpowers/plans/2026-03-17-cmuxterm-optional-sign-in.md`

- [ ] **Step 1: Run backend verification**

Run:

```bash
cd /Users/lawrence/.config/superpowers/worktrees/manaflow/feat-ios-dogfood-convex
bunx vitest run packages/convex/convex/mobileInbox.test.ts apps/www/lib/routes/mobile-machine-session.route.test.ts apps/www/lib/routes/mobile-heartbeat.route.test.ts apps/www/lib/routes/mobile-push.route.test.ts apps/www/lib/routes/mobile-mark-read.route.test.ts apps/www/lib/routes/daemon-ticket.route.test.ts apps/www/lib/routes/mobile-analytics.route.test.ts
bun check
```

Expected: PASS.

- [ ] **Step 2: Run the focused iOS verification**

Run:

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo/ios
xcodebuild test -project cmux.xcodeproj -scheme cmux -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:cmuxTests/AppDatabaseTests \
  -only-testing:cmuxTests/UnifiedInboxSyncServiceTests \
  -only-testing:cmuxTests/ConversationsViewModelTests \
  -only-testing:cmuxTests/NotificationManagerTests \
  -only-testing:cmuxTests/TerminalSidebarStoreTests
```

Expected: PASS.

- [ ] **Step 3: Run the focused mac verification**

Run:

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit -destination 'platform=macOS' -derivedDataPath /tmp/cmux-convex-mobile-final -only-testing:cmuxTests/MachineSessionClientTests -only-testing:cmuxTests/MobileHeartbeatPublisherTests test
```

Expected: PASS.

- [ ] **Step 4: Reload tagged builds**

Run:

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in
./scripts/reload.sh --tag convex-mobile-cache

cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo
./ios/scripts/reload.sh --tag ios-convex-mobile-cache
```

Expected:

- tagged Mac build launches
- tagged simulator build installs
- best-effort iPhone install runs

- [ ] **Step 5: Manual dogfood checklist**

Verify on real devices:

1. Signed-in iOS launch shows cached machines/workspaces immediately, before live sync finishes.
2. Killing the app and relaunching offline still shows the last cached workspace list.
3. A signed-in Mac heartbeat updates the iOS list live when connectivity returns.
4. Opening a workspace clears unread both locally and in Convex.
5. Push registration, test push, and push-open routing work.
6. Daemon ticket issuance still opens the correct workspace without the config sheet.
7. PostHog receives the events needed for the future product questions above.

- [ ] **Step 6: Document the architecture decision**

Update the docs to make these rules explicit:

- GRDB cache on iOS is mandatory, not optional
- Convex is the current operational source of truth
- PostHog is analytics only
- all side effects go through the mobile HTTP boundary
- live workspace rows may still use Convex subscriptions behind a dedicated service seam

- [ ] **Step 7: Commit**

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo
git add ios/README.md docs/superpowers/plans/2026-03-18-ios-convex-grdb-cache-boundary.md
git commit -m "docs: record convex mobile cache-first architecture"
```

## Notes For Future Migration

- Do not add a second operational database before dogfooding this version.
- If Convex becomes the bottleneck later, migrate the backend implementation behind the same mobile contracts and service protocols.
- Keep Swift models and TS mobile contract types aligned through fixture-based tests. Full codegen can be a separate plan once the payloads stop churning.

## Execution Status

Implemented on feature branches only:
- `task-move-ios-app-into-cmux-repo`
- `feat-ios-dogfood-convex`

Completed in this pass:
- GRDB remains the mandatory cache-first iOS read model.
- Workspace live sync stays behind a dedicated Convex seam.
- Machine session, heartbeat, mark-read, push, daemon-ticket, and analytics all cross the mobile HTTP boundary.
- Mobile analytics now emit the PostHog events needed for cache boot, workspace open, attach result, push lifecycle, machine-session issuance, heartbeat ingestion, and daemon-ticket issuance.

Verified commands:

```bash
cd /Users/lawrence/.config/superpowers/worktrees/manaflow/feat-ios-dogfood-convex
bunx vitest run packages/convex/convex/mobileInbox.test.ts apps/www/lib/routes/mobile-machine-session.route.test.ts apps/www/lib/routes/mobile-heartbeat.route.test.ts apps/www/lib/routes/mobile-push.route.test.ts apps/www/lib/routes/mobile-mark-read.route.test.ts apps/www/lib/routes/daemon-ticket.route.test.ts apps/www/lib/routes/mobile-analytics.route.test.ts
set -a; source ~/.secrets/cmux.env; set +a; bun check

cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo/ios
xcodebuild test -project cmux.xcodeproj -scheme cmux -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath /tmp/ios-convex-mobile-cache-gate -only-testing:cmuxTests/AppDatabaseTests -only-testing:cmuxTests/UnifiedInboxSyncServiceTests -only-testing:cmuxTests/ConversationsViewModelTests -only-testing:cmuxTests/NotificationManagerTests -only-testing:cmuxTests/TerminalSidebarStoreTests

cd /Users/lawrence/fun/cmuxterm-hq/worktrees/feat-cmuxterm-optional-sign-in
xcodebuild -project GhosttyTabs.xcodeproj -scheme cmux-unit -destination 'platform=macOS' -derivedDataPath /tmp/cmux-convex-mobile-final -only-testing:cmuxTests/MachineSessionClientTests -only-testing:cmuxTests/MobileHeartbeatPublisherTests test
```

Still manual:
- Real-device cache-first launch check
- Offline relaunch check
- Live heartbeat resync check
- Push open routing check
- On-device direct attach check
