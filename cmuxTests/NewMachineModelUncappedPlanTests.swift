import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The New Machine sheet on a plan with no active-machine ceiling.
@Suite("New machine sheet on an uncapped paid plan")
@MainActor
struct NewMachineModelUncappedPlanTests {
    private func makeModel(plan: MachinePlanSnapshot) -> NewMachineModel {
        NewMachineModel(mode: .newMachine, plan: plan, imageKinds: []) { _ in true }
    }

    @Test("The plan meter reads a plain count when there is no ceiling", arguments: [
        (2, "2 machines in use"), (1, "1 machine in use"),
    ])
    func meterReadsPlainCount(activeCount: Int, expected: String) {
        let plan = MachinePlanSnapshot(activeCount: activeCount, maxActiveVms: nil, planId: "pro", freeAccessWindowDays: 7)
        #expect(makeModel(plan: plan).planMeterText == expected)
    }

    @Test("Paid plans show no free-access note")
    func noFreeAccessNote() {
        let plan = MachinePlanSnapshot(activeCount: 2, maxActiveVms: nil, planId: "pro", freeAccessWindowDays: 7)
        #expect(makeModel(plan: plan).freeAccessNoteText == nil)
    }
}
