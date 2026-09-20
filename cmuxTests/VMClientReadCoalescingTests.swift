import CMUXAuthCore
import CmuxAuthRuntime
import Foundation
import Testing
import os

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Cloud read request ownership", .serialized)
struct VMClientReadCoalescingTests {
    @Test("Overlapping machine stats callers share one HTTP request")
    func statsReadersShareTransport() async throws {
        let fixture = try await CloudRefreshFixture.make()
        defer { fixture.session.invalidateAndCancel() }
        await CloudRefreshURLProtocol.reset()
        await CloudRefreshURLProtocol.holdResponses()
        let requests = Task {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<4 {
                    for machine in 0..<10 {
                        group.addTask { _ = try? await fixture.client.stats(id: "fixture-\(machine)") }
                    }
                }
            }
        }
        try await eventually { await fixture.readRequests.entries.values.reduce(0) { $0 + $1.waiters.count } == 40 }
        await CloudRefreshURLProtocol.releaseResponses()
        await requests.value
        let counts = await CloudRefreshURLProtocol.requestCounts()
        #expect(counts.count == 10)
        #expect(counts.values.allSatisfy { $0 == 1 }, "Four owners must share one read per machine: \(counts.values.sorted())")
    }

    @Test("Overlapping machine list callers share one HTTP request")
    func listReadersShareTransport() async throws {
        let fixture = try await CloudRefreshFixture.make()
        defer { fixture.session.invalidateAndCancel() }
        await CloudRefreshURLProtocol.reset()
        await CloudRefreshURLProtocol.holdResponses()
        let requests = Task {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<4 { group.addTask { _ = try? await fixture.client.listPage() } }
            }
        }
        try await eventually { await fixture.readRequests.entries.values.first?.waiters.count == 4 }
        await CloudRefreshURLProtocol.releaseResponses()
        await requests.value
        let counts = await CloudRefreshURLProtocol.requestCounts()
        #expect(counts.values.reduce(0, +) == 1)
    }
    @Test("A hidden panel cancels its list and cannot start stats from a late result")
    func hiddenPanelCancelsFollowupWork() async throws {
        let fixture = try await CloudRefreshFixture.make()
        defer { fixture.session.invalidateAndCancel() }
        await CloudRefreshURLProtocol.reset()
        await CloudRefreshURLProtocol.holdResponses()
        let model = MachinesPanelViewModel(client: fixture.client, isCloudEnabled: { true })
        model.startPolling()
        await CloudRefreshURLProtocol.waitUntilStarted()
        model.beginOperation("fixture operation")
        model.stopPolling()
        model.endOperation()
        await CloudRefreshURLProtocol.waitUntilStopped()
        #expect(!model.isLoading)
        #expect(model.machines.isEmpty)
        NotificationCenter.default.post(name: .cmuxCloudReadNetworkChanged, object: nil, userInfo: ["isOnline": true])
        #expect(await CloudRefreshURLProtocol.requestCounts().values.reduce(0, +) == 1)
    }

    @Test("Dropping a view model releases it and cancels its pending list")
    func viewModelTeardown() async throws {
        let fixture = try await CloudRefreshFixture.make()
        defer { fixture.session.invalidateAndCancel() }
        await CloudRefreshURLProtocol.reset()
        await CloudRefreshURLProtocol.holdResponses()
        var model: MachinesPanelViewModel? = MachinesPanelViewModel(client: fixture.client, isCloudEnabled: { true })
        weak var weakModel: MachinesPanelViewModel?
        weakModel = model
        model?.refresh()
        await CloudRefreshURLProtocol.waitUntilStarted()
        model = nil
        #expect(weakModel == nil)
        await CloudRefreshURLProtocol.waitUntilStopped()
    }

    @Test("A failed stats sample clears the last live reading")
    func failedStatsAreUnavailable() async throws {
        let fixture = try await CloudRefreshFixture.make()
        defer { fixture.session.invalidateAndCancel() }
        await CloudRefreshURLProtocol.reset()
        let model = MachinesPanelViewModel(client: fixture.client, isCloudEnabled: { true })
        defer { model.stopPolling() }
        model.refresh()
        try await eventually { model.machines.first?.stats?.state == .awake }
        await CloudRefreshURLProtocol.configure(.statsUnavailable)
        model.refresh()
        try await eventually { !model.isLoading && model.machines.first?.stats?.state == .unknown }
        #expect(model.machines.count == 1)
        #expect(model.listProblem == nil)
        #expect(model.machines.first?.stats?.cpus == 2)
        #expect(model.machines.first?.stats?.cpuPercent == nil)
        #expect(model.machines.first?.stats?.memoryUsedMb == nil)
        #expect(model.machines.first?.stats?.diskUsedMb == nil)
    }

    @Test("Known offline state clears live samples without waiting for the next poll")
    func offlinePresentation() async throws {
        let fixture = try await CloudRefreshFixture.make()
        defer { fixture.session.invalidateAndCancel() }
        await CloudRefreshURLProtocol.reset()
        let model = MachinesPanelViewModel(client: fixture.client, isCloudEnabled: { true })
        defer { model.stopPolling() }
        model.refresh()
        try await eventually { model.machines.first?.stats?.state == .awake }
        NotificationCenter.default.post(name: .cmuxCloudReadNetworkChanged, object: nil, userInfo: ["isOnline": false])
        #expect(model.machines.first?.stats?.state == .unknown)
        #expect(model.machines.first?.stats?.cpus == 2)
        #expect(model.machines.first?.stats?.cpuPercent == nil)
        #expect(model.listProblem == .unreachable)
        #expect(model.lastErrorDescription == URLError(.notConnectedToInternet).localizedDescription)
    }

    @Test("The VM operation budget cancels a slow transport")
    func totalRequestBudget() async throws {
        let clock = CloudReadManualClock()
        let reads = CloudReadRequestCoordinator(clock: CloudRequestClock(clock), budget: .milliseconds(100))
        let fixture = try await CloudRefreshFixture.make(readRequests: reads)
        defer { fixture.session.invalidateAndCancel() }
        await CloudRefreshURLProtocol.reset()
        await CloudRefreshURLProtocol.holdResponses()
        let request = Task { try await fixture.client.stats(id: "fixture-0") }
        await CloudRefreshURLProtocol.waitUntilStarted()
        clock.advance(by: .milliseconds(101))
        do { _ = try await request.value; Issue.record("request exceeded its total budget") }
        catch { #expect((error as? URLError)?.code == .timedOut) }
        await CloudRefreshURLProtocol.waitUntilStopped()
        await CloudRefreshURLProtocol.releaseResponses()
    }

    @Test("HTTP Retry-After exceeds the budget without an early automatic retry")
    func retryAfterAcrossCalls() async throws {
        let clock = CloudReadManualClock()
        let reads = CloudReadRequestCoordinator(clock: CloudRequestClock(clock))
        let fixture = try await CloudRefreshFixture.make(readRequests: reads)
        defer { fixture.session.invalidateAndCancel() }
        await CloudRefreshURLProtocol.reset()
        await CloudRefreshURLProtocol.configure(.throttled)
        for _ in 0..<2 {
            do { _ = try await fixture.client.stats(id: "fixture-0"); Issue.record("throttle succeeded") }
            catch VMClientError.httpStatus(429, _) {} catch { Issue.record("\(error)") }
        }
        #expect(await CloudRefreshURLProtocol.requestCounts().values.reduce(0, +) == 1)
        await CloudRefreshURLProtocol.configure(.normal)
        clock.advance(by: .seconds(60))
        #expect(try await fixture.client.stats(id: "fixture-0").state == .awake)
        #expect(await CloudRefreshURLProtocol.requestCounts().values.reduce(0, +) == 2)
    }

    @Test("Disabled Cloud rejects cached throttles before reuse", arguments: ["/api/vm", "/api/vm/fixture-0/stats"], [false, true])
    func gateClosesDuringCooldown(path: String, managedPolicy: Bool) async throws {
        // Injected flags are synchronous across actors; this lock protects only test state.
        let blocked = OSAllocatedUnfairLock(initialState: false)
        let fixture = try await CloudRefreshFixture.make(
            isDisabledByManagedPolicy: { managedPolicy && blocked.withLock { $0 } },
            isCloudEnabled: { managedPolicy || !blocked.withLock { $0 } }
        )
        defer { fixture.session.invalidateAndCancel() }
        await CloudRefreshURLProtocol.reset()
        await CloudRefreshURLProtocol.configure(.throttled)
        let first = try await fixture.client.request("GET", path: path)
        #expect(first.1.statusCode == 429)
        blocked.withLock { $0 = true }
        do {
            _ = try await fixture.client.request("GET", path: path)
            Issue.record("Disabled Cloud reused a cached response")
        } catch VMClientError.disabledByManagedPolicy where managedPolicy {
        } catch VMClientError.cloudMachinesDisabled where !managedPolicy {
        } catch { Issue.record("Unexpected gate error: \(error)") }
        #expect(await CloudRefreshURLProtocol.requestCounts().values.reduce(0, +) == 1)
    }

    @Test("A joined read cannot publish after its Cloud gate closes", arguments: ["/api/vm", "/api/vm/fixture-0/stats"], [false, true])
    func gateClosesDuringJoinedRead(path: String, managedPolicy: Bool) async throws {
        // Injected flags are synchronous across actors; this lock protects only test state.
        let blocked = OSAllocatedUnfairLock(initialState: false)
        let fixture = try await CloudRefreshFixture.make(
            isDisabledByManagedPolicy: { managedPolicy && blocked.withLock { $0 } },
            isCloudEnabled: { managedPolicy || !blocked.withLock { $0 } }
        )
        defer { fixture.session.invalidateAndCancel() }
        await CloudRefreshURLProtocol.reset()
        let identity = try #require(fixture.auth.authenticatedSessionIdentity)
        let key = CloudReadRequestCoordinator.Key(path: path, accountID: identity.accountID,
            generation: identity.generation, teamID: fixture.auth.resolvedTeamID)
        let gate = CloudReadResponseGate()
        // Hold an already-admitted response at the shared owner boundary, after
        // its transport's gate check, so the joining caller must enforce its own gate.
        let existing = Task { try await fixture.readRequests.read(key) {
            await gate.read(.init(data: Data(), http: HTTPURLResponse(
                url: URL(string: "https://fixture.invalid")!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!))
        } }
        try await eventually { await gate.requests == 1 }
        let joined = Task { try await fixture.client.request("GET", path: path) }
        try await eventually { await fixture.readRequests.entries[key]?.waiters.count == 2 }
        blocked.withLock { $0 = true }
        await gate.release()
        _ = try await existing.value
        do {
            _ = try await joined.value
            Issue.record("Disabled Cloud published an in-flight response")
        } catch VMClientError.disabledByManagedPolicy where managedPolicy {
        } catch VMClientError.cloudMachinesDisabled where !managedPolicy {
        } catch { Issue.record("Unexpected gate error: \(error)") }
        #expect(await CloudRefreshURLProtocol.requestCounts().isEmpty)
    }

    @Test("Cloud access revocation remains available with both gates closed")
    func revocationBypassesClosedGates() async throws {
        let fixture = try await CloudRefreshFixture.make(isDisabledByManagedPolicy: { true }, isCloudEnabled: { false })
        defer { fixture.session.invalidateAndCancel() }
        await CloudRefreshURLProtocol.reset()
        try await fixture.client.revokeCloudAccess(deviceID: "fixture-device")
        #expect(await CloudRefreshURLProtocol.requestCounts() == ["/api/vm/tunnel": 1])
    }

    @Test("A list delayed beyond a polling interval stays owned and stops when hidden")
    func delayedListAcrossPoll() async throws {
        let clock = CloudReadManualClock()
        let reads = CloudReadRequestCoordinator(clock: CloudRequestClock(clock), budget: .seconds(90))
        let fixture = try await CloudRefreshFixture.make(readRequests: reads)
        defer { fixture.session.invalidateAndCancel() }
        await CloudRefreshURLProtocol.reset()
        await CloudRefreshURLProtocol.holdResponses()
        let model = MachinesPanelViewModel(client: fixture.client, pollingClock: clock, isCloudEnabled: { true })
        model.startPolling()
        await CloudRefreshURLProtocol.waitUntilStarted()
        try await eventually { clock.pendingSleeperCount == 2 }
        clock.advance(by: .seconds(45))
        try await eventually { clock.pendingSleeperCount == 2 }
        #expect(await CloudRefreshURLProtocol.requestCounts().values.reduce(0, +) == 1)
        model.stopPolling()
        await CloudRefreshURLProtocol.waitUntilStopped()
        await CloudRefreshURLProtocol.releaseResponses()
        #expect(!model.isLoading)
        #expect(model.machines.isEmpty)
    }

    @Test("Visible and hidden panels share the same machines without hidden follow-up work")
    func visibleAndHiddenOwners() async throws {
        let fixture = try await CloudRefreshFixture.make()
        defer { fixture.session.invalidateAndCancel() }
        await CloudRefreshURLProtocol.reset()
        await CloudRefreshURLProtocol.holdResponses()
        let models = (0..<4).map { _ in MachinesPanelViewModel(client: fixture.client, isCloudEnabled: { true }) }
        defer { for model in models { model.stopPolling() } }
        for model in models { model.startPolling() }
        models[2].stopPolling()
        models[3].stopPolling()
        try await eventually { await fixture.readRequests.entries.values.first?.waiters.count == 2 }
        await CloudRefreshURLProtocol.releaseResponses()
        try await eventually { models[0].machines.first?.stats != nil && models[1].machines.first?.stats != nil }
        let counts = await CloudRefreshURLProtocol.requestCounts()
        #expect(counts["/api/vm"] == 1)
        #expect(counts["/api/vm/fixture-0/stats"] == 1)
        #expect(models[2].machines.isEmpty && models[3].machines.isEmpty)
    }

    @Test("Team usage shares offline state with list and stats while keeping its shorter budget")
    func teamUsageNetworkState() async throws {
        let clock = CloudReadManualClock()
        let reads = CloudReadRequestCoordinator(clock: CloudRequestClock(clock))
        let fixture = try await CloudRefreshFixture.make(readRequests: reads)
        defer { fixture.session.invalidateAndCancel() }
        await CloudRefreshURLProtocol.reset()
        await CloudRefreshURLProtocol.holdResponses()
        let usage = MachineUsageClient(session: fixture.session, auth: fixture.auth, readRequests: reads)
        let request = Task { try await usage.teamUsage() }
        await CloudRefreshURLProtocol.waitUntilStarted()
        await reads.networkChanged(isOnline: false)
        do { _ = try await request.value; Issue.record("usage survived offline") }
        catch { #expect((error as? URLError)?.code == .notConnectedToInternet) }
        await CloudRefreshURLProtocol.waitUntilStopped()
        do { _ = try await usage.teamUsage(); Issue.record("usage started offline") }
        catch { #expect((error as? URLError)?.code == .notConnectedToInternet) }
        #expect(await CloudRefreshURLProtocol.requestCounts().values.reduce(0, +) == 1)
        await reads.networkChanged(isOnline: true)
        let recovery = Task { try await usage.teamUsage() }
        await CloudRefreshURLProtocol.waitUntilStarted(2)
        clock.advance(by: .seconds(16))
        do { _ = try await recovery.value; Issue.record("usage exceeded its 15 second budget") }
        catch { #expect((error as? URLError)?.code == .timedOut) }
        await CloudRefreshURLProtocol.releaseResponses()
    }

    @Test("Successful resize invalidates only its authenticated list and machine stats")
    func mutationInvalidationUsesRequestScope() async throws {
        let fixture = try await CloudRefreshFixture.make()
        defer { fixture.session.invalidateAndCancel() }
        await CloudRefreshURLProtocol.reset()
        let identity = try #require(fixture.auth.authenticatedSessionIdentity)
        let paths = ["/api/vm", "/api/vm/fixture-0/stats", "/api/vm/fixture-1/stats"]
        let gates = paths.map { _ in CloudReadResponseGate() }
        let requests = zip(paths, gates).map { path, gate in
            let key = CloudReadRequestCoordinator.Key(path: path, accountID: identity.accountID,
                generation: identity.generation, teamID: fixture.auth.resolvedTeamID)
            return Task { try await fixture.readRequests.read(key) {
                let status = await gate.requests == 0 ? 200 : 201
                return await gate.read(.init(data: Data(), http: HTTPURLResponse(
                    url: URL(string: "https://fixture.invalid")!, statusCode: status, httpVersion: nil, headerFields: nil
                )!))
            } }
        }
        for gate in gates { try await eventually { await gate.requests == 1 } }
        _ = try await fixture.client.request("POST", path: "/api/vm/fixture-0/resize", jsonBody: ["cpu": 4])
        for gate in gates { await gate.release() }
        for (index, request) in requests.enumerated() {
            #expect(try await request.value.http.statusCode == (index < 2 ? 201 : 200))
            #expect(await gates[index].requests == (index < 2 ? 2 : 1))
        }
    }

    private func eventually(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !(await condition()), ContinuousClock.now < deadline { await Task.yield() }
        try #require(await condition())
    }

}

@MainActor
struct CloudRefreshFixture {
    let client: VMClient
    let auth: AuthCoordinator
    let session: URLSession
    let readRequests: CloudReadRequestCoordinator

    static func make(
        readRequests: CloudReadRequestCoordinator = CloudReadRequestCoordinator(),
        isDisabledByManagedPolicy: (@Sendable () -> Bool)? = nil,
        isCloudEnabled: @escaping @Sendable () -> Bool = { true }
    ) async throws -> Self {
        let defaults = try #require(UserDefaults(suiteName: "CloudRefreshFixture.\(UUID())"))
        let auth = AuthCoordinator(
            client: CloudRefreshAuthClient(),
            sessionCache: CMUXAuthSessionCache(keyValueStore: defaults, key: "session"),
            userCache: CMUXAuthIdentityStore(keyValueStore: defaults, key: "user"),
            teamSelection: CMUXAuthTeamSelectionStore(keyValueStore: defaults, key: "team"),
            anchor: AuthPresentationContextProvider(),
            config: AuthConfig(
                stack: CMUXAuthConfig(projectId: "fixture", publishableClientKey: "fixture"),
                magicLinkCallbackURL: "http://127.0.0.1:1/callback", apiBaseURL: "http://127.0.0.1:1"
            ),
            launch: AuthLaunchOptions(
                clearAuthRequested: false, mockDataEnabled: false,
                environment: ["CMUX_UITEST_AUTH_FIXTURE": "1", "CMUX_UITEST_AUTH_USER_ID": "fixture"],
                includesDevAuth: true
            )
        )
        auth.start()
        await auth.awaitBootstrapped()
        try #require(auth.isAuthenticated)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudRefreshURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return Self(client: VMClient(
            session: session, auth: auth, resourceStats: VMResourceStatsStore(), checkpointRenames: CloudRenameCoordinator(),
            machineCache: CloudMachineCache(defaults: defaults), isDisabledByManagedPolicy: isDisabledByManagedPolicy,
            readRequests: readRequests, isCloudEnabled: isCloudEnabled
        ), auth: auth, session: session, readRequests: readRequests)
    }
}

private actor CloudRefreshAuthClient: AuthClient {
    func accessToken() async -> String? { "fixture-access" }
    func refreshToken() async -> String? { "fixture-refresh" }
    func forceRefreshAccessToken() async -> String? { "fixture-access" }
    func currentUser(throwOnMissing: Bool) async throws -> CMUXAuthUser? {
        CMUXAuthUser(id: "fixture", primaryEmail: "fixture@example.test", displayName: "Fixture")
    }
    func listTeams() async throws -> [CMUXAuthTeam] { [] }
    func sendMagicLinkEmail(email: String, callbackURL: String) async throws -> String { "fixture" }
    func signInWithMagicLink(code: String) async throws {}
    func signInWithCredential(email: String, password: String) async throws {}
    func signInWithOAuth(provider: String, anchor: any AuthPresentationAnchoring) async throws {}
    func storedAccessToken() async -> String? { "fixture-access" }
    func clearLocalSession() async {}
    func clearLocalSession(ifRefreshTokenMatches refreshToken: String) async {}
    func revokeSession(accessToken: String?, refreshToken: String?) async throws {}
    func freshAccessToken(accessToken: String?, refreshToken: String) async -> String? { accessToken }
}
