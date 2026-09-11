import CMUXAuthCore
import CmuxAuthRuntime
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior tests for the MDM `DisableCloud` policy at its runtime seams: the
/// transition observer (enforcement at construction for a profile installed
/// before launch, once per mid-session push, and again on the lift) and the
/// Cloud VM service boundary, which must refuse every operation before any
/// network work regardless of which entry point asked, while leaving access
/// revocation reachable for cleanup.
@MainActor
struct ManagedPolicyCloudGateTests {
    // MARK: - Transition observer

    @Test func aProfileForcedBeforeLaunchIsEnforcedAtConstruction() {
        let policy = ManagedPolicyFlag()
        policy.isEnforced = true
        let recorder = EnforcementRecorder()
        let observer = makeObserver(center: NotificationCenter(), policy: policy, recorder: recorder)

        #expect(recorder.cloud == 1)
        #expect(recorder.browser == 0)
        #expect(recorder.remoteControl == 0)

        // Re-evaluating an unchanged state is not a transition.
        observer.reevaluate()
        #expect(recorder.cloud == 1)
        withExtendedLifetime(observer) {}
    }

    @Test func aMidSessionPushEnforcesOnceAndTheLiftRunsEnforcementAgain() {
        let center = NotificationCenter()
        let policy = ManagedPolicyFlag()
        let recorder = EnforcementRecorder()
        let observer = makeObserver(center: center, policy: policy, recorder: recorder)
        let token = center.addObserver(
            forName: ManagedDevicePolicy.didChangeNotification,
            object: nil,
            queue: nil
        ) { _ in recorder.recordChangeSignal() }
        defer { center.removeObserver(token) }
        #expect(recorder.cloud == 0)

        policy.isEnforced = true
        observer.reevaluate()
        #expect(recorder.cloud == 1)
        #expect(recorder.changeSignals == 1)

        observer.reevaluate()
        #expect(recorder.cloud == 1)
        #expect(recorder.changeSignals == 1)

        // The lift is a transition too: the app restarts Cloud discovery and
        // Settings re-reads the resolver.
        policy.isEnforced = false
        observer.reevaluate()
        #expect(recorder.cloud == 2)
        #expect(recorder.changeSignals == 2)
        withExtendedLifetime(observer) {}
    }

    @Test func irohPolicyEnforcesBothTransitionsAndPublishesSettingsChanges() {
        let policy = ManagedPolicyFlag()
        let recorder = EnforcementRecorder()
        let observer = ManagedPolicyEnforcementObserver(
            notificationCenter: NotificationCenter(),
            isBrowserDisabledByPolicy: { false },
            isRemoteControlDisabledByPolicy: { false },
            isCloudDisabledByPolicy: { false },
            isIrohDisabledByPolicy: { policy.isEnforced },
            enforceBrowserPolicy: {},
            enforceBrowserURLAllowlistPolicy: {},
            enforceRemoteControlPolicy: { recorder.recordRemoteControl() }
        )
        policy.isEnforced = true
        observer.reevaluate()
        #expect(recorder.remoteControl == 1)
        observer.reevaluate()
        #expect(recorder.remoteControl == 1)
        policy.isEnforced = false
        observer.reevaluate()
        #expect(recorder.remoteControl == 2)
    }

    // MARK: - Service boundary

    @Test func theCloudServiceRefusesEveryCallBeforeTheNetworkAndKeepsRevocationOpen() async throws {
        let suiteName = "ManagedPolicyCloudGateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let coordinator = makeRestoredSessionCoordinator(defaults: defaults)
        coordinator.start()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingCloudURLProtocol.self]
        RecordingCloudURLProtocol.recorder.reset()
        let policy = ManagedPolicyFlag()
        policy.isEnforced = true
        let client = VMClient(
            session: URLSession(configuration: configuration),
            auth: coordinator,
            isDisabledByManagedPolicy: { policy.isEnforced }
        )

        // Representative operations across the API surface: discovery,
        // creation, SSH, exec, ports, and publications.
        let operations: [(String, () async throws -> Void)] = [
            ("list", { _ = try await client.listPage() }),
            ("create", { _ = try await client.create(idempotencyKey: "policy-test") }),
            ("openSSH", { _ = try await client.openSSH(id: "vm-1") }),
            ("exec", { _ = try await client.exec(id: "vm-1", command: "true") }),
            ("openPort", { _ = try await client.openPort(id: "vm-1", port: 3000) }),
            ("publications", { _ = try await client.listPublications() }),
        ]
        for (name, operation) in operations {
            do {
                try await operation()
                Issue.record("\(name) succeeded under DisableCloud")
            } catch VMClientError.disabledByManagedPolicy {
                // Expected: refused before auth, telemetry, or the network.
            } catch {
                Issue.record("\(name) failed with \(error) instead of the managed-policy refusal")
            }
        }
        #expect(RecordingCloudURLProtocol.recorder.requests.isEmpty)

