import UserNotifications
import XCTest
@testable import cmux_DEV

@MainActor
final class NotificationManagerTests: XCTestCase {
    func testSyncsDeviceTokenToServer() async throws {
        let pushSyncer = StubNotificationPushSyncer()
        pushSyncer.isAuthenticated = true
        let tokenStore = InMemoryNotificationTokenStore()
        let routeStore = NotificationRouteStore()
        let system = StubNotificationSystem()
        system.status = .authorized
        let deviceInfo = StubNotificationDeviceInfo(
            bundleIdentifier: "dev.cmux.app.dev",
            vendorIdentifier: "device-123"
        )
        let manager = NotificationManager(
            pushSyncer: pushSyncer,
            tokenStore: tokenStore,
            routeStore: routeStore,
            system: system,
            deviceInfo: deviceInfo,
            observeDidBecomeActive: false
        )

        manager.handleDeviceToken(Data([0xde, 0xad, 0xbe, 0xef]))

        try await waitForCondition {
            pushSyncer.upsertCalls.count == 1
        }

        let call = try XCTUnwrap(pushSyncer.upsertCalls.first)
        XCTAssertEqual(tokenStore.load(), "deadbeef")
        XCTAssertEqual(call.token, "deadbeef")
        XCTAssertEqual(call.bundleId, "dev.cmux.app.dev")
        XCTAssertEqual(call.deviceId, "device-123")
        XCTAssertEqual(call.platform, "ios")
        XCTAssertEqual(call.environment, .development)
        XCTAssertTrue(system.didRegisterForRemoteNotifications)
    }

    func testNotificationRouteStoresWorkspacePayload() {
        let manager = NotificationManager(
            pushSyncer: StubNotificationPushSyncer(),
            tokenStore: InMemoryNotificationTokenStore(),
            routeStore: NotificationRouteStore(),
            system: StubNotificationSystem(),
            deviceInfo: StubNotificationDeviceInfo(
                bundleIdentifier: "dev.cmux.app.dev",
                vendorIdentifier: "device-123"
            ),
            observeDidBecomeActive: false
        )

        manager.handleNotificationUserInfo([
            "route": [
                "kind": "workspace",
                "workspaceId": "workspace_123",
                "machineId": "machine_123",
            ],
        ])

        XCTAssertEqual(
            manager.pendingRouteForTesting,
            NotificationRoute(
                kind: .workspace,
                workspaceID: "workspace_123",
                machineID: "machine_123"
            )
        )
    }

    func testLaunchPolicyCanSkipPermissionPrompt() async {
        let system = StubNotificationSystem()
        let manager = NotificationManager(
            pushSyncer: StubNotificationPushSyncer(),
            tokenStore: InMemoryNotificationTokenStore(),
            routeStore: NotificationRouteStore(),
            system: system,
            deviceInfo: StubNotificationDeviceInfo(
                bundleIdentifier: "dev.cmux.app.dev.sim",
                vendorIdentifier: "device-123"
            ),
            permissionRequestPolicy: StubNotificationPermissionRequestPolicy(allowedTriggers: [.settings]),
            observeDidBecomeActive: false
        )

        await manager.requestAuthorizationIfNeeded(trigger: .launch)

        XCTAssertEqual(system.requestAuthorizationCallCount, 0)
        XCTAssertFalse(system.didRegisterForRemoteNotifications)
        XCTAssertEqual(manager.authorizationStatus, .notDetermined)
    }

    func testSettingsTriggerStillRequestsPermissionWhenPolicyAllowsIt() async {
        let system = StubNotificationSystem()
        let manager = NotificationManager(
            pushSyncer: StubNotificationPushSyncer(),
            tokenStore: InMemoryNotificationTokenStore(),
            routeStore: NotificationRouteStore(),
            system: system,
            deviceInfo: StubNotificationDeviceInfo(
                bundleIdentifier: "dev.cmux.app.dev.sim",
                vendorIdentifier: "device-123"
            ),
            permissionRequestPolicy: StubNotificationPermissionRequestPolicy(allowedTriggers: [.settings]),
            observeDidBecomeActive: false
        )

        await manager.requestAuthorizationIfNeeded(trigger: .settings)

        XCTAssertEqual(system.requestAuthorizationCallCount, 1)
        XCTAssertTrue(system.didRegisterForRemoteNotifications)
        XCTAssertEqual(manager.authorizationStatus, .authorized)
    }

