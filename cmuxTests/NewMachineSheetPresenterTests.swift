import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The New Machine sheet's Create: the reservation, the pending row and the launch all
/// happen in the click's own main-actor turn, and the sheet itself no longer waits for
/// a fleet read once a plan is known.
@MainActor
@Suite(.serialized)
struct NewMachineSheetPresenterTests {
    @MainActor
    private final class Harness {
        let launches = MachineCreateCoordinatorTests.LaunchRecorder()
        let coordinator = MachineCreateCoordinator(notifier: { _ in }, notificationCenter: NotificationCenter())
        private(set) var reserved: [UUID] = []
        private(set) var presented: [NewMachineModel] = []
        private(set) var prewarms = 0
        private(set) var listPages = 0
        var listPageGate: CloudLinkFirstValue<Bool>?
        var page = VMListPage(vms: [], limits: VMPlanLimits(maxActiveVms: nil, planId: "pro", freeAccessWindowDays: 0))
        private(set) var presenter: NewMachineSheetPresenter!

        // Weak, not unowned: the plan refresh a cached-plan open starts can resume
        // after the test that owned this harness has returned.
        init() {
            presenter = NewMachineSheetPresenter(
                coordinator: coordinator,
                reserveWorkspace: { [weak self] _, _ in
                    guard let self else { return nil }
                    let id = UUID()
                    reserved.append(id)
                    return id
                },
                presentSheet: { [weak self] model, _ in self?.presented.append(model) },
                listPage: { [weak self] in
                    guard let self else { return nil }
                    listPages += 1
                    if let listPageGate { _ = await listPageGate.result }
                    return page
                },
                prewarm: { [weak self] in self?.prewarms += 1 },
                launch: launches.cancellableLaunch
            )
        }
    }

    @Test func submitStartsTheCreateInTheSameMainActorTurnAsTheReservation() async throws {
        let harness = Harness()
        var reservations: [UUID] = []
        let awaiting = Task { await harness.presenter.presentNewMachineFetchingPlan(preferredWindow: nil) { reservations.append($0) } }
        await Self.yieldUntil { !harness.presented.isEmpty }
        let model = try #require(harness.presented.first)
        #expect(harness.prewarms == 1, "opening the sheet warms the tunnel and the auth token")
        #expect(harness.reserved.isEmpty)
        #expect(!harness.coordinator.hasRunningOperations)

        model.create()

        // Everything below is observed before any suspension point: the reservation,
        // the pending row and the launch belong to the click's own turn.
        let workspaceID = try #require(harness.reserved.first)
        #expect(reservations == [workspaceID])
        #expect(harness.coordinator.hasRunningOperations)
        #expect(harness.launches.arguments.count == 1)
        #expect(harness.launches.arguments[0].contains(workspaceID.uuidString))
        #expect(harness.launches.arguments[0].starts(with: ["vm", "new"]))
        #expect(model.outcome == .submitted)

        harness.launches.complete(
            status: 0, output: "OK machine=calm-petrel\nworkspace=\(workspaceID.uuidString)\n",
            workspaceID: workspaceID, machineID: "calm-petrel"
        )
        #expect(await awaiting.value == workspaceID)
        #expect(!harness.coordinator.hasRunningOperations)
    }

    @Test func aSecondOpenPresentsFromTheCachedPlanBeforeTheFleetReadReturns() async throws {
        let harness = Harness()
        let first = Task { await harness.presenter.presentNewMachineFetchingPlan(preferredWindow: nil) { _ in } }
        await Self.yieldUntil { harness.presented.count == 1 }
        #expect(harness.listPages == 1, "the first open has no cached plan and fetches one")
        harness.presented[0].cancel()
        #expect(await first.value == nil)

        let gate = CloudLinkFirstValue<Bool>()
        harness.listPageGate = gate
        let second = Task { await harness.presenter.presentNewMachineFetchingPlan(preferredWindow: nil) { _ in } }
        await Self.yieldUntil { harness.presented.count == 2 }
        #expect(harness.presented.count == 2, "the cached plan presents the sheet while the refresh is still in flight")
        #expect(harness.presented[1].plan?.planId == "pro")
        harness.presented[1].cancel()
        gate.resolve(true)
        #expect(await second.value == nil)
    }

    @Test func aPlanAtItsLimitStillRefusesTheSheet() async throws {
        let harness = Harness()
        harness.page = VMListPage(
            vms: [VMSummary(id: "only", provider: "freestyle", status: "running", image: "i", createdAt: 0, base: nil)],
            limits: VMPlanLimits(maxActiveVms: 1, planId: "free", freeAccessWindowDays: 7)
        )
        let result = await harness.presenter.presentNewMachineFetchingPlan(preferredWindow: nil) { _ in }
        #expect(result == nil)
        #expect(harness.presented.isEmpty)
        #expect(harness.reserved.isEmpty)
    }

    @Test func cancellingTheAwaitAfterSubmitCancelsTheRunningCreate() async throws {
        let harness = Harness()
        let awaiting = Task { await harness.presenter.presentNewMachineFetchingPlan(preferredWindow: nil) { _ in } }
        await Self.yieldUntil { !harness.presented.isEmpty }
        harness.presented[0].create()
        #expect(harness.coordinator.hasRunningOperations)
        awaiting.cancel()
        #expect(await awaiting.value == nil)
        await Self.yieldUntil { !harness.coordinator.hasRunningOperations }
        #expect(harness.launches.cancellations == 1)
    }

    @MainActor
    private static func yieldUntil(
        timeout: Duration = .seconds(2),
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(condition())
    }
}
