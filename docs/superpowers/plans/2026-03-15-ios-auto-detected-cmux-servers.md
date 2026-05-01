# iOS Auto-Detected cmux Servers Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an authenticated iOS terminal home that auto-loads the user’s available cmux servers, lets tapping a top server pin create a persisted terminal workspace immediately, and upgrades server-backed sessions to reuse the `cmuxd-remote` transport contract from the desktop SSH work.

**Architecture:** Keep the current `TerminalSidebarRootView` / `TerminalSidebarStore` UX, but replace “manual hosts only” with a merged server catalog: team-discovered cmux servers plus locally persisted custom overrides. For runtime transport, keep the current raw SSH shell path as the fallback, but add a daemon-backed path that reuses the Go `cmuxd-remote` RPC contract and session semantics from the desktop SSH branch, using bundled binaries and SSH-executed bootstrap on iOS.

**Tech Stack:** SwiftUI, Combine, ConvexMobile, StackAuth, SwiftNIO, SwiftNIOSSH, SwiftNIOTransportServices, libghostty, Go `cmuxd-remote`

---

## Scope and Assumptions

1. “Auto-detect all the cmux servers I have available” is implemented by reading authenticated team metadata that already exists in iOS via `teams:listTeamMemberships` and `team.serverMetadata`, not by trying to parse a macOS `~/.ssh/config` file on iOS.
2. The source of truth for discovered servers is a JSON payload stored in team `serverMetadata`, with local iOS state preserving secrets, trust decisions, UI ordering overrides, and persisted workspaces.
3. The reusable part of the desktop SSH PR is the remote daemon contract and bootstrap semantics:
   - Go daemon: `daemon/remote/cmd/cmuxd-remote/main.go`
   - Go CLI relay: `daemon/remote/cmd/cmuxd-remote/cli.go`
   - Mac bootstrap/orchestration reference: `Sources/Workspace.swift`
4. Do **not** port mac shell-out code (`Process`, `scp`, local `go build`) directly to iOS. iOS must instead use bundled `cmuxd-remote` binaries plus SSH-executed upload/bootstrap.
5. Manual custom servers stay supported as a fallback, but the primary UX becomes discovered server pins.

## Relevant Existing Code

- Current iOS home and launch UX:
  - `ios/Sources/Terminal/TerminalSidebarRootView.swift`
- Current iOS store, persistence, and session controller:
  - `ios/Sources/Terminal/TerminalSidebarStore.swift`
  - `ios/Sources/Terminal/TerminalModels.swift`
- Current iOS raw SSH transport:
  - `ios/Sources/Terminal/TerminalSSHTransport.swift`
- Current iOS app auth + team query building blocks:
  - `ios/Sources/Auth/AuthManager.swift`
  - `ios/Sources/Convex/ConvexClient.swift`
  - `ios/Sources/Debug/CodexOAuthView.swift`
- Existing iOS terminal spec:
  - `ios/docs/terminal-sidebar-living-spec.md`
- Desktop SSH reference branch:
  - `../issue-151-cef-ssh-browser-proxy/daemon/remote/cmd/cmuxd-remote/main.go`
  - `../issue-151-cef-ssh-browser-proxy/Sources/Workspace.swift`

## Target Metadata Shape

Use this JSON schema inside `team.serverMetadata` under a dedicated namespaced key:

```json
{
  "cmux": {
    "servers": [
      {
        "id": "cmux-macmini",
        "name": "Mac mini",
        "hostname": "cmux-macmini",
        "port": 22,
        "username": "cmux",
        "symbolName": "desktopcomputer",
        "palette": "mint",
        "transport": "cmuxd-remote",
        "bootstrapCommand": "tmux new-session -A -s {{session}}",
        "remoteDaemonPath": "~/.cmux/bin/cmuxd-remote",
        "preferredAuth": "password"
      }
    ]
  }
}
```

Rules:
- `id` must be stable across refreshes.
- `transport` values: `cmuxd-remote`, `raw-ssh`.
- Missing or invalid metadata must not wipe local workspaces.
- Local passwords and trusted host keys stay local-only and never go into team metadata.

## File Structure

**Create**
- `ios/Sources/Terminal/TerminalServerCatalog.swift`
  - Decode discovered server metadata, merge discovered and local hosts, preserve stable IDs.
