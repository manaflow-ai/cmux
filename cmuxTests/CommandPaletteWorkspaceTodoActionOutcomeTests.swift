import AppKit
import CmuxCommandPalette
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Command palette workspace todo action outcomes", .serialized)
struct CommandPaletteWorkspaceTodoActionOutcomeTests {
    @Test func checklistPresentationRequestPersistsUntilMatchingConsumption() {
        let store = WorkspaceTodoChecklistAddRequestStore()
        let firstWorkspaceID = UUID()
        let latestWorkspaceID = UUID()
        let unrelatedWorkspaceID = UUID()

        _ = store.request(workspaceID: firstWorkspaceID)
        let latestToken = store.request(workspaceID: latestWorkspaceID)

        #expect(store.claimLatest(workspaceIDs: [unrelatedWorkspaceID]) == nil)
        #expect(store.pendingToken(for: firstWorkspaceID) == nil)
        #expect(store.pendingToken(for: latestWorkspaceID) == latestToken)

        #expect(store.claimLatest(workspaceIDs: [firstWorkspaceID, latestWorkspaceID]) == .init(
            workspaceID: latestWorkspaceID,
            token: latestToken
        ))
        #expect(store.claimLatest(workspaceIDs: [firstWorkspaceID, latestWorkspaceID]) == nil)
        #expect(store.pendingToken(for: firstWorkspaceID) == nil)
        #expect(store.pendingToken(for: latestWorkspaceID) == nil)
    }

    @Test func checklistPresentationRequestsAreIsolatedPerWindowStore() {
        let firstWindowStore = WorkspaceTodoChecklistAddRequestStore()
        let secondWindowStore = WorkspaceTodoChecklistAddRequestStore()
        let firstWorkspaceID = UUID()
        let secondWorkspaceID = UUID()

        let firstToken = firstWindowStore.request(workspaceID: firstWorkspaceID)
        let secondToken = secondWindowStore.request(workspaceID: secondWorkspaceID)

        #expect(firstWindowStore.claimLatest(workspaceIDs: [secondWorkspaceID]) == nil)
        #expect(secondWindowStore.claimLatest(workspaceIDs: [firstWorkspaceID]) == nil)
        #expect(firstWindowStore.claimLatest(workspaceIDs: [firstWorkspaceID]) == .init(
            workspaceID: firstWorkspaceID,
            token: firstToken
        ))
        #expect(secondWindowStore.claimLatest(workspaceIDs: [secondWorkspaceID]) == .init(
            workspaceID: secondWorkspaceID,
            token: secondToken
        ))
    }

    @Test func todoPaneRequiresCapturedPanelInLivePane() throws {
        let contribution = try #require(
            WorkspaceTodoPaletteCommands.contributions(workspaceSubtitle: { _ in "" }).first {
                $0.arguments.map(\.name) == ["focus"]
            }
        )
        var noPanel = CommandPaletteContextSnapshot()
        noPanel.setBool(CommandPaletteContextKeys.hasWorkspace, true)
        var panelWithoutPane = noPanel
        panelWithoutPane.setBool(CommandPaletteContextKeys.hasFocusedPanel, true)
        var panelInPane = panelWithoutPane
        panelInPane.setBool(CommandPaletteContextKeys.panelHasPane, true)

        #expect(!contribution.when(noPanel))
        #expect(!contribution.when(panelWithoutPane))
        #expect(contribution.when(panelInPane))
    }

    @Test func checklistInsertionReportsRejectedAndSuccessfulOutcomes() throws {
        let defaults = UserDefaults.standard
        let key = BetaFeaturesCatalogSection().workspaceTodoControls.userDefaultsKey
        let previousValue = defaults.object(forKey: key)
        defaults.set(true, forKey: key)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        let tabManager = TabManager()
        let selectedWorkspace = try #require(tabManager.selectedWorkspace)
        let workspace = tabManager.addWorkspace(select: false)
        let targetPanelID = try #require(workspace.focusedPanelId)
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
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
            window.close()
            AppDelegate.shared = previousAppDelegate
        }
        let context = CommandPaletteActionContext(
            target: CommandPaletteActionTarget(
                windowID: windowID,
                workspaceID: workspace.id,
                panelID: targetPanelID
            ),
            tabManager: tabManager,
            owningWindowID: windowID
        )
        let contribution = try #require(
            WorkspaceTodoPaletteCommands.contributions(workspaceSubtitle: { _ in "" }).first {
                $0.arguments.map(\.name) == ["text"]
            }
        )
        var registry = CommandPaletteHandlerRegistry()
        var presentedWorkspaceID: UUID?
        WorkspaceTodoPaletteCommands.registerHandlers(
            in: &registry,
            context: context,
            presentChecklistAddField: {
                presentedWorkspaceID = $0
                return true
            }
        )
        let handler = try #require(registry.handler(for: contribution.commandId))

        #expect(handler(CmuxActionInvocation(source: .commandPalette)) == .presented)
        #expect(presentedWorkspaceID == workspace.id)

        var rejectingRegistry = CommandPaletteHandlerRegistry()
        WorkspaceTodoPaletteCommands.registerHandlers(
            in: &rejectingRegistry,
            context: context,
            presentChecklistAddField: { _ in false }
        )
        let rejectingHandler = try #require(
            rejectingRegistry.handler(for: contribution.commandId)
        )
        guard case .failed(let code, _) = rejectingHandler(
            CmuxActionInvocation(source: .automation)
        ) else {
            Issue.record("expected presentation failure")
            return
        }
        #expect(code == "presentation_failed")

        let initialCount = workspace.todoState.checklist.count
        let selectedInitialCount = selectedWorkspace.todoState.checklist.count
        let rejected = handler(CmuxActionInvocation(
            source: .automation,
            arguments: ["text": "  \n\t  "]
        ))
        #expect(rejected == .failed(
            code: "action_failed",
            message: String(
                localized: "action.error.checklistItemAddFailed",
                defaultValue: "The checklist item could not be added."
            )
        ))
        #expect(workspace.todoState.checklist.count == initialCount)

        let completed = handler(CmuxActionInvocation(
            source: .automation,
            arguments: ["text": "  Ship the palette action  "]
        ))
        #expect(completed == .completed)
        #expect(workspace.todoState.checklist.count == initialCount + 1)
        #expect(workspace.todoState.checklist.last?.text == "Ship the palette action")
        #expect(selectedWorkspace.todoState.checklist.count == selectedInitialCount)
        #expect(tabManager.selectedTabId == selectedWorkspace.id)
    }

    @Test func todoOpenFocusIsStaticForAutomationAfterSelectionMoves() throws {
        let contribution = try #require(
            WorkspaceTodoPaletteCommands.contributions(workspaceSubtitle: { _ in "" }).first {
                $0.arguments.map(\.name) == ["focus"]
            }
        )
        #expect(contribution.arguments == [
            CmuxActionArgumentDefinition(
                name: "focus",
                valueType: .boolean,
                required: false
            )
        ])

        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        let targetWorkspace = try #require(tabManager.selectedWorkspace)
        let targetPanelID = try #require(targetWorkspace.focusedPanelId)
        let targetPaneID = try #require(targetWorkspace.paneId(forPanelId: targetPanelID))
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
        var registry = CommandPaletteHandlerRegistry()
        WorkspaceTodoPaletteCommands.registerHandlers(
            in: &registry,
            context: context,
            presentChecklistAddField: { _ in true }
        )
        let handler = try #require(registry.handler(for: contribution.commandId))

        let selectedWorkspace = tabManager.addWorkspace(select: true)
        #expect(tabManager.selectedTabId == selectedWorkspace.id)

        #expect(handler(CmuxActionInvocation(
            source: .automation,
            arguments: ["focus": "false"]
        )) == .completed)
        let todoPanel = try #require(
            targetWorkspace.panels.values.compactMap { $0 as? WorkspaceTodoPanel }.first
        )
        #expect(targetWorkspace.paneId(forPanelId: todoPanel.id) == targetPaneID)
        #expect(targetWorkspace.focusedPanelId == targetPanelID)

        #expect(handler(CmuxActionInvocation(source: .commandPalette)) == .completed)
        #expect(targetWorkspace.focusedPanelId == targetPanelID)

        #expect(handler(CmuxActionInvocation(source: .automation)) == .completed)
        #expect(targetWorkspace.focusedPanelId == todoPanel.id)
        #expect(tabManager.selectedTabId == selectedWorkspace.id)
    }
}
