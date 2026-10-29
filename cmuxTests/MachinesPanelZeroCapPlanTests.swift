import CmuxCloud
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A zero machine ceiling closes Cloud provisioning for the plan. The server
/// refuses the create at any fleet size and, once the free window passes,
/// every access verb on the machines already there, so owning machines is not
/// evidence of an entitlement and the client must keep gating on the cap.
@Suite("Cloud machines zero-cap plan")
struct MachinesPanelZeroCapPlanTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func machines(count: Int) -> [MachineSnapshot] {
        (0..<count).map { index in
            MachineSnapshot(
                id: "machine-\(index)",
                provider: "freestyle",
                image: "cmuxd",
                isDesktop: false,
                activity: .ready
            )
        }
    }

    private func limits(maxActiveVms: Int?, planId: String = "free") -> VMPlanLimits {
        VMPlanLimits(
            maxActiveVms: maxActiveVms,
            planId: planId,
            freeAccessWindowDays: 7,
            freeAccessExpiresAt: Int64((now.addingTimeInterval(7 * 86_400)).timeIntervalSince1970 * 1000)
        )
    }

    private func plan(activeCount: Int, maxActiveVms: Int?, planId: String = "free") throws -> MachinePlanSnapshot {
        try #require(MachineSnapshotBuilder.planSnapshot(
            activeCount: activeCount,
            limits: limits(maxActiveVms: maxActiveVms, planId: planId),
            machines: machines(count: activeCount),
            now: now
        ))
    }

    @Test("A zero cap gates an account that already has machines")
    @MainActor
    func zeroCapGatesAnExistingFleet() throws {
        let plan = try plan(activeCount: 3, maxActiveVms: 0)
        #expect(plan.maxActiveVms == 0)
        #expect(plan.isAtLimit, "a zero cap refuses the next create at any fleet size")
        #expect(NewMachineSheetPresenter.shouldPresentUpgrade(for: plan))
        #expect(CloudTreeGroupCount(usage: plan.usage).isWarning)
        #expect(plan.freeAccessBanner != .none, "the server's expiry is authoritative")
        #expect(plan.freeAccessBannerText != nil)
    }

    @Test("A zero cap gates an empty fleet the same way")
    @MainActor
    func zeroCapGatesAnEmptyFleet() throws {
        let plan = try plan(activeCount: 0, maxActiveVms: 0)
        #expect(plan.isAtLimit)
        #expect(NewMachineSheetPresenter.shouldPresentUpgrade(for: plan))
        #expect(plan.freeAccessBannerText != nil)
    }

    @Test("A positive free cap still reads as a meter")
    @MainActor
    func positiveFreeCapKeepsItsMeter() throws {
        let plan = try plan(activeCount: 1, maxActiveVms: 1)
        #expect(plan.usage.compactCount == "1/1")
        #expect(plan.usage.countLabel == "1 of 1 machine")
        #expect(plan.isAtLimit)
        #expect(NewMachineSheetPresenter.shouldPresentUpgrade(for: plan))
    }

    @Test("A room-to-spare free cap is neither at the limit nor tinted")
    @MainActor
    func freeCapWithRoomIsNotGated() throws {
        let plan = try plan(activeCount: 0, maxActiveVms: 1)
        #expect(plan.usage.compactCount == "0/1")
        #expect(plan.isAtLimit == false)
        #expect(NewMachineSheetPresenter.shouldPresentUpgrade(for: plan) == false)
        #expect(CloudTreeGroupCount(usage: plan.usage).isWarning == false)
    }

    @Test("A paid plan with no cap is uncapped, not gated")
    @MainActor
    func paidPlanWithoutCapIsUngated() throws {
        let plan = try plan(activeCount: 3, maxActiveVms: nil, planId: "pro")
        #expect(plan.usage.compactCount == "3")
        #expect(plan.usage.countLabel == "3 machines")
        #expect(plan.isAtLimit == false)
        #expect(NewMachineSheetPresenter.shouldPresentUpgrade(for: plan) == false)
        #expect(plan.freeAccessBanner == .none)
    }

    @Test("A zero cap shows the fleet it holds, not a fraction of zero")
    @MainActor
    func zeroCapShowsABareCount() throws {
        let plan = try plan(activeCount: 3, maxActiveVms: 0)
        #expect(plan.usage.compactCount == "3", "\"3/0\" counts a fleet against a ceiling it already passed")
        #expect(plan.usage.countLabel == "3 machines")
        // The tint and the tooltip are what still say provisioning is closed,
        // so dropping the fraction must not drop either of them.
        #expect(CloudTreeGroupCount(usage: plan.usage).isWarning)
        #expect(plan.usage.help.contains("0"))
    }

    @Test("An empty zero-cap fleet shows a bare zero")
    func emptyZeroCapShowsABareCount() throws {
        let plan = try plan(activeCount: 0, maxActiveVms: 0)
        #expect(plan.usage.compactCount == "0")
        #expect(plan.usage.countLabel == "0 machines")
    }
}
