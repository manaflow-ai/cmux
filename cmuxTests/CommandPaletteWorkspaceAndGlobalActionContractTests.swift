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
@Suite("Workspace and global command palette action contracts")
struct CommandPaletteWorkspaceAndGlobalActionContractTests {
    @Test("Full-screen declares optional Boolean enabled")
    func fullScreenDeclaresOptionalEnabled() throws {
        #expect(ContentView.commandPaletteToggleFullScreenArguments.count == 1)
        let argument = try #require(ContentView.commandPaletteToggleFullScreenArguments.first)

        #expect(argument.name == "enabled")
        #expect(argument.valueType == .boolean)
        #expect(!argument.required)
    }

    @Test("Full-screen toggles interactively and treats explicit state idempotently")
    func fullScreenMutationPolicyIsDeterministic() {
        let interactiveToggle = CmuxActionInvocation(source: .commandPalette)
        #expect(ContentView.commandPaletteFullScreenShouldToggle(
            interactiveToggle,
            currentIsFullScreen: false
        ) == true)
        #expect(ContentView.commandPaletteFullScreenShouldToggle(
            interactiveToggle,
            currentIsFullScreen: true
        ) == true)

        let enable = CmuxActionInvocation(
            source: .automation,
            arguments: ["enabled": "true"]
        )
        #expect(ContentView.commandPaletteFullScreenShouldToggle(
            enable,
            currentIsFullScreen: false
        ) == true)
        #expect(ContentView.commandPaletteFullScreenShouldToggle(
            enable,
            currentIsFullScreen: true
        ) == false)

        let disable = CmuxActionInvocation(
            source: .automation,
            arguments: ["enabled": "false"]
        )
        #expect(ContentView.commandPaletteFullScreenShouldToggle(
            disable,
            currentIsFullScreen: true
        ) == true)
        #expect(ContentView.commandPaletteFullScreenShouldToggle(
            disable,
            currentIsFullScreen: false
        ) == false)

        #expect(ContentView.commandPaletteFullScreenShouldToggle(
            CmuxActionInvocation(
                source: .automation,
                arguments: ["enabled": "invalid"]
            ),
            currentIsFullScreen: false
        ) == nil)
    }

    @Test("Focus adapters prefer explicit state and default automation to focused")
    func focusAdapterPolicyIsDeterministic() {
        #expect(!ContentView.commandPaletteShouldFocus(
            CmuxActionInvocation(
                source: .automation,
                arguments: ["focus": "false"]
            ),
            interactiveDefault: true
        ))
        #expect(ContentView.commandPaletteShouldFocus(
            CmuxActionInvocation(
                source: .commandPalette,
                arguments: ["focus": "true"]
            ),
            interactiveDefault: false
        ))
        #expect(ContentView.commandPaletteShouldFocus(
            CmuxActionInvocation(source: .automation),
            interactiveDefault: false
        ))
        #expect(!ContentView.commandPaletteShouldFocus(
            CmuxActionInvocation(source: .commandPalette),
            interactiveDefault: false
        ))
        #expect(ContentView.commandPaletteShouldFocus(
            CmuxActionInvocation(source: .commandPalette),
            interactiveDefault: true
        ))

        #expect(!ContentView.commandPaletteDiffShouldFocus(
            CmuxActionInvocation(source: .commandPalette),
            targetWasSelected: false
        ))
        #expect(ContentView.commandPaletteDiffShouldFocus(
            CmuxActionInvocation(source: .automation),
            targetWasSelected: false
        ))
    }

    @Test("Update request outcomes map to queued, no-op, and suppression")
    func updateRequestOutcomesAreTruthful() {
        #expect(ContentView.commandPaletteUpdateResult(.accepted) == .queued)
        #expect(ContentView.commandPaletteUpdateResult(.inProgress) == .completed)
        guard case .failed(let code, _) = ContentView.commandPaletteUpdateResult(.suppressed) else {
            Issue.record("Expected a suppressed update request to return typed failure")
            return
        }
        #expect(code == "update_suppressed")

        guard case .failed(let failureCode, _) = ContentView.commandPaletteUpdateResult(.failed) else {
            Issue.record("Expected updater startup failure to remain a typed failure")
            return
        }
        #expect(failureCode == "update_failed")
    }

    @Test("Close action availability requires its exact target scope")
    func closeActionAvailabilityUsesTargetContext() {
        var context = CommandPaletteContextSnapshot()
        #expect(!ContentView.commandPaletteCloseTabIsAvailable(context))
        #expect(!ContentView.commandPaletteCloseWorkspaceIsAvailable(context))

        context.setBool(CommandPaletteContextKeys.hasWorkspace, true)
        #expect(!ContentView.commandPaletteCloseTabIsAvailable(context))
        #expect(ContentView.commandPaletteCloseWorkspaceIsAvailable(context))

        context.setBool(CommandPaletteContextKeys.hasFocusedPanel, true)
        #expect(ContentView.commandPaletteCloseTabIsAvailable(context))
    }

    @Test("Workspace pull request focus uses explicit and adapter defaults")
    func workspacePullRequestFocusPolicyIsDeterministic() {
        #expect(!ContentView.commandPaletteOpenWorkspacePullRequestsShouldFocus(
            CmuxActionInvocation(
                source: .automation,
                arguments: ["focus": "false"]
            ),
            targetWasSelected: true
        ))
        #expect(ContentView.commandPaletteOpenWorkspacePullRequestsShouldFocus(
            CmuxActionInvocation(
                source: .commandPalette,
                arguments: ["focus": "true"]
            ),
            targetWasSelected: false
        ))
        #expect(ContentView.commandPaletteOpenWorkspacePullRequestsShouldFocus(
            CmuxActionInvocation(source: .automation),
            targetWasSelected: false
        ))
        #expect(!ContentView.commandPaletteOpenWorkspacePullRequestsShouldFocus(
            CmuxActionInvocation(source: .commandPalette),
            targetWasSelected: false
        ))
        #expect(ContentView.commandPaletteOpenWorkspacePullRequestsShouldFocus(
            CmuxActionInvocation(source: .commandPalette),
            targetWasSelected: true
        ))
    }

    @Test("Default-terminal errors use the captured interactive window and no automation UI")
    func defaultTerminalFailurePresentationUsesExactTarget() throws {
        let targetWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { targetWindow.close() }

        let interactivePresentation = try #require(
            ContentView.commandPaletteDefaultTerminalFailurePresentation(
                CmuxActionInvocation(source: .commandPalette),
                targetWindow: targetWindow
            )
        )
        guard case .alert(presentingWindow: let resolvedWindow) = interactivePresentation else {
            Issue.record("Expected an interactive default-terminal alert")
            return
        }
        #expect(resolvedWindow === targetWindow)
        #expect(ContentView.commandPaletteDefaultTerminalFailurePresentation(
            CmuxActionInvocation(source: .commandPalette),
            targetWindow: nil
        ) == nil)

        let automationPresentation = try #require(
            ContentView.commandPaletteDefaultTerminalFailurePresentation(
                CmuxActionInvocation(source: .automation),
                targetWindow: targetWindow
            )
        )
        guard case .silent = automationPresentation else {
            Issue.record("Expected automation to suppress default-terminal error UI")
            return
        }
    }
}
