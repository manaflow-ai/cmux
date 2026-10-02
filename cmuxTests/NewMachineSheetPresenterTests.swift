import CmuxCloud
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("New machine sheet plan readiness")
struct NewMachineSheetPresenterTests {
    @Test("presentation waits for and uses the shared authoritative fleet page")
    func transientFleetMissIsRetried() async {
        var attempts = 0
        let expected = VMListPage(vms: [], limits: VMPlanLimits(
            maxActiveVms: nil,
            planId: "pro",
            freeAccessWindowDays: 0,
            memoryOptionsMb: [4096, 8192, 16384]
        ))
        let model = CloudMenuModel(
            listMachines: {
                attempts += 1
                return expected
            },
            isAvailable: { true },
            isFeatureEnabled: { true },
            mainMenu: { nil }
        )

        let page = await model.fleetPageForPresentation()

        #expect(page?.limits?.memoryOptionsMb == [4096, 8192, 16384])
        #expect(attempts == 1)
        #expect(model.fleetPage?.limits?.memoryOptionsMb == [4096, 8192, 16384])
    }
}