- `ios/Sources/Terminal/TerminalServerDiscovery.swift`
  - Subscribe to `teams:listTeamMemberships`, extract the chosen team’s `serverMetadata`, publish catalog updates.
- `ios/Sources/Terminal/TerminalRemoteDaemonModels.swift`
  - JSON-RPC request/response structs and capability enums for `cmuxd-remote`.
- `ios/Sources/Terminal/TerminalRemoteDaemonBootstrap.swift`
  - Probe remote platform, select bundled binary, upload/install daemon, perform `hello`.
- `ios/Sources/Terminal/TerminalRemoteDaemonClient.swift`
  - Maintain stdio RPC session to `cmuxd-remote serve --stdio`.
- `ios/Sources/Terminal/TerminalRemoteDaemonTransport.swift`
  - Bridge daemon session RPC to `GhosttySurfaceView` input/output/resize.
- `ios/cmuxTests/TerminalServerCatalogTests.swift`
- `ios/cmuxTests/TerminalServerDiscoveryTests.swift`
- `ios/cmuxTests/TerminalRemoteDaemonBootstrapTests.swift`
- `ios/cmuxTests/TerminalRemoteDaemonClientTests.swift`
- `ios/cmuxUITests/TerminalSidebarDiscoveryUITests.swift`

**Modify**
- `ios/Sources/Terminal/TerminalModels.swift`
  - Add stable server identity, source, transport preference, discovery metadata.
- `ios/Sources/Terminal/TerminalSidebarStore.swift`
  - Merge discovered hosts, preserve persisted workspaces, choose transport path per host, persist launch behavior.
- `ios/Sources/Terminal/TerminalSidebarRootView.swift`
  - Treat top pins as discovered launch targets first, keep manual add/edit path secondary.
- `ios/Sources/Terminal/TerminalSSHTransport.swift`
  - Narrow this file to raw-shell SSH transport only, or rename internally to avoid mixing daemon behavior here.
- `ios/project.yml`
  - Add bundled daemon resources.
- `ios/Resources/Localizable.xcstrings`
  - Add any new user-facing strings in English and Japanese.
- `ios/docs/terminal-sidebar-living-spec.md`
  - Update milestones and validation notes.

**Reference Only**
- `issue-151-cef-ssh-browser-proxy/daemon/remote/cmd/cmuxd-remote/main.go`
- `issue-151-cef-ssh-browser-proxy/daemon/remote/cmd/cmuxd-remote/cli.go`
- `issue-151-cef-ssh-browser-proxy/Sources/Workspace.swift`

## Chunk 1: Discovery and Store

### Task 1: Lock the discovered-server model and merge semantics

**Files:**
- Create: `ios/Sources/Terminal/TerminalServerCatalog.swift`
- Modify: `ios/Sources/Terminal/TerminalModels.swift`
- Test: `ios/cmuxTests/TerminalServerCatalogTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
func testCatalogDecodesTeamServerMetadata() throws {
    let json = """
    {
      "cmux": {
        "servers": [
          {
            "id": "cmux-macmini",
            "name": "Mac mini",
            "hostname": "cmux-macmini",
            "port": 22,
            "username": "cmux",
            "symbolName": "desktopcomputer",
            "palette": "mint",
            "transport": "cmuxd-remote"
          }
        ]
      }
    }
    """

    let catalog = try TerminalServerCatalog(metadataJSON: json)
    XCTAssertEqual(catalog.hosts.map(\.stableID), ["cmux-macmini"])
    XCTAssertEqual(catalog.hosts.first?.transportPreference, .remoteDaemon)
}

func testMergePreservesLocalSecretsAndExistingWorkspaceHostIDs() throws {
    let discovered = [
        TerminalHost(
            stableID: "cmux-macmini",
            name: "Mac mini",
            hostname: "cmux-macmini",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            source: .discovered,
            transportPreference: .remoteDaemon
        )
    ]

    let local = [
        TerminalHost(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            stableID: "cmux-macmini",
            name: "Old Label",
            hostname: "cmux-macmini",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            bootstrapCommand: "tmux new-session -A -s {{session}}",
            trustedHostKey: "ssh-ed25519 AAAA",
            source: .discovered,
            transportPreference: .remoteDaemon
        )
    ]

    let merged = TerminalServerCatalog.merge(discovered: discovered, local: local)
    XCTAssertEqual(merged.first?.id.uuidString, "00000000-0000-0000-0000-000000000001")
    XCTAssertEqual(merged.first?.trustedHostKey, "ssh-ed25519 AAAA")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo/ios
xcodegen generate
xcodebuild test -project cmux.xcodeproj -scheme cmux -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:cmuxTests/TerminalServerCatalogTests
```

