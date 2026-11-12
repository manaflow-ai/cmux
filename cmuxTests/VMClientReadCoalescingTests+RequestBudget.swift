import CmuxCloud
import CmuxAuthRuntime
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Every control-plane request states how long its caller waits, so the
/// server answers inside it (web/services/vms/routeDeadline.ts).
@MainActor
extension VMClientReadCoalescingTests {
    /// A budget on a frozen clock: deadlines and stated budgets are exact.
    private static let frozenBudget = CloudRequestBudget(clock: { 1_000 })

    @Test("A request states its timeout cut by the caller's earlier budget")
    func requestStatesCallerBudget() async throws {
        let budget = Self.frozenBudget
        let fixture = try await CloudRefreshFixture.make(authClient: TeamChangeAuthClient(), fixtureTeams: true, requestBudget: budget)
        defer { fixture.session.invalidateAndCancel() }
        await CloudRefreshURLProtocol.reset()

        // The URLRequest alone would wait 60 s; the socket worker or CLI waits 12 s.
        _ = try? await budget.withBudget(seconds: 12) {
            try await fixture.client.status(id: "fixture-0")
        }

        #expect(await CloudRefreshURLProtocol.budgetHeaders() == ["12000"])
    }

    @Test("A request with no caller budget states its own URLRequest timeout")
    func requestStatesOwnTimeout() async throws {
        let fixture = try await CloudRefreshFixture.make(authClient: TeamChangeAuthClient(), fixtureTeams: true, requestBudget: Self.frozenBudget)
        defer { fixture.session.invalidateAndCancel() }
        await CloudRefreshURLProtocol.reset()

        _ = try? await fixture.client.status(id: "fixture-0")

        #expect(await CloudRefreshURLProtocol.budgetHeaders() == ["60000"])
    }

    @Test("A shared read states the transport's budget, not the first caller's shorter one")
    func sharedReadStatesTransportBudget() async throws {
        let budget = Self.frozenBudget
        let fixture = try await CloudRefreshFixture.make(authClient: TeamChangeAuthClient(), fixtureTeams: true, requestBudget: budget)
        defer { fixture.session.invalidateAndCancel() }
        await CloudRefreshURLProtocol.reset()

        _ = try? await budget.withBudget(seconds: 5) {
            try await fixture.client.stats(id: "fixture-0")
        }

        // The read coordinator's transport cap is 30 s.
        #expect(await CloudRefreshURLProtocol.budgetHeaders() == ["30000"])
    }

    @Test("A 429 whose Retry-After outlasts the caller's budget is answered, not waited out")
    func throttleWaitStopsAtBudget() async throws {
        let budget = Self.frozenBudget
        let fixture = try await CloudRefreshFixture.make(authClient: TeamChangeAuthClient(), fixtureTeams: true, requestBudget: budget)
        defer { fixture.session.invalidateAndCancel() }
        await CloudRefreshURLProtocol.reset()
        await CloudRefreshURLProtocol.configure(.throttled)

        // Retry-After is 60 s; the caller waits 5 s, so there is no second attempt.
        _ = try? await budget.withBudget(seconds: 5) {
            try await fixture.client.status(id: "fixture-0")
        }

        #expect(await CloudRefreshURLProtocol.requestCounts()["/api/vm/fixture-0"] == 1)
    }

    @Test("No attempt starts once the caller's budget is spent")
    func spentBudgetSendsNothing() async throws {
        let budget = Self.frozenBudget
        let fixture = try await CloudRefreshFixture.make(authClient: TeamChangeAuthClient(), fixtureTeams: true, requestBudget: budget)
        defer { fixture.session.invalidateAndCancel() }
        await CloudRefreshURLProtocol.reset()

        let outcome: Result<VMSummary, any Error> = await budget.withBudget(seconds: 0) {
            do { return .success(try await fixture.client.status(id: "fixture-0")) } catch { return .failure(error) }
        }

        guard case .failure(let error) = outcome else {
            Issue.record("A spent budget still sent the request")
            return
        }
        #expect((error as? URLError)?.code == .timedOut)
        #expect(await CloudRefreshURLProtocol.requestCounts().isEmpty)
    }
}

/// The CLI adds its remaining wait to every `vm.*` socket call. The
/// dispatcher strips it before any handler validates params, so strict
/// handlers keep accepting the call.
struct CloudSocketClientBudgetDispatchTests {
    @Test("The vm.* dispatcher strips the client budget and reads it in seconds")
    func dispatcherStripsBudget() {
        let dispatched = TerminalController.socketWorkerVMDispatch([
            "phase": "request", "failure": "network", "cloud_client_timeout_ms": 179_500,
        ])
        #expect(dispatched.seconds == 179.5)
        #expect(dispatched.params["cloud_client_timeout_ms"] == nil)
        #expect(dispatched.params["phase"] as? String == "request")
    }

    @Test("The strict vm.file_transfer_failure handler accepts a call that carried the client budget")
    func strictHandlerAcceptsBudgetedCall() {
        let sent: [String: Any] = ["phase": "request", "failure": "network", "cloud_client_timeout_ms": 15_000]
        // The raw params would be refused, which is why the dispatcher strips them.
        #expect(!TerminalController.socketWorkerFileTransferFailureKeysAllowed(sent))
        #expect(TerminalController.socketWorkerFileTransferFailureKeysAllowed(TerminalController.socketWorkerVMDispatch(sent).params))
    }
}
