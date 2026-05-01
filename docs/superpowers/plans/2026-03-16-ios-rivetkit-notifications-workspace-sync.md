# iOS RivetKit Notifications And Workspace Sync Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add realtime workspace sync to the iOS terminal inbox and keep push notifications working, using RivetKit for live actor state while keeping APNS registration and delivery server-side.

**Architecture:** Keep native iOS concerns native. `NotificationManager` continues to own APNS permission and device-token lifecycle, `AuthManager` continues to own Stack access tokens, and `TerminalSidebarStore` stays the single source of truth for persisted workspaces. Add a thin RivetKit layer for live workspace and inbox events, authenticated with connection params derived from the existing Stack session. Reuse the existing APNS backend pattern from `manaflow` PR `swift-ios-clean` instead of trying to make RivetKit send push notifications directly.

**Tech Stack:** SwiftUI, RivetKitSwiftUI 2.1.6, RivetKitClient 2.1.6, Stack Auth, existing `CMUXAuthCore`, APNS, existing Convex workspace APIs, new RivetKit actor registry in `manaflow`.

---

## Chunk 1: Repo Boundaries And Contracts

### File Structure

**Client repo:** `/Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo`

- Modify: `ios/project.yml`
- Modify: `ios/Sources/CMuxApp.swift`
- Modify: `ios/Sources/ContentView.swift`
- Modify: `ios/Sources/Auth/AuthManager.swift`
- Modify: `ios/Sources/Config/Environment.swift`
- Modify: `ios/Sources/Config/LocalConfig.example.plist`
- Modify: `ios/Sources/Notifications/NotificationManager.swift`
- Modify: `ios/Sources/Terminal/TerminalSidebarStore.swift`
- Modify: `ios/Sources/Terminal/TerminalModels.swift`
- Modify: `ios/Sources/Terminal/TerminalWorkspaceIdentityService.swift`
- Modify: `ios/Sources/Terminal/TerminalWorkspaceMetadataService.swift`
- Create: `ios/Sources/Realtime/RivetConfig.swift`
- Create: `ios/Sources/Realtime/RivetConnectionParams.swift`
- Create: `ios/Sources/Realtime/WorkspaceInboxSyncService.swift`
- Create: `ios/Sources/Realtime/ActiveWorkspaceSyncService.swift`
- Create: `ios/Sources/Notifications/NotificationRouteStore.swift`
- Test: `ios/cmuxTests/RivetConfigTests.swift`
- Test: `ios/cmuxTests/WorkspaceInboxSyncServiceTests.swift`
- Test: `ios/cmuxTests/ActiveWorkspaceSyncServiceTests.swift`
- Test: `ios/cmuxTests/NotificationManagerTests.swift`
- Test: `ios/cmuxTests/TerminalSidebarStoreTests.swift`

**Backend repo:** `/Users/lawrence/fun/manaflow`

- Reuse: `packages/convex/convex/pushTokens.ts`
- Reuse: `packages/convex/convex/pushNotificationsActions.ts`
- Reuse: `packages/convex/convex/localWorkspaces.ts`
- Reuse: `packages/convex/convex/tasks.ts`
- Reuse: `packages/convex/convex/schema.ts`
- Reuse: `packages/convex/_shared/convex-env.ts`
- Modify: `apps/www/package.json`
- Modify: `apps/www/lib/hono-app.ts`
- Modify: `apps/www/lib/routes/index.ts`
- Create: `apps/www/lib/rivet/actors/workspaceInbox.ts`
- Create: `apps/www/lib/rivet/actors/workspaceSession.ts`
- Create: `apps/www/lib/rivet/registry.ts`
- Create: `apps/www/lib/rivet/auth.ts`
- Create: `apps/www/lib/routes/mobile.rivet-session.route.ts`
- Test: `apps/www/lib/rivet/workspaceInbox.test.ts`
- Test: `apps/www/lib/rivet/workspaceSession.test.ts`
- Test: `apps/www/lib/routes/mobile.rivet-session.route.test.ts`

### Task 1: Freeze Config And Secret Boundaries

**Files:**
- Modify: `ios/Sources/Config/Environment.swift`
- Modify: `ios/Sources/Config/LocalConfig.example.plist`
- Create: `ios/Sources/Realtime/RivetConfig.swift`
- Test: `ios/cmuxTests/RivetConfigTests.swift`

