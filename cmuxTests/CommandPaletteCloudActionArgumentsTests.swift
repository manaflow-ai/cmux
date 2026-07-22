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

@MainActor
@Suite("Command palette workspace todo action outcomes", .serialized)
struct CommandPaletteWorkspaceTodoActionOutcomeTests {
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

@MainActor
@Suite("Command palette terminal input outcomes")
struct CommandPaletteTerminalInputOutcomeTests {
    @Test func sentInputReportsCompleted() {
        #expect(ContentView.commandPaletteTerminalInputResult(.sent) == .completed)
    }

    @Test func coldSurfaceInputReportsQueued() {
        #expect(ContentView.commandPaletteTerminalInputResult(.queued) == .queued)
    }

    @Test(
        "Rejected input reports failure",
        arguments: [
            TerminalSurface.NamedKeySendResult.unknownKey,
            .inputQueueFull,
            .surfaceUnavailable,
            .processExited,
        ]
    )
    func rejectedInputReportsFailure(_ result: TerminalSurface.NamedKeySendResult) {
        #expect(
            ContentView.commandPaletteTerminalInputResult(result)
                == .failed(
                    code: "terminal_input_rejected",
                    message: String(
                        localized: "action.error.terminalInputRejected",
                        defaultValue: "The terminal did not accept the input."
                    )
                )
        )
    }
}

@MainActor
@Suite("Command palette terminal toggle outcomes", .serialized)
struct CommandPaletteTerminalToggleOutcomeTests {
    @Test func terminalTogglesDeclareOptionalBooleanEnabled() throws {
        let argument = try #require(ContentView.commandPaletteOptionalEnabledArguments.first)

        #expect(ContentView.commandPaletteOptionalEnabledArguments.count == 1)
        #expect(argument.name == "enabled")
        #expect(argument.valueType == .boolean)
        #expect(!argument.required)
    }

    @Test func textBoxFocusIsIdempotentWhileMountIsPending() {
        let panel = TerminalPanel(workspaceId: UUID())
        defer { panel.surface.teardownSurface() }

        #expect(panel.preferTextBoxInputWhenActivated() == .queued)
        #expect(panel.isTextBoxActive)
#if DEBUG
        #expect(panel.debugHasPendingTextBoxFocusRequest)
#endif

        #expect(panel.preferTextBoxInputWhenActivated() == .queued)
        #expect(panel.isTextBoxActive)
#if DEBUG
        #expect(panel.debugHasPendingTextBoxFocusRequest)
#endif
    }

    @Test func mountedTextBoxFocusRemainsIdempotent() {
        let panel = TerminalPanel(workspaceId: UUID())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let scrollView = NSScrollView(frame: window.contentView?.bounds ?? .zero)
        let textView = TextBoxInputTextView(frame: scrollView.bounds)
        window.contentView?.addSubview(scrollView)
        scrollView.documentView = textView
        panel.registerTextBoxInputView(textView)
        defer {
            window.close()
            panel.surface.teardownSurface()
        }

        #expect(textView.window === window)
        #expect(panel.preferTextBoxInputWhenActivated() == .focused)
        #expect(window.firstResponder === textView)
        #expect(panel.preferTextBoxInputWhenActivated() == .focused)
        #expect(window.firstResponder === textView)
        #expect(panel.isTextBoxActive)
    }

    @Test func textBoxOutcomesPreserveFocusedQueuedHiddenAndFailedStates() {
        #expect(ContentView.commandPaletteTerminalTextBoxResult(.focused) == .presented)
        #expect(ContentView.commandPaletteTerminalTextBoxResult(.queued) == .queued)
        #expect(ContentView.commandPaletteTerminalTextBoxResult(.hidden) == .completed)
        #expect(ContentView.commandPaletteTerminalTextBoxResult(.failed) == .failed(
            code: "terminal_text_box_focus_failed",
            message: String(
                localized: "action.error.terminalActionFailed",
                defaultValue: "The terminal action could not be completed."
            )
        ))
    }

    @Test func textBoxExplicitStateIsIdempotentAndOmittedToggleStillFlips() {
        let panel = TerminalPanel(workspaceId: UUID())
        defer { panel.surface.teardownSurface() }

        #expect(panel.setTextBoxInputEnabled(true) == .queued)
        #expect(panel.setTextBoxInputEnabled(true) == .queued)
        #expect(panel.isTextBoxActive)
        #expect(panel.setTextBoxInputEnabled(false) == .hidden)
        #expect(panel.setTextBoxInputEnabled(false) == .hidden)
        #expect(!panel.isTextBoxActive)

        #expect(panel.toggleTextBoxInput())
        #expect(panel.isTextBoxActive)
        #expect(panel.toggleTextBoxInput())
        #expect(!panel.isTextBoxActive)
    }

    @Test func splitZoomExplicitStateIsIdempotentAndToggleStillFlips() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        let leftPanelID = try #require(workspace.focusedPanelId)
        _ = try #require(
            workspace.newTerminalSplit(from: leftPanelID, orientation: .horizontal)
        )
        let leftPaneID = try #require(workspace.paneId(forPanelId: leftPanelID))

        #expect(manager.setSplitZoom(true, tabId: workspace.id, surfaceId: leftPanelID))
        #expect(workspace.bonsplitController.zoomedPaneId == leftPaneID)
        #expect(manager.setSplitZoom(true, tabId: workspace.id, surfaceId: leftPanelID))
        #expect(workspace.bonsplitController.zoomedPaneId == leftPaneID)
        #expect(manager.setSplitZoom(false, tabId: workspace.id, surfaceId: leftPanelID))
        #expect(workspace.bonsplitController.zoomedPaneId == nil)
        #expect(manager.setSplitZoom(false, tabId: workspace.id, surfaceId: leftPanelID))
        #expect(workspace.bonsplitController.zoomedPaneId == nil)

        #expect(manager.toggleSplitZoom(tabId: workspace.id, surfaceId: leftPanelID))
        #expect(workspace.bonsplitController.zoomedPaneId == leftPaneID)
        #expect(manager.toggleSplitZoom(tabId: workspace.id, surfaceId: leftPanelID))
        #expect(workspace.bonsplitController.zoomedPaneId == nil)
    }

    @Test func fullWidthExplicitStateIsIdempotentAndToggleStillFlips() throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)
        let panelID = try #require(workspace.focusedPanelId)
        let paneID = try #require(workspace.paneId(forPanelId: panelID))

        #expect(manager.setFullWidthTab(true, workspaceID: workspace.id, panelID: panelID))
        #expect(workspace.bonsplitController.isFullWidthTabMode(inPane: paneID))
        #expect(manager.setFullWidthTab(true, workspaceID: workspace.id, panelID: panelID))
        #expect(workspace.bonsplitController.isFullWidthTabMode(inPane: paneID))
        #expect(manager.setFullWidthTab(false, workspaceID: workspace.id, panelID: panelID))
        #expect(!workspace.bonsplitController.isFullWidthTabMode(inPane: paneID))
        #expect(manager.setFullWidthTab(false, workspaceID: workspace.id, panelID: panelID))
        #expect(!workspace.bonsplitController.isFullWidthTabMode(inPane: paneID))

        #expect(manager.toggleFullWidthTab(workspaceID: workspace.id, panelID: panelID))
        #expect(workspace.bonsplitController.isFullWidthTabMode(inPane: paneID))
        #expect(manager.toggleFullWidthTab(workspaceID: workspace.id, panelID: panelID))
        #expect(!workspace.bonsplitController.isFullWidthTabMode(inPane: paneID))
    }
}