    func testLivePolicySkipsLaunchPromptOnSimulator() {
        let policy = LiveNotificationPermissionRequestPolicy(runsOnSimulator: true)

        XCTAssertFalse(policy.shouldRequestAuthorization(trigger: .launch))
        XCTAssertTrue(policy.shouldRequestAuthorization(trigger: .settings))
    }

    func testLivePolicyKeepsLaunchPromptOnDeviceBuilds() {
        let policy = LiveNotificationPermissionRequestPolicy(runsOnSimulator: false)

        XCTAssertTrue(policy.shouldRequestAuthorization(trigger: .launch))
        XCTAssertTrue(policy.shouldRequestAuthorization(trigger: .settings))
    }
}

@MainActor
private final class StubNotificationPushSyncer: NotificationPushSyncing {
    struct UpsertCall: Equatable {
        let token: String
        let environment: MobilePushEnvironment
        let platform: String
        let bundleId: String
        let deviceId: String?
    }

    var isAuthenticated = false
    private(set) var sendTestCalls: [(title: String, body: String)] = []
    private(set) var upsertCalls: [UpsertCall] = []
    private(set) var removedTokens: [String] = []

    func sendTestPush(title: String, body: String) async throws {
        sendTestCalls.append((title, body))
    }

    func upsertPushToken(
        token: String,
        environment: MobilePushEnvironment,
        platform: String,
        bundleId: String,
        deviceId: String?
    ) async throws {
        upsertCalls.append(
            UpsertCall(
                token: token,
                environment: environment,
                platform: platform,
                bundleId: bundleId,
                deviceId: deviceId
            )
        )
    }

    func removePushToken(token: String) async throws {
        removedTokens.append(token)
    }
}

private final class InMemoryNotificationTokenStore: NotificationTokenStoring {
    private var token: String?

    func load() -> String? {
        token
    }

    func save(_ token: String) {
        self.token = token
    }

    func clear() {
        token = nil
    }
}

@MainActor
private final class StubNotificationSystem: NotificationSystemHandling {
    var status: UNAuthorizationStatus = .notDetermined
    var requestAuthorizationResult = true
    var requestAuthorizationCallCount = 0
    var didRegisterForRemoteNotifications = false
    var didOpenSettings = false

    func authorizationStatus() async -> UNAuthorizationStatus {
        status
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        requestAuthorizationCallCount += 1
        status = requestAuthorizationResult ? .authorized : .denied
        return requestAuthorizationResult
    }

    var isRegisteredForRemoteNotifications: Bool {
        didRegisterForRemoteNotifications
    }

    func registerForRemoteNotifications() {
        didRegisterForRemoteNotifications = true
    }

    func openSettings() {
        didOpenSettings = true
    }
}

@MainActor
private struct StubNotificationDeviceInfo: NotificationDeviceInfoProviding {
    let bundleIdentifier: String?
    let vendorIdentifier: String?
}

private struct StubNotificationPermissionRequestPolicy: NotificationPermissionRequestPolicy {
    let allowedTriggers: Set<NotificationRequestTrigger>

    func shouldRequestAuthorization(trigger: NotificationRequestTrigger) -> Bool {
        allowedTriggers.contains(trigger)
    }
}

@MainActor
private func waitForCondition(
    timeout: Duration = .seconds(1),
    pollInterval: Duration = .milliseconds(10),
    _ condition: @escaping @MainActor () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() {
            return
        }
        try await Task.sleep(for: pollInterval)
    }
    XCTFail("Timed out waiting for condition.")
}