- [ ] **Step 1: Write the failing config test**

```swift
@Test("Rivet config resolves per-environment public endpoint overrides")
func rivetConfigPrefersEnvironmentSpecificOverride() throws {
    let overrides = [
        "RIVET_PUBLIC_ENDPOINT_DEV": "https://dev-public.example/api/rivet",
        "RIVET_PUBLIC_ENDPOINT_PROD": "https://prod-public.example/api/rivet"
    ]
    #expect(RivetConfig.resolve(environment: .development, overrides: overrides).publicEndpoint == "https://dev-public.example/api/rivet")
    #expect(RivetConfig.resolve(environment: .production, overrides: overrides).publicEndpoint == "https://prod-public.example/api/rivet")
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo/ios && xcodebuild test -project cmux.xcodeproj -scheme cmux -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:cmuxTests/RivetConfigTests`

Expected: FAIL because `RivetConfig` does not exist.

- [ ] **Step 3: Add the minimal config object**

```swift
struct RivetConfig: Equatable {
    let publicEndpoint: String

    static func resolve(environment: Environment, overrides: [String: String]) -> Self {
        let key = environment == .development ? "RIVET_PUBLIC_ENDPOINT_DEV" : "RIVET_PUBLIC_ENDPOINT_PROD"
        let endpoint = overrides[key] ?? ""
        return Self(publicEndpoint: endpoint)
    }
}
```

- [ ] **Step 4: Extend app config resolution**

Add these keys to `LocalConfig.example.plist`:

```xml
<key>RIVET_PUBLIC_ENDPOINT_DEV</key>
<string></string>
<key>RIVET_PUBLIC_ENDPOINT_PROD</key>
<string></string>
```

Expose `Environment.current.rivetConfig`.

- [ ] **Step 5: Run the test to verify it passes**

Run the same `xcodebuild test` command.

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo
git add ios/Sources/Config/Environment.swift ios/Sources/Config/LocalConfig.example.plist ios/Sources/Realtime/RivetConfig.swift ios/cmuxTests/RivetConfigTests.swift
git commit -m "ios: add Rivet public endpoint configuration"
```

### Task 2: Copy The Existing APNS Contract Before Adding RivetKit

**Files:**
- Modify: `/Users/lawrence/fun/manaflow/packages/convex/convex/pushTokens.ts`
- Modify: `/Users/lawrence/fun/manaflow/packages/convex/convex/pushNotificationsActions.ts`
- Modify: `/Users/lawrence/fun/manaflow/packages/convex/convex/schema.ts`
- Modify: `/Users/lawrence/fun/manaflow/packages/convex/_shared/convex-env.ts`

- [ ] **Step 1: Diff against the existing Swift notification precedent**

Reference:
- `https://github.com/manaflow-ai/manaflow/pull/1417`
- commit `d623ced3f` (`ios: improve auth persistence and notifications`)
- commit `791955477` (`convex: Add iOS push notification system with APNS`)

Expected copy targets:
- token upsert/remove/test mutation
- `devicePushTokens` table
- APNS HTTP/2 sender

- [ ] **Step 2: Harden env validation**

Add these server env keys to `packages/convex/_shared/convex-env.ts`:

```ts
APNS_TEAM_ID: z.string().min(1).optional(),
APNS_KEY_ID: z.string().min(1).optional(),
APNS_PRIVATE_KEY_BASE64: z.string().min(1).optional(),
```

- [ ] **Step 3: Verify the backend still typechecks**