Expected: FAIL with missing `TerminalServerCatalog`, `stableID`, `transportPreference`, and `source` model symbols.

- [ ] **Step 3: Write the minimal implementation**

```swift
enum TerminalHostSource: String, Codable, Sendable {
    case discovered
    case custom
}

enum TerminalTransportPreference: String, Codable, Sendable {
    case rawSSH = "raw-ssh"
    case remoteDaemon = "cmuxd-remote"
}

struct TerminalServerCatalog {
    let hosts: [TerminalHost]

    init(metadataJSON: String) throws { ... }

    static func merge(discovered: [TerminalHost], local: [TerminalHost]) -> [TerminalHost] { ... }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run the same `xcodebuild test` command.

Expected: PASS for `TerminalServerCatalogTests`.

- [ ] **Step 5: Commit**

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo
git add ios/Sources/Terminal/TerminalModels.swift ios/Sources/Terminal/TerminalServerCatalog.swift ios/cmuxTests/TerminalServerCatalogTests.swift
git commit -m "test: cover iOS terminal server catalog merge"
```

### Task 2: Add authenticated server discovery from team metadata

**Files:**
- Create: `ios/Sources/Terminal/TerminalServerDiscovery.swift`
- Modify: `ios/Sources/Terminal/TerminalSidebarStore.swift`
- Test: `ios/cmuxTests/TerminalServerDiscoveryTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
func testDiscoveryPublishesHostsFromFirstTeamServerMetadata() async throws {
    let memberships = [
        TeamsListTeamMembershipsItem(
            team: .fixture(serverMetadata: #"{"cmux":{"servers":[{"id":"cmux-macmini","name":"Mac mini","hostname":"cmux-macmini","username":"cmux","symbolName":"desktopcomputer","palette":"mint","transport":"cmuxd-remote"}]}}"#),
            ...
        )
    ]

    let discovery = TerminalServerDiscovery(teamMemberships: .just(memberships).eraseToAnyPublisher())
    let hosts = try await discovery.firstHosts()
    XCTAssertEqual(hosts.map(\.stableID), ["cmux-macmini"])
}

func testStoreMergesDiscoveredHostsWithoutDroppingPersistedWorkspace() async throws {
    let existingHost = TerminalHost(... stableID: "cmux-macmini", source: .discovered, ...)
    let existingWorkspace = TerminalWorkspace(hostID: existingHost.id, title: "Mac mini", tmuxSessionName: "cmux-macmini")
    let store = makeStore(snapshot: .init(hosts: [existingHost], workspaces: [existingWorkspace], selectedWorkspaceID: existingWorkspace.id)).store

    await store.applyDiscoveredHosts([
        TerminalHost(... stableID: "cmux-macmini", name: "Mac Mini", source: .discovered, ...)
    ])

    XCTAssertEqual(store.workspaces.first?.hostID, existingHost.id)
    XCTAssertEqual(store.hosts.first?.name, "Mac Mini")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo/ios
xcodegen generate
xcodebuild test -project cmux.xcodeproj -scheme cmux -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:cmuxTests/TerminalServerDiscoveryTests -only-testing:cmuxTests/TerminalSidebarStoreTests
```

Expected: FAIL with missing discovery type and store merge hooks.

- [ ] **Step 3: Write the minimal implementation**

```swift
protocol TerminalServerDiscovering {
    var hostsPublisher: AnyPublisher<[TerminalHost], Never> { get }
}

final class TerminalServerDiscovery: TerminalServerDiscovering {
    init(convex: ConvexClientWithAuth<StackAuthResult> = ConvexClientManager.shared.client) { ... }
    let hostsPublisher: AnyPublisher<[TerminalHost], Never>
}

@MainActor
func applyDiscoveredHosts(_ hosts: [TerminalHost]) {
    self.hosts = TerminalServerCatalog.merge(discovered: hosts, local: self.hosts)
    rebuildControllers()
    persist()
}
```

- [ ] **Step 4: Run test to verify it passes**

Run the same `xcodebuild test` command.

