import CmuxCloud
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Cloud sidebar polish")
struct CloudSidebarPolishTests {
    @Test("A create refused at the plan's machine limit offers an upgrade when a bigger plan exists")
    func machineLimitFailureOffersUpgrade() {
        var operation = MachineCreateOperation(
            id: UUID(), request: MachineCreateCoordinatorTests.newMachineRequest(), startedAt: Date()
        )
        #expect(!operation.hitMachineLimit)
        operation.phase = .failed("Error: Cloud VM limit reached (HTTP 402: vm_active_limit_exceeded)")
        #expect(operation.hitMachineLimit)
        operation.phase = .failed("Error: The Cloud VM service is temporarily unavailable.")
        #expect(!operation.hitMachineLimit)
        for plan in ["free", "go", "pro", "unknown"] {
            #expect(MachinePlanSnapshot(activeCount: 5, planId: plan).hasHigherPlan, "\(plan)")
        }
        for plan in ["max", "Team", " founders "] {
            #expect(!MachinePlanSnapshot(activeCount: 5, planId: plan).hasHigherPlan, "\(plan)")
        }
    }

    @Test("The right sidebar never gets narrower than its mode tabs' full names")
    func rightSidebarClampHonorsContentMinimum() {
        let builtIn = CGFloat(RightSidebarWidthSettings.minimumWidth)
        #expect(ContentView.clampedRightSidebarWidth(200, availableWidth: 1600, contentMinimumWidth: 381) == 381)
        #expect(ContentView.clampedRightSidebarWidth(500, availableWidth: 1600, contentMinimumWidth: 381) == 500)
        // A content minimum below the built-in one never lowers it.
        #expect(ContentView.clampedRightSidebarWidth(100, availableWidth: 1600, contentMinimumWidth: 120) == builtIn)
    }
}
