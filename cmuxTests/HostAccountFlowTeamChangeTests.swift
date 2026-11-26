import CMUXAuthCore
import CmuxCloud
import CMUXMobileCore
import CmuxAuthRuntime
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Team changes from every surface (the Cloud picker, Settings and the socket)
/// share the runtime coordinator's exclusion policy. The flow owns only the
/// optimistic projection and preserves it when the coordinator refuses a
/// request from another surface.
///
/// Serialized because the billing stub's response body and hold gate are
/// static, so two plan requests in flight at once would share them.
@MainActor
@Suite("Host account flow team changes", .serialized)
struct HostAccountFlowTeamChangeTests {
    @Test func successfulAuthCallbackRefreshesThePaidEntitlement() async throws {
        let planClient = BillingPlanClient(
            session: BillingPlanCallbackURLProtocol.session(body: """
            {"authenticated":true,"billingAvailable":true,"planId":"pro",
             "subscriptionPlanId":"pro","isPro":true,"billingManagement":"stripe",
             "teamPlanId":"free","teamBillingManagement":"none"}
            """
            )
        )
        let client = TeamChangeAuthClient()
        let flow = try await HostAccountFlow.makeForTeamChangeTests(
            client: client,
            billingPlanClient: planClient
        )

        let callback = URL(string: "cmux://auth-callback?stack_refresh=refresh-1&stack_access=access-1")!
        #expect(await flow.handleCallbackURL(callback, delivery: .trustedEmbeddedBrowser))
        #expect(flow.billingPlanState == BillingPlanState(
            accountID: "fixture",
            isPro: true,
            canManageBilling: true,
            tier: .pro,
            teamID: "team-a"
        ))
    }

    @Test func lateBillingResponseDoesNotApplyAfterTeamSwitch() async throws {
        // team-a's request is held and answers Pro; the switch refetches for
        // team-b, which answers Max.
        let planClient = BillingPlanCallbackURLProtocol.client(
            bodies: [Self.proPlanBody, Self.maxPlanBody],
            holdFirstResponse: true
        )
        let client = TeamChangeAuthClient()
        let flow = try await HostAccountFlow.makeForTeamChangeTests(
            client: client,
            billingPlanClient: planClient
        )

        let refresh = Task { await flow.refreshBillingPlan() }
        // Release on every exit so a failed switch cannot leave the request
        // and its loading thread blocked.
        defer { BillingPlanCallbackURLProtocol.releaseResponse() }
        let started = await Task.detached {
            BillingPlanCallbackURLProtocol.waitForRequest(timeout: .now() + 5)
        }.value
        try #require(started, "The billing request never reached the stub.")

        try await flow.selectTeam(id: "team-b")
        try await waitUntil { flow.planTier == .max }
        BillingPlanCallbackURLProtocol.releaseResponse()
        await refresh.value

        // team-a's late Pro answer must not replace team-b's Max answer.
        #expect(flow.confirmedTeamID == "team-b")
        #expect(flow.billingPlanState.teamID == "team-b")
        #expect(flow.planTier == .max)
        #expect(flow.upgradeOffer == nil)
    }

    @Test func teamSwitchLoadsTheNewTeamsPlanWithoutOfferingTheOldUpgrade() async throws {
        let planClient = BillingPlanCallbackURLProtocol.client(
            bodies: [Self.freePlanBody, Self.maxPlanBody]
        )
        let client = TeamChangeAuthClient()
        let flow = try await HostAccountFlow.makeForTeamChangeTests(
            client: client,
            billingPlanClient: planClient
        )
        await flow.refreshBillingPlan()
        #expect(flow.upgradeOffer == .pro)

        // team-b holds a Max plan. team-a's Free answer must never offer Pro
        // there, and the flow fetches team-b's plan without any surface
        // asking for it.
        try await flow.selectTeam(id: "team-b")
        #expect(flow.confirmedTeamID == "team-b")
        #expect(flow.upgradeOffer != .pro)
        #expect(flow.planTier != .free)

        try await waitUntil { flow.planTier == .max }
        #expect(flow.billingPlanState.teamID == "team-b")
        #expect(flow.upgradeOffer == nil)
    }

    @Test func switchDuringPendingCreateIsRefusedAndTheCreateCompletes() async throws {
        let client = TeamChangeAuthClient()
        let flow = try await makeFlow(client: client)
        await client.holdNextCreate()
        let create = Task { try await flow.createTeam(displayName: "New Team") }
        try await waitUntil { await client.isHoldingCreate }

        await #expect(throws: TeamChangeInProgressError()) {
            try await flow.selectTeam(id: "team-b")
        }
        #expect(await client.selectCount == 0)
        #expect(flow.selectedTeamID == "team-a")
        #expect(flow.confirmedTeamID == "team-a")
        #expect(flow.pendingTeamCreate?.displayName == "New Team")
        #expect(flow.isCreatingTeam)

        await client.releaseCreate()
        let created = try await create.value
        #expect(created.id == "team-new-1")
        #expect(flow.confirmedTeamID == "team-new-1")
    }

    @Test func createDuringPendingSwitchIsRefusedWithoutCreatingATeam() async throws {
        let client = TeamChangeAuthClient()
        let flow = try await makeFlow(client: client)
        await client.holdNextSelect()
        let select = Task { try await flow.selectTeam(id: "team-b") }
        try await waitUntil { await client.isHoldingSelect }

        await #expect(throws: TeamChangeInProgressError()) {
            _ = try await flow.createTeam(displayName: "New Team")
        }
        #expect(await client.createCount == 0)

        await client.releaseSelect()
        try await select.value
        #expect(flow.confirmedTeamID == "team-b")
    }

    @Test func createDuringPendingCreateIsRefusedAndTheFirstCreateCompletes() async throws {
        let client = TeamChangeAuthClient()
        let flow = try await makeFlow(client: client)
        await client.holdNextCreate()
        let first = Task { try await flow.createTeam(displayName: "First Team") }
        try await waitUntil { await client.isHoldingCreate }

        await #expect(throws: TeamChangeInProgressError()) {
            _ = try await flow.createTeam(displayName: "Second Team")
        }
        #expect(await client.createCount == 1)
        #expect(flow.pendingTeamCreate?.displayName == "First Team")
        #expect(flow.isCreatingTeam)

        await client.releaseCreate()
        let created = try await first.value
        #expect(created.id == "team-new-1")
        #expect(flow.confirmedTeamID == "team-new-1")
    }

    /// The Cloud header shows a pending create as the active team, standing in
    /// for teams the coordinator lists mid-create, while the confirmed scope
    /// stays on the previous team until the server answers.
    @Test func pendingCreateIsProjectedUntilTheServerAnswers() async throws {
        let client = TeamChangeAuthClient()
        let flow = try await makeFlow(client: client)
        await client.holdNextCreate()
        let create = Task { try await flow.createTeam(displayName: "  Launch Crew ") }
        try await waitUntil { await client.isHoldingCreate }

        #expect(flow.pendingTeamCreate == PendingTeamCreate(
            displayName: "Launch Crew",
            existingTeamIDs: ["team-a", "team-b"]
        ))
        #expect(flow.isCreatingTeam)
        #expect(flow.confirmedTeamID == "team-a")

        await client.releaseCreate()
        _ = try await create.value
        #expect(flow.pendingTeamCreate == nil)
        #expect(flow.confirmedTeamID == "team-new-1")
    }

    @Test func rejectedCreateClearsTheProjectionAndKeepsTheTeam() async throws {
        let client = TeamChangeAuthClient()
        let flow = try await makeFlow(client: client)
        await client.failNextCreate()

        await #expect(throws: TeamChangeRejectedError.self) {
            _ = try await flow.createTeam(displayName: "Taken Team")
        }
        #expect(flow.pendingTeamCreate == nil)
        #expect(flow.confirmedTeamID == "team-a")
        #expect(flow.availableTeams.map(\.id) == ["team-a", "team-b"])
    }

    /// Only a create holds other changes; a later switch still replaces a
    /// pending one, and the superseded switch fails.
    @Test func switchDuringPendingSwitchReplacesIt() async throws {
        let client = TeamChangeAuthClient()
        let flow = try await makeFlow(client: client)
        await client.holdNextSelect()
        let first = Task { try await flow.selectTeam(id: "team-b") }
        try await waitUntil { await client.isHoldingSelect }
        #expect(flow.selectedTeamID == "team-b")

        try await flow.selectTeam(id: "team-a")
        await client.releaseSelect()
        await #expect(throws: AuthError.unauthorized) { try await first.value }
        #expect(flow.selectedTeamID == "team-a")
        #expect(flow.confirmedTeamID == "team-a")
        #expect(await client.selectCount == 2)
    }

    /// A superseded switch can still be in flight after the switch that
    /// replaced it finishes, and a create must wait for it too.
    @Test func createWaitsForASupersededSwitchStillInFlight() async throws {
        let client = TeamChangeAuthClient()
        let flow = try await makeFlow(client: client)
        await client.holdNextSelect()
        let first = Task { try await flow.selectTeam(id: "team-b") }
        try await waitUntil { await client.isHoldingSelect }
        try await flow.selectTeam(id: "team-a")

        #expect(flow.isSelectingTeam)
        await #expect(throws: TeamChangeInProgressError()) {
            _ = try await flow.createTeam(displayName: "New Team")
        }
        #expect(await client.createCount == 0)

        await client.releaseSelect()
        await #expect(throws: AuthError.unauthorized) { try await first.value }
        #expect(!flow.isSelectingTeam)
    }

    /// The coordinator clears its busy flag before the first caller resumes
    /// and clears its optimistic projection. A second accepted create can
    /// therefore overlap that continuation; the first cleanup must not clear
    /// the second request's projection.
    @Test func overlappingAcceptedCreatesKeepTheLatestProjectionOwned() async throws {
        let client = TeamChangeAuthClient()
        let flow = try await makeFlow(client: client)
        await client.holdNextCreate()
        let first = Task { try await flow.createTeam(displayName: "First Team") }
        try await waitUntil { await client.isHoldingCreate }

        let second = Task { @MainActor in
            while flow.isCreatingTeam { await Task.yield() }
            return try await flow.createTeam(displayName: "Second Team")
        }
        await client.holdNextCreate()
        await client.releaseCreate()
        try await waitUntil { await client.isHoldingCreate }

        let firstResult = try await first.value
        #expect(firstResult.id == "team-new-1")
        #expect(flow.pendingTeamCreate?.displayName == "Second Team")
        #expect(flow.isCreatingTeam)

        await client.releaseCreate()
        let secondResult = try await second.value
        #expect(secondResult.id == "team-new-2")
        #expect(flow.pendingTeamCreate == nil)
    }

    private static let freePlanBody = """
    {"authenticated":true,"billingAvailable":true,"planId":"free",
     "subscriptionPlanId":"free","isPro":false,"billingManagement":"none",
     "teamPlanId":"free","teamBillingManagement":"none"}
    """
    private static let proPlanBody = """
    {"authenticated":true,"billingAvailable":true,"planId":"pro",
     "subscriptionPlanId":"pro","isPro":true,"billingManagement":"stripe",
     "teamPlanId":"free","teamBillingManagement":"none"}
    """
    private static let maxPlanBody = """
    {"authenticated":true,"billingAvailable":true,"planId":"pro",
     "subscriptionPlanId":"free","isPro":true,"billingManagement":"none",
     "teamPlanId":"max","teamBillingManagement":"stripe"}
    """

    private func makeFlow(client: TeamChangeAuthClient) async throws -> HostAccountFlow {
        try await HostAccountFlow.makeForTeamChangeTests(client: client)
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await condition(), "The condition never became true.")
    }
}