Expected: PASS for the new discovery tests and updated store tests.

- [ ] **Step 5: Commit**

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo
git add ios/Sources/Terminal/TerminalServerDiscovery.swift ios/Sources/Terminal/TerminalSidebarStore.swift ios/cmuxTests/TerminalServerDiscoveryTests.swift ios/cmuxTests/TerminalSidebarStoreTests.swift
git commit -m "feat: discover iOS terminal servers from team metadata"
```

### Task 3: Make discovered pins the primary launcher flow

**Files:**
- Modify: `ios/Sources/Terminal/TerminalSidebarRootView.swift`
- Modify: `ios/Sources/Terminal/TerminalSidebarStore.swift`
- Modify: `ios/Resources/Localizable.xcstrings`
- Test: `ios/cmuxTests/TerminalSidebarStoreTests.swift`
- Test: `ios/cmuxUITests/TerminalSidebarDiscoveryUITests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor
func testStartWorkspaceOnDiscoveredHostCreatesPersistedWorkspaceImmediately() throws {
    let fixture = makeStore()
    let host = TerminalHost(... stableID: "cmux-macmini", source: .discovered, ...)
    fixture.store.applyDiscoveredHosts([host])
    fixture.credentialsStore.setPassword("secret", for: fixture.store.hosts[0].id)

    let workspaceID = fixture.store.startWorkspace(on: fixture.store.hosts[0])

    XCTAssertEqual(fixture.store.selectedWorkspaceID, workspaceID)
    XCTAssertEqual(fixture.snapshotStore.load().workspaces.first?.id, workspaceID)
}
```

```swift
func testDiscoveredServerTapCreatesWorkspaceAndShowsDetail() {
    let app = XCUIApplication()
    app.launchEnvironment["CMUX_UITEST_MOCK_TEAM_SERVER_METADATA"] = #"{"cmux":{"servers":[{"id":"cmux-macmini","name":"Mac mini","hostname":"cmux-macmini","username":"cmux","symbolName":"desktopcomputer","palette":"mint","transport":"raw-ssh"}]}}"#
    app.launchEnvironment["CMUX_UITEST_STACK_EMAIL"] = "l@l.com"
    app.launchEnvironment["CMUX_UITEST_STACK_PASSWORD"] = "abc123"
    app.launch()

    app.buttons["terminal.server.cmux-macmini"].tap()
    XCTAssertTrue(app.navigationBars["Mac mini"].waitForExistence(timeout: 5))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo/ios
xcodegen generate
xcodebuild test -project cmux.xcodeproj -scheme cmux -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:cmuxTests/TerminalSidebarStoreTests -only-testing:cmuxUITests/TerminalSidebarDiscoveryUITests
```

Expected: FAIL because no metadata-driven UI test hook exists and accessibility identifiers still assume manual hosts.

- [ ] **Step 3: Write the minimal implementation**

```swift
// TerminalSidebarRootView
ForEach(store.hosts) { host in
    Button {
        if store.canLaunch(host) {
            let workspaceID = store.startWorkspace(on: host)
            navigationPath.append(workspaceID)
        } else {
            pendingStartHostID = host.id
            editorDraft = TerminalHostEditorDraft(host: host, password: store.password(for: host))
        }
    } label: { ... }
    .accessibilityIdentifier("terminal.server.\(host.stableAccessibilitySlug)")
}
```

Add localized copy updates:
- “Servers” → “Available Servers”
- footer copy describing auto-detected servers
- any credential prompt copy for discovered hosts

- [ ] **Step 4: Run test to verify it passes**

Run the same `xcodebuild test` command.

Expected: PASS for store tests and the new targeted UI test.

- [ ] **Step 5: Commit**

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo
git add ios/Sources/Terminal/TerminalSidebarRootView.swift ios/Sources/Terminal/TerminalSidebarStore.swift ios/Resources/Localizable.xcstrings ios/cmuxTests/TerminalSidebarStoreTests.swift ios/cmuxUITests/TerminalSidebarDiscoveryUITests.swift
git commit -m "feat: launch persisted workspaces from discovered terminal pins"
```

## Chunk 2: Daemon-Backed Transport

### Task 4: Bundle and resolve `cmuxd-remote` binaries for iOS

**Files:**
- Modify: `ios/project.yml`
- Create: `ios/Sources/Terminal/TerminalRemoteDaemonBootstrap.swift`
- Test: `ios/cmuxTests/TerminalRemoteDaemonBootstrapTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
func testBundledDaemonPathPrefersExactPlatformMatch() throws {
    let locator = TerminalRemoteDaemonBootstrap.BundleLocator(resourceRoot: fixtureURL)
    let url = try locator.binaryURL(goOS: "linux", goArch: "arm64", version: "dev")
    XCTAssertTrue(url.lastPathComponent == "cmuxd-remote")
    XCTAssertTrue(url.path.contains("/linux-arm64/"))
}

func testRemotePlatformProbeParsesUnameOutput() throws {
    let platform = try TerminalRemoteDaemonBootstrap.parsePlatform(stdout: "Linux\nx86_64\n")
    XCTAssertEqual(platform.goOS, "linux")
    XCTAssertEqual(platform.goArch, "amd64")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo/ios
xcodegen generate
xcodebuild test -project cmux.xcodeproj -scheme cmux -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:cmuxTests/TerminalRemoteDaemonBootstrapTests
```

Expected: FAIL with missing bootstrap helper and bundle locator.

- [ ] **Step 3: Write the minimal implementation**

```swift
struct RemotePlatform: Equatable {
    let goOS: String
    let goArch: String
}

enum TerminalRemoteDaemonBootstrap {
    struct BundleLocator {
        func binaryURL(goOS: String, goArch: String, version: String) throws -> URL { ... }
    }

    static func parsePlatform(stdout: String) throws -> RemotePlatform { ... }
}
```

Implementation notes:
- Add daemon resources under `ios/Resources/cmuxd-remote/<version>/<goOS>-<goArch>/cmuxd-remote`.
- Start with four targets only: `darwin-arm64`, `darwin-amd64`, `linux-arm64`, `linux-amd64`.
- Keep this task resource-only. No SSH upload yet.

- [ ] **Step 4: Run test to verify it passes**

Run the same `xcodebuild test` command.

Expected: PASS for bootstrap resource/locator tests.

- [ ] **Step 5: Commit**

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo
git add ios/project.yml ios/Sources/Terminal/TerminalRemoteDaemonBootstrap.swift ios/cmuxTests/TerminalRemoteDaemonBootstrapTests.swift ios/Resources/cmuxd-remote
git commit -m "feat: bundle cmuxd-remote binaries for iOS terminal sessions"
```

### Task 5: Implement daemon bootstrap and JSON-RPC client over SSH stdio

**Files:**
- Create: `ios/Sources/Terminal/TerminalRemoteDaemonModels.swift`
- Create: `ios/Sources/Terminal/TerminalRemoteDaemonClient.swift`
- Modify: `ios/Sources/Terminal/TerminalRemoteDaemonBootstrap.swift`
- Test: `ios/cmuxTests/TerminalRemoteDaemonClientTests.swift`
- Test: `ios/cmuxTests/TerminalRemoteDaemonBootstrapTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
func testHelloResponseParsesCapabilities() throws {
    let line = #"{"id":1,"ok":true,"result":{"name":"cmuxd-remote","version":"dev","capabilities":["session.basic","session.resize.min","proxy.stream"]}}"#
    let response = try TerminalRemoteDaemonClient.decodeHello(from: line)
    XCTAssertEqual(response.name, "cmuxd-remote")
    XCTAssertTrue(response.capabilities.contains("session.basic"))
}

func testUploadScriptEncodesBundledBinaryWithoutScp() throws {
    let script = try TerminalRemoteDaemonBootstrap.installScript(
        remotePath: "~/.cmux/bin/cmuxd-remote/dev/linux-arm64/cmuxd-remote",
        base64Payload: "QUJD"
    )
    XCTAssertTrue(script.contains("base64"))
    XCTAssertTrue(script.contains("chmod 755"))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo/ios
xcodegen generate
xcodebuild test -project cmux.xcodeproj -scheme cmux -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:cmuxTests/TerminalRemoteDaemonClientTests -only-testing:cmuxTests/TerminalRemoteDaemonBootstrapTests
```

Expected: FAIL with missing RPC client and bootstrap script helpers.

- [ ] **Step 3: Write the minimal implementation**

```swift
struct TerminalRemoteDaemonHello: Decodable, Equatable {
    let name: String
    let version: String
    let capabilities: [String]
}

final class TerminalRemoteDaemonClient {
    func sendHello() async throws -> TerminalRemoteDaemonHello { ... }
    func sessionOpen(cols: Int, rows: Int) async throws -> String { ... }
    func sessionResize(sessionID: String, attachmentID: String, cols: Int, rows: Int) async throws { ... }
    func sessionClose(sessionID: String, attachmentID: String) async throws { ... }
}
```

Implementation notes:
- Reuse `cmuxd-remote` line-delimited JSON-RPC framing from the Go daemon.
- Use SSH-executed shell scripts for:
  - remote platform probe via `uname -s` / `uname -m`
  - binary install via base64 chunk write + `chmod` + atomic move
  - daemon launch via `serve --stdio`
- Do **not** add SFTP or a custom Go build path in iOS.

- [ ] **Step 4: Run test to verify it passes**

Run the same `xcodebuild test` command.

Expected: PASS for RPC parsing and bootstrap-script tests.

- [ ] **Step 5: Commit**

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo
git add ios/Sources/Terminal/TerminalRemoteDaemonModels.swift ios/Sources/Terminal/TerminalRemoteDaemonClient.swift ios/Sources/Terminal/TerminalRemoteDaemonBootstrap.swift ios/cmuxTests/TerminalRemoteDaemonClientTests.swift ios/cmuxTests/TerminalRemoteDaemonBootstrapTests.swift
git commit -m "feat: add iOS cmuxd-remote bootstrap and rpc client"
```

### Task 6: Prefer daemon-backed sessions, keep raw SSH fallback

**Files:**
- Create: `ios/Sources/Terminal/TerminalRemoteDaemonTransport.swift`
- Modify: `ios/Sources/Terminal/TerminalSSHTransport.swift`
- Modify: `ios/Sources/Terminal/TerminalSidebarStore.swift`
- Test: `ios/cmuxTests/TerminalSidebarStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
@MainActor
func testRemoteDaemonHostUsesDaemonTransportFactory() throws {
    let fixture = makeStore()
    let host = TerminalHost(... stableID: "cmux-macmini", transportPreference: .remoteDaemon, source: .discovered, ...)
    fixture.store.applyDiscoveredHosts([host])
    fixture.credentialsStore.setPassword("secret", for: fixture.store.hosts[0].id)

    let controller = fixture.store.controller(for: fixture.store.startWorkspaceObject(on: fixture.store.hosts[0]))

    XCTAssertEqual((controller.transportDebugName), "remote-daemon")
}

@MainActor
func testDaemonBootstrapFailureFallsBackToRawShellWhenAllowed() throws {
    ...
    XCTAssertEqual(controller.phase, .connecting)
    XCTAssertEqual(controller.transportDebugName, "raw-ssh")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo/ios
xcodegen generate
xcodebuild test -project cmux.xcodeproj -scheme cmux -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:cmuxTests/TerminalSidebarStoreTests
```

Expected: FAIL because transport selection and fallback policy do not exist yet.

- [ ] **Step 3: Write the minimal implementation**

```swift
protocol TerminalTransportFactory {
    func makeTransport(host: TerminalHost, password: String, sessionName: String) -> TerminalTransport
}

struct DefaultTerminalTransportFactory: TerminalTransportFactory {
    func makeTransport(host: TerminalHost, password: String, sessionName: String) -> TerminalTransport {
        switch host.transportPreference {
        case .remoteDaemon:
            return TerminalRemoteDaemonTransport(host: host, password: password, sessionName: sessionName)
        case .rawSSH:
            return TerminalSSHTransport(host: host, password: password, sessionName: sessionName)
        }
    }
}
```

Fallback policy:
- discovered `cmuxd-remote` hosts prefer daemon transport
- daemon bootstrap errors that indicate unsupported remote platform or missing bundled binary fall back to raw SSH
- host key mismatch and auth failures do **not** silently fall back

- [ ] **Step 4: Run test to verify it passes**

Run the same `xcodebuild test` command.

Expected: PASS for updated store/controller tests.

- [ ] **Step 5: Commit**

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo
git add ios/Sources/Terminal/TerminalRemoteDaemonTransport.swift ios/Sources/Terminal/TerminalSSHTransport.swift ios/Sources/Terminal/TerminalSidebarStore.swift ios/cmuxTests/TerminalSidebarStoreTests.swift
git commit -m "feat: prefer daemon-backed iOS terminal sessions"
```

## Chunk 3: Product Finish and Verification

### Task 7: Update copy, living spec, and manual validation hooks

**Files:**
- Modify: `ios/Resources/Localizable.xcstrings`
- Modify: `ios/docs/terminal-sidebar-living-spec.md`
- Modify: `ios/Sources/Terminal/TerminalSidebarRootView.swift`

- [ ] **Step 1: Write the failing test or assertion**

If a UI test from Task 3 already covers copy exposure, extend it to assert the new header/footer strings. Do not add source-shape tests against `.xcstrings`.

- [ ] **Step 2: Run test to verify it fails**

Run the relevant UI test from Task 3 if string assertions were added.

- [ ] **Step 3: Write the minimal implementation**

Update:
- English and Japanese localized strings for discovery states, daemon errors, and fallback states
- `ios/docs/terminal-sidebar-living-spec.md` milestone status:
  - discovery source
  - auto-persisted launch path
  - daemon-backed transport status
- any visible status banner copy for fallback / setup

- [ ] **Step 4: Run test to verify it passes**

Re-run the targeted UI tests and unit tests touched in Tasks 1-6.

- [ ] **Step 5: Commit**

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo
git add ios/Resources/Localizable.xcstrings ios/docs/terminal-sidebar-living-spec.md ios/Sources/Terminal/TerminalSidebarRootView.swift
git commit -m "docs: update iOS terminal discovery and daemon status"
```

### Task 8: End-to-end verification on simulator and device

**Files:**
- Test: existing iOS app and test targets only

- [ ] **Step 1: Run the focused unit and UI suites**

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo/ios
xcodegen generate
xcodebuild test -project cmux.xcodeproj -scheme cmux -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:cmuxTests/TerminalServerCatalogTests \
  -only-testing:cmuxTests/TerminalServerDiscoveryTests \
  -only-testing:cmuxTests/TerminalRemoteDaemonBootstrapTests \
  -only-testing:cmuxTests/TerminalRemoteDaemonClientTests \
  -only-testing:cmuxTests/TerminalSidebarStoreTests \
  -only-testing:cmuxUITests/TerminalSidebarDiscoveryUITests
```

Expected: PASS.

- [ ] **Step 2: Reload the app for manual testing**

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo/ios
./scripts/reload.sh
```

Expected: simulator reload always succeeds; iPhone reload succeeds if the device is available.

- [ ] **Step 3: Perform manual verification**

Manual checks:
1. Sign in and confirm the top server row auto-populates without manual server entry.
2. Tap one discovered server and confirm a new persisted workspace appears immediately.
3. Kill and relaunch the app, confirm the workspace still exists and reconnects.
4. Select a second discovered server and confirm it creates a second persisted workspace instead of overwriting the first.
5. Verify host key capture/update works for first connect.
6. On a server marked `cmuxd-remote`, verify daemon-backed connect or explicit fallback banner.

- [ ] **Step 4: Capture real gaps instead of fake follow-up tests**

If daemon bootstrap still has unsupported-platform gaps, document them in `ios/docs/terminal-sidebar-living-spec.md` instead of adding source-shape assertions.

- [ ] **Step 5: Commit**

```bash
cd /Users/lawrence/fun/cmuxterm-hq/worktrees/task-move-ios-app-into-cmux-repo
git add ios/docs/terminal-sidebar-living-spec.md
git commit -m "test: verify iOS discovered terminal server flow"
```

## Notes for the Implementer

1. The current top-pin tap path already calls `startWorkspace(on:)` and persists the workspace. Keep that behavior and move the work into discovery + transport, not a new home-screen flow.
2. The current iOS raw SSH transport already supports:
   - password auth
   - host key capture
   - shell session creation
   - resize and output streaming
3. The missing pieces for the desired flow are:
   - automatic host discovery
   - stable discovered-host identity
   - daemon-backed session reuse
   - explicit fallback behavior
4. `cmuxd-remote` reuse should focus on:
   - `hello`
   - `session.open`
   - `session.attach`
   - `session.resize`
   - `session.detach`
   - `session.close`
5. Do not expand into browser proxying or full CLI relay in the first iOS pass. That is separate scope from “top pins create persisted terminals.”

Plan complete and saved to `docs/superpowers/plans/2026-03-15-ios-auto-detected-cmux-servers.md`. Ready to execute?
