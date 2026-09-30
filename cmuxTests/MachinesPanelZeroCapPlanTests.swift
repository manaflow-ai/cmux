import CmuxCloud
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A zero machine ceiling is granted access only when the fleet already has
/// machines; an empty fleet still has the free-plan paywall.
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

    private func limits(maxActiveVms: Int, planId: String = "free") -> VMPlanLimits {
        VMPlanLimits(
            maxActiveVms: maxActiveVms,
            planId: planId,
            freeAccessWindowDays: 7,
            freeAccessExpiresAt: Int64((now.addingTimeInterval(7 * 86_400)).timeIntervalSince1970 * 1000)
        )
    }

    @Test("A zero cap is inventory-only for an account with machines")
    func zeroCapIsUnmeteredWhenMachinesExist() throws {
        let plan = try #require(MachineSnapshotBuilder.planSnapshot(
            activeCount: 3,
            limits: limits(maxActiveVms: 0),
            machines: machines(count: 3),
            now: now
        ))
        #expect(plan.usage.compactCount == "3")
        #expect(plan.isAtLimit == false)
        #expect(CloudTreeGroupCount(usage: plan.usage).isWarning == false)
        #expect(plan.usage.countLabel == "3 machines")
        #expect(plan.maxActiveVms == 0)
        #expect(plan.isCloudAccessGranted)
        #expect(plan.usage.maxActiveVms == nil)
        #expect(plan.hasPlanMeter == false)
        #expect(plan.freeAccessBanner == .none)
        #expect(plan.freeAccessBannerText == nil)
    }

    @Test("A genuine free plan still meters and banners")
    func positiveFreeCapKeepsMeter() throws {
        let plan = try #require(MachineSnapshotBuilder.planSnapshot(
            activeCount: 1,
            limits: limits(maxActiveVms: 1),
            machines: machines(count: 1),
            now: now
        ))
        #expect(plan.usage.compactCount == "1/1")
        #expect(plan.isAtLimit == true)
        #expect(plan.freeAccessBanner != .none)
        #expect(plan.freeAccessBannerText != nil)
    }

    @Test("A zero-cap account without machines keeps its free-access banner")
    func zeroCapWithoutMachinesKeepsBanner() throws {
        let plan = try #require(MachineSnapshotBuilder.planSnapshot(
            activeCount: 0,
            limits: limits(maxActiveVms: 0),
            machines: [],
            now: now
        ))
        #expect(plan.maxActiveVms == 0)
        #expect(plan.isCloudAccessGranted == false)
        #expect(plan.hasPlanMeter)
        #expect(plan.isAtLimit)
        #expect(plan.freeAccessBanner != .none)
        #expect(plan.freeAccessBannerText != nil)
    }

    @Test("Granted access clears row locks and the new-machine free-window note")
    @MainActor
    func grantedAccessClearsFreeWindowPresentation() throws {
        let plan = try #require(MachineSnapshotBuilder.planSnapshot(
            activeCount: 3,
            limits: limits(maxActiveVms: 0),
            machines: machines(count: 3),
            now: now
        ))
        let locked = machines(count: 3).map { machine -> MachineSnapshot in
            var machine = machine
            machine.freeAccess = .expired
            return machine
        }
        let unlocked = MachineSnapshotBuilder.applyingFreeAccess(to: locked, plan: plan, now: now)
        #expect(unlocked.allSatisfy { $0.freeAccess == .unrestricted })

        let model = NewMachineModel(
            mode: .newMachine,
            plan: plan,
            memoryOptionsMb: [],
            submit: { _ in false }
        )
        #expect(model.freeAccessNoteText == nil)
    }

    @Test("The presenter keeps the upgrade gate only for an unentitled zero-cap account")
    @MainActor
    func presenterUpgradeGateDistinguishesGrant() throws {
        let granted = try #require(MachineSnapshotBuilder.planSnapshot(
            activeCount: 3,
            limits: limits(maxActiveVms: 0),
            machines: machines(count: 3),
            now: now
        ))
        let unentitled = try #require(MachineSnapshotBuilder.planSnapshot(
            activeCount: 0,
            limits: limits(maxActiveVms: 0),
            machines: [],
            now: now
        ))
        #expect(NewMachineSheetPresenter.shouldPresentUpgrade(for: granted) == false)
        #expect(NewMachineSheetPresenter.shouldPresentUpgrade(for: unentitled))
    }
}
