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

    @Test func acceptedRestoreReportsQueuedInsteadOfCompleted() {
        #expect(
            ContentView.commandPaletteCloudRestoreResult(
                hasSnapshotID: true,
                didStart: true
            ) == .queued
        )
    }

    @Test func restoreWithoutAnIdentifierStillReportsPresented() {
        #expect(
            ContentView.commandPaletteCloudRestoreResult(
                hasSnapshotID: false,
                didStart: false
            ) == .presented
        )
    }

    @Test func automationRestoreWithoutAnIdentifierReportsFailure() {
        #expect(
            ContentView.commandPaletteCloudRestoreResult(
                hasSnapshotID: false,
                didStart: false,
                source: .automation
            ) == .failed(
                code: "action_failed",
                message: String(
                    localized: "action.error.cloudVMRestoreFailed",
                    defaultValue: "Cloud VM restore could not be started."
                )
            )
        )
    }

    @Test func invocationSourceSelectsOperationalPresentationPolicy() {
        #expect(
            ContentView.commandPaletteCloudPresentationPolicy(for: .commandPalette)
                == .interactive
        )
        #expect(
            ContentView.commandPaletteCloudPresentationPolicy(for: .automation)
                == .automation
        )
    }

    @Test func automationPolicySuppressesOperationalPresentation() {
        let policy = CloudVMActionPresentationPolicy.automation

        #expect(!policy.showsProgress)
        #expect(!policy.presentsFailure)
        #expect(!policy.presentsMissingTarget)
        #expect(!policy.allowsInteractiveInput)
        #expect(!policy.presentsOutputOnSuccess(requested: true))
    }

    @Test func interactivePolicyPreservesOperationalPresentation() {
        let policy = CloudVMActionPresentationPolicy.interactive

        #expect(policy.showsProgress)
        #expect(policy.presentsFailure)
        #expect(policy.presentsMissingTarget)
        #expect(policy.allowsInteractiveInput)
        #expect(policy.presentsOutputOnSuccess(requested: true))
        #expect(!policy.presentsOutputOnSuccess(requested: false))
    }

    @Test func loadingWorkspaceOwnsOperationalPresentation() {
        let policy = CloudVMActionPresentationPolicy.workspaceLoading

        #expect(!policy.showsProgress)
        #expect(!policy.presentsFailure)
        #expect(!policy.presentsOutputOnSuccess(requested: true))
    }

    @Test func automationMissingCloudVMFailsWithoutPresentingASheet() {
        let appDelegate = AppDelegate()
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        let windowID = UUID()
        let window = testWindow()
        _ = appDelegate.registerMainWindow(
            window,
            windowId: windowID,
            tabManager: tabManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState()
        )
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
            window.close()
        }
        let workspaceID = tabManager.selectedWorkspace?.id

        #expect(!appDelegate.performCurrentCloudVMCommand(
            .status,
            workspaceID: workspaceID,
            tabManager: tabManager,
            preferredWindow: window,
            presentationPolicy: .automation,
            debugSource: "test.palette.cloud.automation.missing"
        ))
        #expect(window.sheets.isEmpty)
    }

    @Test func automationRestoreWithoutStaticArgumentFailsWithoutPresentingASheet() {
        let appDelegate = AppDelegate()
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        let windowID = UUID()
        let window = testWindow()
        _ = appDelegate.registerMainWindow(
            window,
            windowId: windowID,
            tabManager: tabManager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState()
        )
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
            window.close()
        }

        #expect(!appDelegate.performCloudVMRestoreCommand(
            tabManager: tabManager,
            preferredWindow: window,
            presentationPolicy: .automation,
            debugSource: "test.palette.cloud.automation.restoreMissingArgument"
        ))
        #expect(window.sheets.isEmpty)
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

    @Test func proPresenterValidatesTheCapturedWindowWorkspaceAndPanel() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        let windowID = UUID()
        let window = testWindow()
        _ = appDelegate.registerMainWindow(
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
        let workspace = try #require(tabManager.selectedWorkspace)
        let panelID = try #require(workspace.focusedPanelId)

        #expect(ProUpgradePresenter.capturedSourceIsAvailable(
            appDelegate: appDelegate,
            tabManager: tabManager,
            sourceWindowID: windowID,
            sourceWorkspaceID: workspace.id,
            sourcePanelID: panelID
        ))
        #expect(!ProUpgradePresenter.capturedSourceIsAvailable(
            appDelegate: appDelegate,
            tabManager: tabManager,
            sourceWindowID: UUID(),
            sourceWorkspaceID: workspace.id,
            sourcePanelID: panelID
        ))
        #expect(!ProUpgradePresenter.capturedSourceIsAvailable(
            appDelegate: appDelegate,
            tabManager: tabManager,
            sourceWindowID: windowID,
            sourceWorkspaceID: UUID(),
            sourcePanelID: panelID
        ))
        #expect(!ProUpgradePresenter.capturedSourceIsAvailable(
            appDelegate: appDelegate,
            tabManager: tabManager,
            sourceWindowID: windowID,
            sourceWorkspaceID: workspace.id,
            sourcePanelID: UUID()
        ))
        #expect(!ProUpgradePresenter.capturedSourceIsAvailable(
            appDelegate: appDelegate,
            tabManager: tabManager,
            sourceWindowID: windowID,
            sourceWorkspaceID: nil,
            sourcePanelID: panelID
        ))

        appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
        #expect(!ProUpgradePresenter.capturedSourceIsAvailable(
            appDelegate: appDelegate,
            tabManager: tabManager,
            sourceWindowID: windowID,
            sourceWorkspaceID: workspace.id,
            sourcePanelID: panelID
        ))
    }

    @Test func savedLayoutPromptResolvesOnlyTheCapturedWindow() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        let windowID = UUID()
        let window = testWindow()
        _ = appDelegate.registerMainWindow(
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
        let workspace = try #require(tabManager.selectedWorkspace)
        let panelID = try #require(workspace.focusedPanelId)
        let target = CommandPaletteActionTarget(
            windowID: windowID,
            workspaceID: workspace.id,
            panelID: panelID
        )
        let context = CommandPaletteActionContext(
            target: target,
            tabManager: tabManager,
            owningWindowID: windowID
        )

        #expect(ContentView.savedLayoutPresentingWindow(
            for: context,
            appDelegate: appDelegate
        ) === window)

        let mismatchedOwner = CommandPaletteActionContext(
            target: target,
            tabManager: tabManager,
            owningWindowID: UUID()
        )
        #expect(ContentView.savedLayoutPresentingWindow(
            for: mismatchedOwner,
            appDelegate: appDelegate
        ) == nil)

        let mismatchedWindow = CommandPaletteActionContext(
            target: CommandPaletteActionTarget(
                windowID: UUID(),
                workspaceID: workspace.id,
                panelID: panelID
            ),
            tabManager: tabManager,
            owningWindowID: windowID
        )
        #expect(ContentView.savedLayoutPresentingWindow(
            for: mismatchedWindow,
            appDelegate: appDelegate
        ) == nil)
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
