import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct CloudVMLoadingPanelTests {
    @Test func loadingHeadlineReplacesBaseProgressCopyAndResets() {
        let panel = CloudVMLoadingPanel(workspaceId: UUID())
        panel.configureLoadingHeadline("Creating a workspace on early-plum-alpaca…")

        guard case .loading(let headline) = panel.phase else {
            Issue.record("headline configuration must remain in the loading phase")
            return
        }
        #expect(headline == "Creating a workspace on early-plum-alpaca…")
        panel.resetLoading()
        guard case .loading(let resetHeadline) = panel.phase else {
            Issue.record("reset must return to loading")
            return
        }
        #expect(resetHeadline == nil)
    }

    @Test func failureReplacesLoadingHeadlineAndShowsFailurePhase() {
        let panel = CloudVMLoadingPanel(workspaceId: UUID())
        panel.configureLoadingHeadline("Creating a workspace on early-plum-alpaca…")

        panel.showFailure("The Cloud VM service is unavailable")

        #expect(panel.hasFailed)
        #expect(!panel.isLoading)
        guard case .failed(let message, _) = panel.phase else {
            Issue.record("failure must be the sole presentation phase")
            return
        }
        #expect(message == "The Cloud VM service is unavailable")
    }

    @Test("The socket handler and the in-process create replace the loading pane through one function")
    func theSocketHandlerAndTheInProcessCreateShareOneLoadingPaneReplacement() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let app = try VaultPaneAppFixture()
            let controller = TerminalController.shared
            let previousManager = controller.activeTabManagerForCallerNotification()
            let betaKey = RightSidebarBetaFeatureSettings.cloudMachinesEnabledKey
            let previousBeta = UserDefaults.standard.object(forKey: betaKey)
            let flag = CmuxFeatureFlags.cloudMachinesFlag
            let previousFlag = CmuxFeatureFlags.shared.overrideValue(for: flag)
            defer {
                controller.setActiveTabManager(previousManager)
                UserDefaults.standard.set(previousBeta, forKey: betaKey)
                CmuxFeatureFlags.shared.setOverride(previousFlag, for: flag)
                for workspace in app.manager.tabs { workspace.teardownAllPanels() }
                app.tearDown()
            }
            UserDefaults.standard.set(true, forKey: betaKey)
            CmuxFeatureFlags.shared.setOverride(true, for: flag)
            controller.setActiveTabManager(app.manager)

            let pending = app.manager.addWorkspace(initialSurface: .cloudVMLoading, select: false, autoWelcomeIfNeeded: false)
            let loadingPanelID = try #require(pending.panels.first { $0.value.panelType == .cloudVMLoading }?.key)

            let deferred = try controller.replaceCloudVMLoadingPane(
                workspaceID: pending.id, in: app.manager, command: "sleep 60", deferTerminal: true, focus: false
            )
            #expect(deferred.workspace === pending)
            #expect(deferred.panelID == loadingPanelID)
            #expect(pending.panels[loadingPanelID] is CloudVMLoadingPanel,
                    "a deferred attachment keeps the card for the catalog to adopt")

            let response = controller.v2WorkspaceCloudVMTerminalReady(params: [
                "workspace_id": pending.id.uuidString, "initial_command": "sleep 60",
                "defer_terminal": true, "focus": false
            ])
            let bytes = Data(controller.v2Result(id: "ready", response).utf8)
            let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            #expect(object["ok"] as? Bool == true)
            let result = try #require(object["result"] as? [String: Any])
            #expect(result["surface_id"] as? String == loadingPanelID.uuidString,
                    "the socket entrypoint resolves the same pane through the same function")

            #expect(throws: TerminalController.CloudVMTerminalAttachmentError.emptyCommand) {
                try controller.replaceCloudVMLoadingPane(
                    workspaceID: pending.id, in: app.manager, command: " ", deferTerminal: true, focus: false
                )
            }
            app.manager.closeWorkspace(pending, recordHistory: false)
            #expect(throws: TerminalController.CloudVMTerminalAttachmentError.workspaceNotFound) {
                try controller.replaceCloudVMLoadingPane(
                    workspaceID: pending.id, in: app.manager, command: "sleep 60", deferTerminal: true, focus: false
                )
            }
        }
    }
}
