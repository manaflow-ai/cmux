import AppKit
import CmuxCommandPalette
import CmuxControlSocket
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Browser command palette action contracts")
struct CommandPaletteBrowserActionContractTests {
    @Test("Browser state actions declare optional Boolean enabled")
    func stateActionsDeclareOptionalEnabled() throws {
        let argument = try #require(ContentView.commandPaletteOptionalEnabledArguments.first)

        #expect(ContentView.commandPaletteOptionalEnabledArguments.count == 1)
        #expect(argument.name == "enabled")
        #expect(argument.valueType == .boolean)
        #expect(!argument.required)
    }

    @Test("Explicit browser state is idempotent and omission remains a toggle")
    func enabledPolicySupportsStateAndLegacyToggle() {
        #expect(ContentView.commandPaletteRequestedToggleValue(
            CmuxActionInvocation(
                source: .automation,
                arguments: ["enabled": "true"]
            ),
            argumentName: "enabled",
            currentValue: true
        ) == true)
        #expect(ContentView.commandPaletteRequestedToggleValue(
            CmuxActionInvocation(
                source: .commandPalette,
                arguments: ["enabled": "false"]
            ),
            argumentName: "enabled",
            currentValue: false
        ) == false)
        #expect(ContentView.commandPaletteRequestedToggleValue(
            CmuxActionInvocation(source: .automation),
            argumentName: "enabled",
            currentValue: true
        ) == false)
        #expect(ContentView.commandPaletteRequestedToggleValue(
            CmuxActionInvocation(source: .commandPalette),
            argumentName: "enabled",
            currentValue: false
        ) == true)
        #expect(ContentView.commandPaletteRequestedToggleValue(
            CmuxActionInvocation(
                source: .automation,
                arguments: ["enabled": "maybe"]
            ),
            argumentName: "enabled",
            currentValue: false
        ) == nil)
    }

    @Test("Browser split actions declare optional Boolean focus")
    func splitActionsDeclareOptionalFocus() throws {
        let argument = try #require(ContentView.commandPaletteBrowserSplitArguments.first)

        #expect(ContentView.commandPaletteBrowserSplitArguments.count == 1)
        #expect(argument.name == "focus")
        #expect(argument.valueType == .boolean)
        #expect(!argument.required)
    }

    @Test("Browser split focus has deterministic adapter defaults")
    func splitFocusPolicyIsDeterministic() {
        #expect(!ContentView.commandPaletteBrowserSplitShouldFocus(
            CmuxActionInvocation(
                source: .automation,
                arguments: ["focus": "false"]
            ),
            targetIsSelected: true
        ))
        #expect(ContentView.commandPaletteBrowserSplitShouldFocus(
            CmuxActionInvocation(
                source: .commandPalette,
                arguments: ["focus": "true"]
            ),
            targetIsSelected: false
        ))
        #expect(ContentView.commandPaletteBrowserSplitShouldFocus(
            CmuxActionInvocation(source: .automation),
            targetIsSelected: false
        ))
        #expect(!ContentView.commandPaletteBrowserSplitShouldFocus(
            CmuxActionInvocation(source: .commandPalette),
            targetIsSelected: false
        ))
        #expect(ContentView.commandPaletteBrowserSplitShouldFocus(
            CmuxActionInvocation(source: .commandPalette),
            targetIsSelected: true
        ))
    }

    @Test("Rejected and no-op browser actions return typed failure")
    func actionResultReflectsWhetherWorkStarted() {
        #expect(ContentView.commandPaletteBrowserActionResult(
            didStart: true,
            acceptedResult: .completed
        ) == .completed)
        #expect(ContentView.commandPaletteBrowserActionResult(
            didStart: true,
            acceptedResult: .queued
        ) == .queued)

        guard case .failed(let code, let message) = ContentView.commandPaletteBrowserActionResult(
            didStart: false,
            acceptedResult: .completed
        ) else {
            Issue.record("Expected a typed browser action failure")
            return
        }
        #expect(code == "panel_action_failed")
        #expect(message == String(
            localized: "action.error.panelActionFailed",
            defaultValue: "The panel action could not be completed."
        ))
    }

    @Test("Browser state outcomes preserve completion and queue semantics")
    func stateActionResultReflectsMutationOutcome() {
        #expect(ContentView.commandPaletteBrowserStateActionResult(
            .alreadySatisfied
        ) == .completed)
        #expect(ContentView.commandPaletteBrowserStateActionResult(
            .completed
        ) == .completed)
        #expect(ContentView.commandPaletteBrowserStateActionResult(
            .queued
        ) == .queued)

        guard case .failed(let code, _) = ContentView.commandPaletteBrowserStateActionResult(
            .failed
        ) else {
            Issue.record("Expected a typed browser state failure")
            return
        }
        #expect(code == "panel_action_failed")
    }

    @Test("Browser state setters use exact identities and report idempotence")
    func stateSettersUseExactTarget() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let ambientWorkspaceID = try #require(manager.selectedWorkspace?.id)
        let targetWorkspace = manager.addWorkspace(
            initialSurface: .browser,
            select: false,
            autoWelcomeIfNeeded: false
        )
        let peerWorkspace = manager.addWorkspace(
            initialSurface: .browser,
            select: false,
            autoWelcomeIfNeeded: false
        )
        let targetPanel = try #require(targetWorkspace.panels.values.first as? BrowserPanel)
        let peerPanel = try #require(peerWorkspace.panels.values.first as? BrowserPanel)
        defer {
            targetPanel.close()
            peerPanel.close()
        }

        let targetInitialOmnibar = targetPanel.isOmnibarVisible
        let peerInitialOmnibar = peerPanel.isOmnibarVisible
        #expect(manager.setBrowserOmnibar(
            workspaceID: targetWorkspace.id,
            panelID: targetPanel.id,
            enabled: !targetInitialOmnibar
        ) == .completed)
        #expect(targetPanel.isOmnibarVisible == !targetInitialOmnibar)
        #expect(peerPanel.isOmnibarVisible == peerInitialOmnibar)
        #expect(manager.selectedTabId == ambientWorkspaceID)
        #expect(manager.setBrowserOmnibar(
            workspaceID: targetWorkspace.id,
            panelID: targetPanel.id,
            enabled: !targetInitialOmnibar
        ) == .alreadySatisfied)

        #expect(manager.setBrowserFocusMode(
            workspaceID: targetWorkspace.id,
            panelID: targetPanel.id,
            enabled: false,
            reason: "test"
        ) == .alreadySatisfied)
        #expect(manager.setBrowserDeveloperTools(
            workspaceID: targetWorkspace.id,
            panelID: targetPanel.id,
            enabled: false
        ) == .alreadySatisfied)
        #expect(manager.setBrowserReactGrab(
            workspaceID: targetWorkspace.id,
            panelID: targetPanel.id,
            enabled: false,
            focusWebView: false
        ) == .alreadySatisfied)
        #expect(manager.setBrowserOmnibar(
            workspaceID: targetWorkspace.id,
            panelID: UUID(),
            enabled: targetInitialOmnibar
        ) == .failed)
    }

    @Test("Back and forward model entrypoints reject unavailable traversal")
    func navigationModelRejectsNoOpTraversal() {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }

        #expect(!panel.goBackIfPossible())
        #expect(!panel.goForwardIfPossible())

        panel.restoreSessionNavigationHistory(
            backHistoryURLStrings: ["https://example.com/back"],
            forwardHistoryURLStrings: ["https://example.com/forward"],
            currentURLString: "https://example.com/current"
        )

        #expect(panel.goBackIfPossible())
        #expect(panel.goForwardIfPossible())
    }

    @Test("Back and forward enablement follows the captured browser state")
    func navigationEnablementUsesCapturedState() {
        var context = CommandPaletteContextSnapshot()

        #expect(!ContentView.commandPaletteBrowserBackEnabled(context))
        #expect(!ContentView.commandPaletteBrowserForwardEnabled(context))

        context.setBool(CommandPaletteContextKeys.panelBrowserCanGoBack, true)
        #expect(ContentView.commandPaletteBrowserBackEnabled(context))
        #expect(!ContentView.commandPaletteBrowserForwardEnabled(context))

        context.setBool(CommandPaletteContextKeys.panelBrowserCanGoForward, true)
        #expect(ContentView.commandPaletteBrowserForwardEnabled(context))
    }

    @Test("Address-bar activation selects an exact background browser target")
    func addressBarActivationSelectsExactTarget() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let originalWorkspaceID = try #require(manager.selectedWorkspace?.id)
        let browserWorkspace = manager.addWorkspace(
            initialSurface: .browser,
            select: false,
            autoWelcomeIfNeeded: false
        )
        let browserPanel = try #require(browserWorkspace.panels.values.first as? BrowserPanel)
        defer { browserPanel.close() }

        #expect(manager.selectedTabId == originalWorkspaceID)
        let activated = manager.activateBrowserPanelForAddressBarFocus(
            workspaceID: browserWorkspace.id,
            panelID: browserPanel.id
        )

        #expect(activated === browserPanel)
        #expect(manager.selectedTabId == browserWorkspace.id)
        #expect(browserWorkspace.focusedPanelId == browserPanel.id)
    }

    @Test("Browser focus actions dismiss the palette before moving AppKit focus")
    func focusActionsDismissBeforeRun() {
        #expect(ContentView.commandPaletteShouldDismissBeforeRun(
            forCommandId: "palette.browserFocusMode"
        ))
        #expect(ContentView.commandPaletteShouldDismissBeforeRun(
            forCommandId: "palette.browserFocusAddressBar"
        ))
    }
}
