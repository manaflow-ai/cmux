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
@Suite("Command palette cloud action arguments", .serialized)
struct CommandPaletteCloudActionArgumentsTests {
    @Test func restoreDeclaresSnapshotIdentifier() throws {
        let restore = try #require(
            ContentView.commandPaletteCloudCommandContributions().first {
                $0.commandId == ContentView.commandPaletteCloudRestoreCommandId
            }
        )

        #expect(restore.arguments == [CmuxActionArgumentDefinition(name: "snapshot_id")])
    }

    @Test func explicitCloudCommandTabManagerWinsOverTheActiveWindow() throws {
        let appDelegate = AppDelegate()
        let activeManager = TabManager(autoWelcomeIfNeeded: false)
        let targetManager = TabManager(autoWelcomeIfNeeded: false)
        let activeWindowID = UUID()
        let targetWindowID = UUID()
        let activeWindow = testWindow()
        let targetWindow = testWindow()
        _ = appDelegate.registerMainWindow(
            activeWindow,
            windowId: activeWindowID,
            tabManager: activeManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState()
        )
        _ = appDelegate.registerMainWindow(
            targetWindow,
            windowId: targetWindowID,
            tabManager: targetManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState()
        )
        appDelegate.tabManager = activeManager
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: activeWindowID)
            appDelegate.unregisterMainWindowContextForTesting(windowId: targetWindowID)
            activeWindow.close()
            targetWindow.close()
        }

        let explicitContext = try #require(appDelegate.cloudVMCommandContext(
            tabManager: targetManager,
            preferredWindow: nil,
            debugSource: "test.palette.cloud.explicitTarget"
        ))
        #expect(explicitContext.tabManager === targetManager)
    }

    @Test func proWorkspaceReuseKeepsIndependentWindowTargets() throws {
        let appDelegate = AppDelegate()
        let windowA = UUID()
        let windowB = UUID()
        let workspaceA = UUID()
        let workspaceB = UUID()
        let managerA = TabManager(autoWelcomeIfNeeded: false)
        let managerB = TabManager(autoWelcomeIfNeeded: false)

        _ = appDelegate.registerMainWindowContextForTesting(windowId: windowA, tabManager: managerA)
        _ = appDelegate.registerMainWindowContextForTesting(windowId: windowB, tabManager: managerB)
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowA)
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowB)
        }
        let contextA = try #require(appDelegate.mainWindowContext(for: managerA))
        let contextB = try #require(appDelegate.mainWindowContext(for: managerB))
        contextA.proPricingWorkspaceId = workspaceA
        contextB.proPricingWorkspaceId = workspaceB

        #expect(contextA.proPricingWorkspaceId == workspaceA)
        #expect(contextB.proPricingWorkspaceId == workspaceB)
    }

    @Test func proWorkspaceLookupDoesNotEscapeTheExplicitTabManager() throws {
        let appDelegate = AppDelegate()
        let managerA = TabManager(autoWelcomeIfNeeded: false)
        let managerB = TabManager(autoWelcomeIfNeeded: false)
        let workspaceA = try #require(managerA.tabs.first)

        #expect(appDelegate.proUpgradeWorkspaceExists(
            workspaceId: workspaceA.id,
            tabManager: managerA
        ))
        #expect(!appDelegate.proUpgradeWorkspaceExists(
            workspaceId: workspaceA.id,
            tabManager: managerB
        ))
    }

    @Test func browserOpenUsesTheExplicitTabManager() throws {
        let wasBrowserDisabled = BrowserAvailabilitySettings.isDisabled()
        BrowserAvailabilitySettings.setDisabled(false)
        defer { BrowserAvailabilitySettings.setDisabled(wasBrowserDisabled) }

        let appDelegate = AppDelegate()
        let activeManager = TabManager(autoWelcomeIfNeeded: false)
        let targetManager = TabManager(autoWelcomeIfNeeded: false)
        appDelegate.tabManager = activeManager
        let targetWindowID = UUID()
        let targetWindow = testWindow()
        _ = appDelegate.registerMainWindow(
            targetWindow,
            windowId: targetWindowID,
            tabManager: targetManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState()
        )
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: targetWindowID)
            targetWindow.close()
        }
        let activeWorkspace = try #require(activeManager.selectedWorkspace)
        let targetWorkspace = try #require(targetManager.selectedWorkspace)
        let activeBrowserCount = activeWorkspace.panels.values.filter { $0 is BrowserPanel }.count
        let targetBrowserCount = targetWorkspace.panels.values.filter { $0 is BrowserPanel }.count

        #expect(appDelegate.openBrowserAndFocusAddressBar(tabManager: targetManager) != nil)
        #expect(activeWorkspace.panels.values.filter { $0 is BrowserPanel }.count == activeBrowserCount)
        #expect(targetWorkspace.panels.values.filter { $0 is BrowserPanel }.count == targetBrowserCount + 1)
    }

    @Test func browserOpenRejectsAnUnregisteredExplicitTabManager() throws {
        let wasBrowserDisabled = BrowserAvailabilitySettings.isDisabled()
        BrowserAvailabilitySettings.setDisabled(false)
        defer { BrowserAvailabilitySettings.setDisabled(wasBrowserDisabled) }

        let appDelegate = AppDelegate()
        let staleManager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(staleManager.selectedWorkspace)
        let browserCount = workspace.panels.values.filter { $0 is BrowserPanel }.count

        #expect(appDelegate.openBrowserAndFocusAddressBar(tabManager: staleManager) == nil)
        #expect(workspace.panels.values.filter { $0 is BrowserPanel }.count == browserCount)
    }

    private func testWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
    }
}

@MainActor
@Suite("Command palette workspace todo action outcomes", .serialized)
struct CommandPaletteWorkspaceTodoActionOutcomeTests {
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

        let tabManager = TabManager()
        let workspace = try #require(tabManager.selectedWorkspace)
        let contribution = try #require(
            WorkspaceTodoPaletteCommands.contributions(workspaceSubtitle: { _ in "" }).first {
                $0.arguments.map(\.name) == ["text"]
            }
        )
        var registry = CommandPaletteHandlerRegistry()
        WorkspaceTodoPaletteCommands.registerHandlers(in: &registry, tabManager: tabManager)
        let handler = try #require(registry.handler(for: contribution.commandId))

        let initialCount = workspace.todoState.checklist.count
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
    }
}

@MainActor
@Suite("Command palette inline VS Code outcome")
struct CommandPaletteInlineVSCodeOutcomeTests {
    @Test func acceptedAsynchronousOpenReportsQueued() {
        #expect(ContentView.commandPaletteInlineVSCodeOpenResult(didQueue: true) == .queued)
    }

    @Test func rejectedOpenReportsFailure() {
        #expect(
            ContentView.commandPaletteInlineVSCodeOpenResult(didQueue: false)
                == .failed(
                    code: "open_failed",
                    message: String(
                        localized: "action.error.inlineVSCodeOpenFailed",
                        defaultValue: "VS Code (Inline) could not open the directory."
                    )
                )
        )
    }
}