        // Revocation is the one call allowed through: it ends this Mac's
        // access. It reaches the session check and, with a session, the wire.
        await coordinator.awaitBootstrapped()
        try #require(coordinator.isAuthenticated)
        do {
            try await client.revokeCloudAccess(deviceID: "device-1")
            let recorded = RecordingCloudURLProtocol.recorder.requests
            #expect(recorded.count == 1)
            #expect(recorded.first?.httpMethod == "DELETE")
            #expect(recorded.first?.url?.path.hasSuffix("/api/vm/tunnel") == true)
        } catch VMClientError.disabledByManagedPolicy {
            Issue.record("revocation must stay available under DisableCloud")
        }
    }

    // MARK: - Helpers

    private func makeObserver(
        center: NotificationCenter,
        policy: ManagedPolicyFlag,
        recorder: EnforcementRecorder
    ) -> ManagedPolicyEnforcementObserver {
        ManagedPolicyEnforcementObserver(
            notificationCenter: center,
            isBrowserDisabledByPolicy: { false },
            isRemoteControlDisabledByPolicy: { false },
            isCloudDisabledByPolicy: { policy.isEnforced },
            enforceBrowserPolicy: { recorder.recordBrowser() },
            enforceBrowserURLAllowlistPolicy: {},
            enforceRemoteControlPolicy: { recorder.recordRemoteControl() },
            enforceCloudPolicy: { recorder.recordCloud() }
        )
    }

    private func makeRestoredSessionCoordinator(defaults: UserDefaults) -> AuthCoordinator {
        AuthCoordinator(
            client: ManagedPolicyCloudGateAuthClient(),
            sessionCache: CMUXAuthSessionCache(keyValueStore: defaults, key: "auth-session"),
            userCache: CMUXAuthIdentityStore(keyValueStore: defaults, key: "auth-user"),
            teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: defaults, key: "auth-team"),
            anchor: AuthPresentationContextProvider(),
            config: AuthConfig(
                stack: CMUXAuthConfig(projectId: "project-a", publishableClientKey: "publishable-a"),
                magicLinkCallbackURL: "http://127.0.0.1:1/auth/callback",
                apiBaseURL: "http://127.0.0.1:1"
            ),
            launch: AuthLaunchOptions(
                clearAuthRequested: false,
                mockDataEnabled: false,
                environment: [
                    "CMUX_UITEST_AUTH_FIXTURE": "1",
                    "CMUX_UITEST_AUTH_USER_ID": "managed-policy-account",
                ],
                includesDevAuth: true
            )
        )
    }
}

/// Counts enforcement callbacks and change signals. Lock-protected so the
/// observer's closures and NotificationCenter blocks can all record into it.
private final class EnforcementRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var cloudCount = 0
    private var browserCount = 0
    private var remoteControlCount = 0
    private var changeSignalCount = 0

    var cloud: Int { lock.withLock { cloudCount } }
    var browser: Int { lock.withLock { browserCount } }
    var remoteControl: Int { lock.withLock { remoteControlCount } }
    var changeSignals: Int { lock.withLock { changeSignalCount } }

    func recordCloud() { lock.withLock { cloudCount += 1 } }
    func recordBrowser() { lock.withLock { browserCount += 1 } }
    func recordRemoteControl() { lock.withLock { remoteControlCount += 1 } }
    func recordChangeSignal() { lock.withLock { changeSignalCount += 1 } }
}

/// A managed-policy switch the tests flip mid-scenario, standing in for an
/// MDM profile pushed while the app runs.
private final class ManagedPolicyFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var enforced = false

    var isEnforced: Bool {
        get { lock.withLock { enforced } }
        set { lock.withLock { enforced = newValue } }
    }
}

/// Records every request the Cloud client sends and answers `200 {}`, so a
/// test can prove exactly which calls reach the network under the policy.
private final class RecordingCloudURLProtocol: URLProtocol {
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [URLRequest] = []

        var requests: [URLRequest] { lock.withLock { stored } }
        func record(_ request: URLRequest) { lock.withLock { stored.append(request) } }
        func reset() { lock.withLock { stored.removeAll() } }
    }

    static let recorder = Recorder()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.recorder.record(request)
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private actor ManagedPolicyCloudGateAuthClient: AuthClient {
    func accessToken() async -> String? { "access-token" }
    func refreshToken() async -> String? { "refresh-token" }
    func forceRefreshAccessToken() async -> String? { "access-token" }
    func currentUser(
        throwOnMissing: Bool
    ) async throws -> CMUXAuthCore.CMUXAuthUser? {
        CMUXAuthCore.CMUXAuthUser(
            id: "managed-policy-account",
            primaryEmail: "managed-policy@cmux.test",
            displayName: "Managed Policy Account"
        )
    }
    func listTeams() async throws -> [CMUXAuthCore.CMUXAuthTeam] { [] }
    func sendMagicLinkEmail(email: String, callbackURL: String) async throws -> String {
        "nonce"
    }
    func signInWithMagicLink(code: String) async throws {}
    func signInWithCredential(email: String, password: String) async throws {}
    func signInWithOAuth(
        provider: String,
        anchor: any AuthPresentationAnchoring
    ) async throws {}
    func storedAccessToken() async -> String? { "access-token" }
    func clearLocalSession() async {}
    func clearLocalSession(ifRefreshTokenMatches refreshToken: String) async {}
    func revokeSession(accessToken: String?, refreshToken: String?) async throws {}
    func freshAccessToken(
        accessToken: String?,
        refreshToken: String
    ) async -> String? {
        accessToken
    }
}
