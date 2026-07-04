import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Mobile viewport generation fence")
struct MobileViewportGenerationFenceTests {
    @Test("generationed clear prevents stale generationless piggyback from re-pinning viewport")
    func generationedClearPreventsStaleGenerationlessPiggyback() async throws {
        let controller = TerminalController.shared
        let previousManager = controller.activeTabManagerForCallerNotification()
        let manager = TabManager()
        controller.setActiveTabManager(manager)
        defer {
            controller.clearAllMobileViewportReports(reason: "test.cleanup")
            controller.setActiveTabManager(previousManager)
        }

        let workspace = try #require(manager.selectedWorkspace)
        let panel = try #require(workspace.focusedTerminalPanel)
        let baseParams: [String: Any] = [
            "workspace_id": workspace.id.uuidString,
            "surface_id": panel.id.uuidString,
            "client_id": "ios-client",
        ]

        let reportResponse = await controller.mobileHostHandleRPC(
            MobileHostRPCRequest(
                id: "viewport-report",
                method: "mobile.terminal.viewport",
                params: baseParams.merging([
                    "viewport_columns": 80,
                    "viewport_rows": 24,
                    "viewport_generation": 1,
                ]) { _, new in new },
                auth: nil
            )
        )
        guard case .ok = reportResponse else {
            Issue.record("Expected generationed viewport report to succeed")
            return
        }
        #expect(controller.debugMobileViewportReportClientIDsForTesting(surfaceID: panel.id) == Set(["ios-client"]))

        let clearResponse = await controller.mobileHostHandleRPC(
            MobileHostRPCRequest(
                id: "viewport-clear",
                method: "mobile.terminal.viewport",
                params: baseParams.merging([
                    "clear": true,
                    "viewport_generation": 2,
                ]) { _, new in new },
                auth: nil
            )
        )
        guard case .ok = clearResponse else {
            Issue.record("Expected generationed viewport clear to succeed")
            return
        }
        #expect(controller.debugMobileViewportReportClientIDsForTesting(surfaceID: panel.id) == nil)

        let stalePiggybackResponse = await controller.mobileHostHandleRPC(
            MobileHostRPCRequest(
                id: "stale-input",
                method: "terminal.input",
                params: baseParams.merging([
                    "text": "echo stale\n",
                    "viewport_columns": 90,
                    "viewport_rows": 30,
                ]) { _, new in new },
                auth: nil
            )
        )
        guard case .ok = stalePiggybackResponse else {
            Issue.record("Expected generationless input request to complete")
            return
        }
        #expect(controller.debugMobileViewportReportClientIDsForTesting(surfaceID: panel.id) == nil)
    }
}
