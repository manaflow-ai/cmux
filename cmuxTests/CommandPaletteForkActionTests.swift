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
@Suite(.serialized)
struct CommandPaletteForkActionTests {
    @Test func forkActionsDeclareOptionalBooleanFocus() throws {
        #expect(ContentView.commandPaletteOptionalFocusArguments.count == 1)
        let argument = try #require(ContentView.commandPaletteOptionalFocusArguments.first)

        #expect(argument.name == "focus")
        #expect(argument.valueType == .boolean)
        #expect(!argument.required)
        #expect(ContentView.commandPaletteForkShouldFocus(
            CmuxActionInvocation(source: .commandPalette)
        ))
        #expect(ContentView.commandPaletteForkShouldFocus(
            CmuxActionInvocation(source: .automation)
        ))
        #expect(!ContentView.commandPaletteForkShouldFocus(
            CmuxActionInvocation(source: .automation, arguments: ["focus": "false"])
        ))
    }

    @Test(arguments: AgentConversationForkDestination.allCases)
    func staleExactPanelReturnsTypedTargetFailure(
        _ destination: AgentConversationForkDestination
    ) throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        let windowID = UUID()
        AppDelegate.shared = appDelegate
        defer { AppDelegate.shared = previousAppDelegate }

        let context = CommandPaletteActionContext(
            target: CommandPaletteActionTarget(
                windowID: windowID,
                workspaceID: tabManager.tabs.first?.id,
                panelID: tabManager.tabs.first?.focusedPanelId
            ),
            tabManager: tabManager,
            owningWindowID: windowID
        )
        let contentView = ContentView(
            updateViewModel: UpdateStateModel(),
            windowId: windowID
        )
        var registry = CommandPaletteHandlerRegistry()
        contentView.registerForkAgentConversationCommandPaletteHandlers(
            &registry,
            context: context
        )
        let handler = try #require(registry.handler(for: destination.commandPaletteCommandId))

        guard case .failed(let code, _) = handler(CmuxActionInvocation(source: .automation)) else {
            Issue.record("Expected a typed target failure")
            return
        }
        #expect(code == "target_unavailable")
    }

    @Test(arguments: AgentConversationForkDestination.allCases)
    func focusFalseReservesExactPanelAndPreservesAmbientFocus(
        _ destination: AgentConversationForkDestination
    ) async throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        let selectedWorkspace = try #require(tabManager.tabs.first)
        let selectedPanelID = try #require(selectedWorkspace.focusedPanelId)
        let targetWorkspace = tabManager.addWorkspace(
            select: false,
            autoWelcomeIfNeeded: false
        )
        let targetPanelID = try #require(targetWorkspace.focusedPanelId)
        let targetPaneID = try #require(targetWorkspace.paneId(forPanelId: targetPanelID))
        let snapshot = makeForkableClaudeSnapshot()
        targetWorkspace.setRestoredAgentSnapshotForTesting(snapshot, panelId: targetPanelID)

        let windowID = UUID()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        appDelegate.registerMainWindow(
            window,
            windowId: windowID,
            tabManager: tabManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState()
        )
        AppDelegate.shared = appDelegate
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
            window.close()
            AppDelegate.shared = previousAppDelegate
        }

        let context = CommandPaletteActionContext(
            target: CommandPaletteActionTarget(
                windowID: windowID,
                workspaceID: targetWorkspace.id,
                panelID: targetPanelID
            ),
            tabManager: tabManager,
            owningWindowID: windowID
        )
        var contentView = ContentView(
            updateViewModel: UpdateStateModel(),
            windowId: windowID
        )
        let panelKey = ContentView.commandPaletteForkableAgentPanelKey(
            workspaceId: targetWorkspace.id,
            panelId: targetPanelID
        )
        contentView.commandPaletteForkableAgentSupportedPanelKeys = [panelKey]
        contentView.commandPaletteForkableAgentSnapshotFingerprintsByPanelKey = [
            panelKey: ContentView.commandPaletteForkSnapshotFingerprint(snapshot)
        ]
        contentView.commandPaletteForkableAgentRemoteContextsByPanelKey = [panelKey: false]
        var registry = CommandPaletteHandlerRegistry()
        contentView.registerForkAgentConversationCommandPaletteHandlers(
            &registry,
            context: context
        )
        let handler = try #require(registry.handler(for: destination.commandPaletteCommandId))
        let invocation = CmuxActionInvocation(
            source: .automation,
            arguments: ["focus": "false"]
        )

        #expect(handler(invocation) == .queued)
        guard case .failed(let duplicateCode, _) = handler(invocation) else {
            Issue.record("Expected the duplicate fork to be rejected synchronously")
            return
        }
        #expect(duplicateCode == "action_in_progress")
        #expect(tabManager.selectedWorkspace?.id == selectedWorkspace.id)
        #expect(selectedWorkspace.focusedPanelId == selectedPanelID)
        #expect(targetWorkspace.focusedPanelId == targetPanelID)

        await Task.yield()

        #expect(tabManager.selectedWorkspace?.id == selectedWorkspace.id)
        #expect(selectedWorkspace.focusedPanelId == selectedPanelID)
        #expect(targetWorkspace.focusedPanelId == targetPanelID)
        switch destination {
        case .right, .left, .top, .bottom:
            #expect(targetWorkspace.bonsplitController.allPaneIds.count == 2)
        case .newTab:
            #expect(targetWorkspace.bonsplitController.tabs(inPane: targetPaneID).count == 2)
        case .newWorkspace:
            #expect(tabManager.tabs.count == 3)
        }
    }

    private func makeForkableClaudeSnapshot() -> SessionRestorableAgentSnapshot {
        let workingDirectory = "/tmp/command-palette-fork"
        return SessionRestorableAgentSnapshot(
            kind: .claude,
            sessionId: "019dad34-d218-7943-b81a-eddac5c87951",
            workingDirectory: workingDirectory,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "claude",
                executablePath: "/opt/homebrew/bin/claude",
                arguments: ["/opt/homebrew/bin/claude"],
                workingDirectory: workingDirectory,
                environment: nil,
                capturedAt: 123,
                source: "process"
            )
        )
    }
}