Run: `cd /Users/lawrence/fun/manaflow/packages/convex && bunx tsc --noEmit`

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
cd /Users/lawrence/fun/manaflow
git add packages/convex/convex/pushTokens.ts packages/convex/convex/pushNotificationsActions.ts packages/convex/convex/schema.ts packages/convex/_shared/convex-env.ts
git commit -m "convex: add validated APNS push token contract"
```

## Chunk 2: RivetKit Backend For Realtime Workspace Sync

### Task 3: Add A Public Rivet Registry And Auth Mint Route

**Files:**
- Modify: `/Users/lawrence/fun/manaflow/apps/www/package.json`
- Create: `/Users/lawrence/fun/manaflow/apps/www/lib/rivet/auth.ts`
- Create: `/Users/lawrence/fun/manaflow/apps/www/lib/rivet/registry.ts`
- Create: `/Users/lawrence/fun/manaflow/apps/www/lib/routes/mobile.rivet-session.route.ts`
- Modify: `/Users/lawrence/fun/manaflow/apps/www/lib/routes/index.ts`
- Modify: `/Users/lawrence/fun/manaflow/apps/www/lib/hono-app.ts`
- Test: `/Users/lawrence/fun/manaflow/apps/www/lib/routes/mobile.rivet-session.route.test.ts`

- [ ] **Step 1: Write the failing route test**

```ts
it("returns a public endpoint for an authenticated mobile user", async () => {
  const response = await app.request("/api/mobile/rivet-session", { method: "POST" });
  expect(response.status).toBe(200);
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /Users/lawrence/fun/manaflow/apps/www && bun test lib/routes/mobile.rivet-session.route.test.ts`

Expected: FAIL because the route does not exist.

- [ ] **Step 3: Add RivetKit dependency and registry shell**

Create `lib/rivet/registry.ts` with:

```ts
import { setup } from "rivetkit";
import { workspaceInbox } from "./actors/workspaceInbox";
import { workspaceSession } from "./actors/workspaceSession";

export const registry = setup({
  use: { workspaceInbox, workspaceSession },
});
```

- [ ] **Step 4: Add authenticated config route**

Return only public client data:

```ts
{
  publicEndpoint: process.env.RIVET_PUBLIC_ENDPOINT,
  teamId,
  userId
}
```

Do not return `RIVET_TOKEN`.

- [ ] **Step 5: Run the route test**

Run the same `bun test` command.

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
cd /Users/lawrence/fun/manaflow
git add apps/www/package.json apps/www/lib/rivet/auth.ts apps/www/lib/rivet/registry.ts apps/www/lib/routes/mobile.rivet-session.route.ts apps/www/lib/routes/index.ts apps/www/lib/hono-app.ts apps/www/lib/routes/mobile.rivet-session.route.test.ts
git commit -m "www: expose Rivet mobile session bootstrap route"
```

### Task 4: Add Workspace Inbox And Active Workspace Actors

**Files:**
- Create: `/Users/lawrence/fun/manaflow/apps/www/lib/rivet/actors/workspaceInbox.ts`
- Create: `/Users/lawrence/fun/manaflow/apps/www/lib/rivet/actors/workspaceSession.ts`
- Test: `/Users/lawrence/fun/manaflow/apps/www/lib/rivet/workspaceInbox.test.ts`
- Test: `/Users/lawrence/fun/manaflow/apps/www/lib/rivet/workspaceSession.test.ts`

- [ ] **Step 1: Write the failing actor tests**

Inbox actor test:

```ts
it("emits workspace preview and unread updates for a user", async () => {
  // connect actor with auth params
  // publish update
  // assert event payload
});
```

Session actor test:

```ts
it("emits a full workspace snapshot for the requested workspace key", async () => {
  // seed source state
  // connect actor
  // assert snapshot
});
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
- `cd /Users/lawrence/fun/manaflow/apps/www && bun test lib/rivet/workspaceInbox.test.ts`
- `cd /Users/lawrence/fun/manaflow/apps/www && bun test lib/rivet/workspaceSession.test.ts`

Expected: FAIL because the actors do not exist.

- [ ] **Step 3: Implement connection auth**

Use RivetKit connection params instead of headers:

```ts
type ConnParams = {
  authToken: string;
  teamId: string;
  userId: string;
};
```

Validate in `createConnState` by verifying the Stack-derived access token or a short-lived server-issued JWT. Reject mismatched `teamId` and `userId`.

- [ ] **Step 4: Implement actor event surface**

`workspaceInbox` emits:
- `workspace_upsert`
- `workspace_remove`
- `workspace_notification`

`workspaceSession` emits:
- `workspace_snapshot`
- `workspace_phase`
- `workspace_bell`

Initial payload for `workspace_snapshot` should map directly into the current `TerminalWorkspace` display fields:

```ts
{
  workspaceId: string,
  title: string,
  preview: string | null,
  unread: boolean,
  phase: "idle" | "connecting" | "connected" | "reconnecting" | "disconnected" | "failed",
  lastActivity: number
}
```

- [ ] **Step 5: Run the actor tests**

Run the same `bun test` commands.

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
cd /Users/lawrence/fun/manaflow
git add apps/www/lib/rivet/actors/workspaceInbox.ts apps/www/lib/rivet/actors/workspaceSession.ts apps/www/lib/rivet/workspaceInbox.test.ts apps/www/lib/rivet/workspaceSession.test.ts
git commit -m "www: add Rivet workspace inbox and session actors"
```

## Chunk 3: iOS RivetKit Client Integration

### Task 5: Install RivetKit And Bootstrap It At The App Root

**Files:**
- Modify: `ios/project.yml`
- Modify: `ios/Sources/CMuxApp.swift`
- Modify: `ios/Sources/ContentView.swift`
- Modify: `ios/Sources/Auth/AuthManager.swift`
- Create: `ios/Sources/Realtime/RivetConnectionParams.swift`

- [ ] **Step 1: Write the failing client bootstrap test**

```swift
@Test("Auth manager exposes Rivet connection params for the signed-in user")
func authManagerBuildsRivetConnectionParams() async throws {
    let params = try await AuthManager.shared.rivetConnectionParams(teamID: "team_123")
    #expect(params.teamId == "team_123")
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo/ios && xcodebuild test -project cmux.xcodeproj -scheme cmux -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:cmuxTests/RivetConnectionParamsTests`

Expected: FAIL because the type and API do not exist.

- [ ] **Step 3: Add the package and connection params type**

`project.yml`:

```yaml
RivetKit:
  url: https://github.com/rivet-dev/rivetkit-swift
  from: "2.1.6"
```

Swift:

```swift
struct RivetConnectionParams: Encodable, Equatable {
    let authToken: String
    let teamId: String
    let userId: String
}
```

- [ ] **Step 4: Mount RivetKit once**

Update `CMuxApp.swift` so the authenticated root installs the client once:

```swift
ContentView()
    .rivetKit(endpoint: Environment.current.rivetConfig.publicEndpoint)
```

Do not scatter `.rivetKit` modifiers across feature views.

- [ ] **Step 5: Expose auth-derived params**

Add an `AuthManager` helper that returns:
- current user id
- Stack access token from `getAccessToken()`
- selected `teamId` supplied by caller

- [ ] **Step 6: Run the test to verify it passes**

Run the same `xcodebuild test` command.

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo
git add ios/project.yml ios/Sources/CMuxApp.swift ios/Sources/ContentView.swift ios/Sources/Auth/AuthManager.swift ios/Sources/Realtime/RivetConnectionParams.swift ios/cmuxTests/RivetConnectionParamsTests.swift
git commit -m "ios: add RivetKit app bootstrap"
```

### Task 6: Add Inbox And Active Workspace Sync Services

**Files:**
- Create: `ios/Sources/Realtime/WorkspaceInboxSyncService.swift`
- Create: `ios/Sources/Realtime/ActiveWorkspaceSyncService.swift`
- Modify: `ios/Sources/Terminal/TerminalSidebarStore.swift`
- Modify: `ios/Sources/Terminal/TerminalModels.swift`
- Modify: `ios/Sources/Terminal/TerminalWorkspaceIdentityService.swift`
- Modify: `ios/Sources/Terminal/TerminalWorkspaceMetadataService.swift`
- Test: `ios/cmuxTests/WorkspaceInboxSyncServiceTests.swift`
- Test: `ios/cmuxTests/ActiveWorkspaceSyncServiceTests.swift`
- Test: `ios/cmuxTests/TerminalSidebarStoreTests.swift`

- [ ] **Step 1: Write the failing sync-service tests**

Inbox service:

```swift
@Test("Inbox sync applies preview and unread updates to the store")
func inboxSyncAppliesWorkspaceUpsert() async throws {}
```

Active workspace service:

```swift
@Test("Active workspace sync replaces the selected workspace snapshot")
func activeSyncAppliesWorkspaceSnapshot() async throws {}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
- `cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo/ios && xcodebuild test -project cmux.xcodeproj -scheme cmux -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:cmuxTests/WorkspaceInboxSyncServiceTests`
- `cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo/ios && xcodebuild test -project cmux.xcodeproj -scheme cmux -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:cmuxTests/ActiveWorkspaceSyncServiceTests`

Expected: FAIL.

- [ ] **Step 3: Implement the inbox service using `RivetKitClient`**

Use service objects, not `@Actor`, for store integration. The service should:
- bootstrap once after auth
- connect to `workspaceInbox` with key `[teamId, userId]`
- translate actor events into store mutations

- [ ] **Step 4: Implement the active workspace service**

The service should:
- connect only for the selected workspace
- use key `[teamId, workspaceId]`
- expose a callback or async stream that `TerminalSidebarStore` can consume

- [ ] **Step 5: Add explicit store mutation APIs**

Add focused methods to `TerminalSidebarStore` such as:

```swift
func applyInboxWorkspace(_ snapshot: TerminalWorkspaceSyncSnapshot)
func removeWorkspaceSync(id: TerminalWorkspace.ID)
func applyActiveWorkspaceSnapshot(_ snapshot: TerminalWorkspaceSyncSnapshot)
```

Do not let services mutate `@Published` arrays directly.

- [ ] **Step 6: Keep existing Convex identity and metadata services**

Do not delete `TerminalWorkspaceIdentityService` or `TerminalWorkspaceMetadataService` in this pass. Use them to create and resolve workspace linkage, then let RivetKit handle live updates.

- [ ] **Step 7: Run the tests to verify they pass**

Run the same `xcodebuild test` commands plus:

`cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo/ios && xcodebuild test -project cmux.xcodeproj -scheme cmux -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:cmuxTests/TerminalSidebarStoreTests`

Expected: PASS for new sync cases and existing sidebar-store behavior.

- [ ] **Step 8: Commit**

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo
git add ios/Sources/Realtime/WorkspaceInboxSyncService.swift ios/Sources/Realtime/ActiveWorkspaceSyncService.swift ios/Sources/Terminal/TerminalSidebarStore.swift ios/Sources/Terminal/TerminalModels.swift ios/Sources/Terminal/TerminalWorkspaceIdentityService.swift ios/Sources/Terminal/TerminalWorkspaceMetadataService.swift ios/cmuxTests/WorkspaceInboxSyncServiceTests.swift ios/cmuxTests/ActiveWorkspaceSyncServiceTests.swift ios/cmuxTests/TerminalSidebarStoreTests.swift
git commit -m "ios: add Rivet-backed workspace sync services"
```

## Chunk 4: Push Routing And Final Verification

### Task 7: Finish Notification Routing And Auth Lifecycle Hooks

**Files:**
- Modify: `ios/Sources/Notifications/NotificationManager.swift`
- Create: `ios/Sources/Notifications/NotificationRouteStore.swift`
- Modify: `ios/Sources/CMuxApp.swift`
- Modify: `ios/Sources/Terminal/TerminalSidebarRootView.swift`
- Test: `ios/cmuxTests/NotificationManagerTests.swift`

- [ ] **Step 1: Write the failing notification-routing test**

```swift
@Test("Notification payload is converted into an in-app route")
func notificationResponseBuildsWorkspaceRoute() async throws {}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo/ios && xcodebuild test -project cmux.xcodeproj -scheme cmux -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:cmuxTests/NotificationManagerTests`

Expected: FAIL.

- [ ] **Step 3: Add explicit tap handling**

Implement:

```swift
nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse
) async
```

Parse existing payload fields already used by the APNS sender:
- `teamId`
- `taskId`
- `taskRunId`
- `type`

Publish an app route through `NotificationRouteStore`.

- [ ] **Step 4: Open the matching workspace if possible**

Handle routes in `TerminalSidebarRootView` by:
- resolving existing workspace by backend identity
- starting or opening the linked workspace if needed
- falling back to settings or inbox if the route cannot be resolved

- [ ] **Step 5: Keep token sync tied to auth**

Retain the current `AuthManager` hooks:
- after sign-in: `NotificationManager.shared.syncTokenIfPossible()`
- after sign-out: `NotificationManager.shared.unregisterFromServer()`

Do not move APNS token registration into RivetKit.

- [ ] **Step 6: Run the test to verify it passes**

Run the same `xcodebuild test` command.

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo
git add ios/Sources/Notifications/NotificationManager.swift ios/Sources/Notifications/NotificationRouteStore.swift ios/Sources/CMuxApp.swift ios/Sources/Terminal/TerminalSidebarRootView.swift ios/cmuxTests/NotificationManagerTests.swift
git commit -m "ios: route push notifications into workspace navigation"
```

### Task 8: Verify Both Repos End To End

**Files:**
- Verify only

- [ ] **Step 1: Regenerate the iOS project if package graph changed**

Run: `cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo/ios && xcodegen generate`

Expected: PASS.

- [ ] **Step 2: Run focused iOS unit tests**

Run:
- `cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo/ios && xcodebuild test -project cmux.xcodeproj -scheme cmux -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:cmuxTests/RivetConfigTests`
- `cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo/ios && xcodebuild test -project cmux.xcodeproj -scheme cmux -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:cmuxTests/WorkspaceInboxSyncServiceTests`
- `cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo/ios && xcodebuild test -project cmux.xcodeproj -scheme cmux -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:cmuxTests/ActiveWorkspaceSyncServiceTests`
- `cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo/ios && xcodebuild test -project cmux.xcodeproj -scheme cmux -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:cmuxTests/NotificationManagerTests`
- `cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo/ios && xcodebuild test -project cmux.xcodeproj -scheme cmux -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:cmuxTests/TerminalSidebarStoreTests`

Expected: PASS.

- [ ] **Step 3: Run backend tests**

Run:
- `cd /Users/lawrence/fun/manaflow/apps/www && bun test lib/routes/mobile.rivet-session.route.test.ts`
- `cd /Users/lawrence/fun/manaflow/apps/www && bun test lib/rivet/workspaceInbox.test.ts`
- `cd /Users/lawrence/fun/manaflow/apps/www && bun test lib/rivet/workspaceSession.test.ts`
- `cd /Users/lawrence/fun/manaflow/packages/convex && bunx tsc --noEmit`

Expected: PASS.

- [ ] **Step 4: Manual device verification**

Check:
- sign in on iPhone
- allow notifications
- confirm `pushTokens:upsert` succeeds
- update a workspace on desktop or backend and watch the inbox row update without relaunch
- tap an incoming push and confirm the correct workspace opens

- [ ] **Step 5: Commit integration fixes**

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo
git add -A
git commit -m "ios: verify Rivet workspace sync and push routing"
```

## Secret Inventory

### Public values safe to copy into `ios/Sources/Config/LocalConfig.plist`

- `CONVEX_URL_DEV`
- `CONVEX_URL_PROD`
- `STACK_PROJECT_ID_DEV`
- `STACK_PROJECT_ID_PROD`
- `STACK_PUBLISHABLE_CLIENT_KEY_DEV`
- `STACK_PUBLISHABLE_CLIENT_KEY_PROD`
- `API_BASE_URL_DEV`
- `API_BASE_URL_PROD`
- `RIVET_PUBLIC_ENDPOINT_DEV`
- `RIVET_PUBLIC_ENDPOINT_PROD`

### Server-only secrets that must stay out of the app bundle

- `APNS_TEAM_ID`
- `APNS_KEY_ID`
- `APNS_PRIVATE_KEY_BASE64`
- `STACK_WEBHOOK_SECRET`
- `STACK_SECRET_SERVER_KEY`
- `STACK_SUPER_SECRET_ADMIN_KEY`
- `CMUX_TASK_RUN_JWT_SECRET`
- `CMUX_CONVERSATION_JWT_SECRET` if ACP or conversation JWT flows stay enabled
- `ACP_CALLBACK_SECRET` if ACP callbacks stay enabled
- `RIVET_TOKEN` if using Rivet Cloud or self-hosted engine auth
- `RIVET_NAMESPACE` if you keep private namespace routing on the server

### Apple developer assets and capabilities

- Push Notifications capability for `dev.cmux.app.dev`
- Push Notifications capability for `dev.cmux.app.beta`
- Push Notifications capability for `dev.cmux.app`
- `aps-environment` entitlements already present in `ios/cmux.dev.entitlements` and `ios/cmux.prod.entitlements`
- APNS Auth Key (`.p8`) corresponding to `APNS_KEY_ID`

### Important implementation note

Do not copy `APNS_PRIVATE_KEY_BASE64`, `RIVET_TOKEN`, Stack server keys, or JWT secrets into `LocalConfig.plist`, Swift source, or Xcode build settings checked into git. The iOS app only needs public endpoints and publishable identifiers. Actor authorization should happen with connection params derived from the signed-in Stack session, not with a bundled backend secret.
