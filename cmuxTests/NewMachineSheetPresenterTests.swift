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
    @Test("a transient fleet miss is retried before presentation")
    func transientFleetMissIsRetried() async {
        var attempts = 0
        let expected = VMListPage(vms: [], limits: VMPlanLimits(
            maxActiveVms: nil,
            planId: "pro",
            freeAccessWindowDays: 0,
            memoryOptionsMb: [4096, 8192, 16384]
        ))
        let presenter = NewMachineSheetPresenter(
            fleetPageLoader: {
                attempts += 1
                return attempts == 2 ? expected : nil
            },
            retryDelays: [.zero]
        )

        let page = await presenter.fetchFleetPageForPresentation()

        #expect(page?.limits?.memoryOptionsMb == [4096, 8192, 16384])
        #expect(attempts == 2)
    }
}
