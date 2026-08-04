import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Mobile terminal paste agent routing", .serialized)
@MainActor
struct MobileTerminalPasteAgentRoutingTests {
    @Test func unflaggedAgentPrefixedTextUsesOrdinaryPastePath() throws {
        try Self.withRunningAgentHarness { controller, workspace, panel in
            let result = controller.v2MobileTerminalPaste(params: [
                "workspace_id": workspace.id.uuidString,
                "surface_id": panel.id.uuidString,
                "text": "claude doctor says this is fine",
                "submit_key": "return",
            ])

            let payload = try Self.okPayload(result)
            let pending = panel.surface.debugPendingSocketInputForTesting()
            #expect(payload["submitted"] as? Bool == true)
            #expect(payload["launch_suppressed"] == nil)
            #expect(pending.pasteTextItems == 1)
            #expect(pending.keyEvents == 1)
            #expect(panel.surface.debugPendingPasteTextsForTesting() == ["claude doctor says this is fine"])
        }
    }

    @Test func flaggedPromptLaunchIntoRunningAgentReroutesOnlyPrompt() throws {
        try Self.withRunningAgentHarness { controller, workspace, panel in
            let prompt = "Answer only 42"
            let result = controller.v2MobileTerminalPaste(params: [
                "workspace_id": workspace.id.uuidString,
                "surface_id": panel.id.uuidString,
                "text": "claude 'embedded launch prompt'",
                "submit_key": "return",
                "launch_intent": "launch_then_submit_prompt",
                "prompt": prompt,
                "ticket_id": UUID().uuidString,
            ])

            let payload = try Self.okPayload(result)
            let pending = panel.surface.debugPendingSocketInputForTesting()
            #expect(payload["agent_prompt_rerouted"] as? Bool == true)
            #expect(payload["launch_suppressed"] == nil)
            #expect(pending.pasteTextItems == 1)
            #expect(pending.keyEvents == 4)
            #expect(panel.surface.debugPendingPasteTextsForTesting() == [prompt])
        }
    }

    private static func withRunningAgentHarness(
        _ body: (TerminalController, Workspace, TerminalPanel) throws -> Void
    ) throws {
        let previousAppDelegate = AppDelegate.shared
        let controller = TerminalController.shared
        let previousManager = controller.activeTabManagerForCallerNotification()
        let appDelegate = AppDelegate()
        let manager = TabManager()
        let windowID = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        controller.setActiveTabManager(manager)
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
            controller.setActiveTabManager(previousManager)
            AppDelegate.shared = previousAppDelegate
        }

        let workspace = try #require(manager.selectedWorkspace)
        let panel = try #require(workspace.focusedTerminalPanel)
        workspace.agentPIDKeysByPanelId[panel.id] = ["claude"]
        panel.surface.releaseSurfaceForTesting()
        try body(controller, workspace, panel)
    }

    private static func okPayload(_ result: TerminalController.V2CallResult) throws -> [String: Any] {
        guard case .ok(let rawPayload) = result,
              let payload = rawPayload as? [String: Any] else {
            Issue.record("expected successful terminal paste")
            throw AgentGUIRPCError.internalError
        }
        return payload
    }
}
