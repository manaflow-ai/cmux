import CmuxCloud
import CmuxCloudResizeCore
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
        operation.phase = .failed(output: "Error: Cloud VM limit reached (HTTP 402: vm_active_limit_exceeded)")
        operation.refusalCode = "vm_active_limit_exceeded"
        #expect(operation.hitMachineLimit)
        // Actions follow the carried code, never the display text.
        operation.refusalCode = nil
        #expect(!operation.hitMachineLimit)
        for plan in ["free", "go", "unknown"] {
            #expect(MachinePlanSnapshot(activeCount: 5, planId: plan).hasHigherPlan, "\(plan)")
        }
        // Pro already has the most machines any plan sells: Max raises the
        // machine sizes and shared pool, not the machine count, and the
        // service sends no upgrade for a paid plan at its machine limit.
        for plan in ["pro", "max", "Team", " founders "] {
            #expect(!MachinePlanSnapshot(activeCount: 5, planId: plan).hasHigherPlan, "\(plan)")
        }
    }

    @Test("A create refused by a full shared pool says what is in use, not that the plan is missing")
    func resourcePoolFailureExplainsThePool() {
        let body = """
            {"error":"vm_resource_pool_exceeded","resource":"vcpus","pool":{"vcpus":20,"memoryMb":40960},
             "used":{"vcpus":20,"memoryMb":40960},"requested":{"vcpus":4,"memoryMb":8192},"upgradePlanId":"max"}
            """
        let text = InProcessMachineCreateLauncher.failureText(for: VMClientError.httpStatus(402, body))
        #expect(!text.contains(CloudDiagnosticFailure.plan.label))
        #expect(text.hasPrefix(CloudVMResourcePool.shortfallText(.vcpus(requested: 4, free: 0, pool: 20), offersUpgrade: true)))
        let shown = MachineCreateCoordinator.displayableFailureOutput(text)
        #expect(shown == text.trimmingCharacters(in: .whitespacesAndNewlines))
        var operation = MachineCreateOperation(
            id: UUID(), request: MachineCreateCoordinatorTests.newMachineRequest(), startedAt: Date()
        )
        operation.phase = .failed(output: shown)
        operation.refusalCode = "vm_resource_pool_exceeded"
        #expect(operation.hitResourcePool)
        #expect(!operation.hitMachineLimit)
        #expect(InProcessMachineCreateLauncher.failureText(for: VMClientError.httpStatus(402, "")) == CloudDiagnosticFailure.plan.label + "\n")
        // A server message naming another code changes nothing: only the carried code counts.
        operation.phase = .failed(output: "See (HTTP 402: vm_resource_pool_exceeded)\n(HTTP 402: vm_new_gate)")
        operation.refusalCode = "vm_new_gate"
        #expect(!operation.hitResourcePool)
        operation.refusalCode = "vm_resource_pool_exceeded_v2"
        #expect(!operation.hitResourcePool)
    }

    @Test("The mode bar's minimum fits the widest tab's name with every other tab as its icon")
    func oneLabelWidth() {
        // Full and icon-only widths for three tabs; Cloud's label is the widest.
        let natural: [CGFloat] = [59, 66, 58]
        let floors: [CGFloat] = [30, 30, 30]
        #expect(abs(RightSidebarModeBarTabWidths.oneLabelWidth(natural: natural, floors: floors) - 126) < 0.01)
        #expect(RightSidebarModeBarTabWidths.oneLabelWidth(natural: [], floors: []) == 0)
    }

    @Test("The right sidebar never gets narrower than its mode bar needs")
    func rightSidebarClampHonorsContentMinimum() {
        let builtIn = CGFloat(RightSidebarWidthSettings.minimumWidth)
        #expect(ContentView.clampedRightSidebarWidth(200, availableWidth: 1600, contentMinimumWidth: 381) == 381)
        #expect(ContentView.clampedRightSidebarWidth(
            500, availableWidth: 1600, configuredMaximumWidth: 500, contentMinimumWidth: 381
        ) == 500)
        // A content minimum below the built-in one never lowers it.
        #expect(ContentView.clampedRightSidebarWidth(100, availableWidth: 1600, contentMinimumWidth: 120) == builtIn)
    }

    @Test("The right sidebar content minimum stays below its effective maximum")
    func rightSidebarContentMinimumHonorsMaximum() {
        #expect(ContentView.clampedRightSidebarWidth(
            400, availableWidth: 800, configuredMaximumWidth: 420, contentMinimumWidth: 900
        ) == 420)
    }
}
