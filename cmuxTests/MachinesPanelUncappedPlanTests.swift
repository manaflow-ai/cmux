import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Paid plans carry no active-machine ceiling: the server sends
/// `limits.maxActiveVms` as null and the panel must never call that "at limit".
@Suite("Cloud machines uncapped paid plan")
struct MachinesPanelUncappedPlanTests {
    private func snapshot(activeCount: Int) -> MachinePlanSnapshot? {
        MachineSnapshotBuilder.planSnapshot(
            activeCount: activeCount,
            limits: VMPlanLimits(maxActiveVms: nil, planId: "pro", freeAccessWindowDays: 0)
        )
    }

    @Test("A nil ceiling never reaches the limit")
    func nilCeilingIsNeverAtLimit() {
        let plan = snapshot(activeCount: 400)
        #expect(plan?.maxActiveVms == nil)
        #expect(plan?.isAtLimit == false)
        #expect(plan?.isSingleMachinePlan == false)
        #expect(plan?.isPaidPlan == true)
    }

    @Test("The meter drops the 'of N' when there is no ceiling", arguments: [
        (7, "7 machines"), (1, "1 machine"), (0, "0 machines"),
    ])
    func meterReadsPlainCount(activeCount: Int, expected: String) {
        #expect(snapshot(activeCount: activeCount)?.countLabel == expected)
    }

    @Test("A capped plan still reads 'N of M'")
    func cappedPlanKeepsTheCeiling() {
        let plan = MachineSnapshotBuilder.planSnapshot(
            activeCount: 2,
            limits: VMPlanLimits(maxActiveVms: 5, planId: "pro", freeAccessWindowDays: 0)
        )
        #expect(plan?.countLabel == "2 of 5 machines")
        #expect(plan?.isAtLimit == false)
    }
}