private final class BillingPlanCallbackURLProtocol: URLProtocol, @unchecked Sendable {
    // The suite is serialized and creates one stub client at a time. Each
    // request takes the next body; the last body answers any further request.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responseBodies: [Data] = []
    nonisolated(unsafe) private static var holdFirstResponse = false
    nonisolated(unsafe) private static var requestCount = 0
    nonisolated(unsafe) private static var requestStarted = DispatchSemaphore(value: 0)
    nonisolated(unsafe) private static var responseRelease = DispatchSemaphore(value: 0)

    static func session(body: String) -> URLSession {
        session(bodies: [body], holdFirstResponse: false)
    }

    static func client(bodies: [String], holdFirstResponse: Bool = false) -> BillingPlanClient {
        BillingPlanClient(session: session(bodies: bodies, holdFirstResponse: holdFirstResponse))
    }

    private static func session(bodies: [String], holdFirstResponse: Bool) -> URLSession {
        lock.withLock {
            responseBodies = bodies.map { Data($0.utf8) }
            self.holdFirstResponse = holdFirstResponse
            requestCount = 0
            requestStarted = DispatchSemaphore(value: 0)
            responseRelease = DispatchSemaphore(value: 0)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BillingPlanCallbackURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    static func waitForRequest(timeout: DispatchTime) -> Bool {
        requestStarted.wait(timeout: timeout) == .success
    }

    static func releaseResponse() {
        responseRelease.signal()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (body, hold, started, release) = Self.lock.withLock {
            let index = Self.requestCount
            Self.requestCount += 1
            return (
                Self.responseBodies[min(index, Self.responseBodies.count - 1)],
                Self.holdFirstResponse && index == 0,
                Self.requestStarted,
                Self.responseRelease
            )
        }
        guard hold else {
            finish(with: body)
            return
        }
        // Wait off the loading thread so a request started after this one
        // (the team switch's refetch) is not queued behind it.
        started.signal()
        DispatchQueue.global().async {
            _ = release.wait(timeout: .now() + 10)
            self.finish(with: body)
        }
    }

    private func finish(with body: Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
