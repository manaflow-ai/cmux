import AppKit
import Bonsplit
import CMUXAgentLaunch
import CmuxRemoteSession
import CmuxTerminal
import ObjectiveC.runtime
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
private final class ApplicationAttentionRequestRecorder {
    private static weak var active: ApplicationAttentionRequestRecorder?
    private static let installSwizzle: Void = {
        let originalSelector = #selector(NSApplication.requestUserAttention(_:))
        let recordingSelector = #selector(NSApplication.cmuxIssue9466_requestUserAttention(_:))
        guard let originalMethod = class_getInstanceMethod(NSApplication.self, originalSelector),
              let recordingMethod = class_getInstanceMethod(NSApplication.self, recordingSelector) else {
            fatalError("Unable to install NSApplication attention recorder")
        }
        method_exchangeImplementations(originalMethod, recordingMethod)
    }()

    private(set) var requestCount = 0

    static func record(_ operation: () -> Void) -> Int {
        _ = installSwizzle
        precondition(active == nil, "NSApplication attention recording scopes cannot nest")
        let recorder = ApplicationAttentionRequestRecorder()
        active = recorder
        defer { active = nil }
        operation()
        return recorder.requestCount
    }

    fileprivate static func recordRequestIfActive() -> Bool {
        guard let active else { return false }
        active.requestCount += 1
        return true
    }
}

private extension NSApplication {
    @objc func cmuxIssue9466_requestUserAttention(
        _ requestType: NSApplication.RequestUserAttentionType
    ) -> Int {
        if ApplicationAttentionRequestRecorder.recordRequestIfActive() {
            return 0
        }
        return cmuxIssue9466_requestUserAttention(requestType)
    }
}

private final class StageManagerRightSidebarResponder: NSView, FeedKeyboardFocusResponder {
    override var acceptsFirstResponder: Bool { true }
}

@MainActor
@Suite("Window activation", .serialized)
struct GhosttyEnsureFocusWindowActivationTests {
    @Test
    func allowsActivationForActiveManager() {
        let activeManager = TabManager()
        let otherManager = TabManager()
        let targetWindow = NSWindow()
        let otherWindow = NSWindow()

        #expect(
            shouldAllowEnsureFocusWindowActivation(
                activeTabManager: activeManager,
                targetTabManager: activeManager,
                keyWindow: targetWindow,
                mainWindow: targetWindow,
                targetWindow: targetWindow
            )
        )
        #expect(!shouldAllowEnsureFocusWindowActivation(
            activeTabManager: activeManager,
            targetTabManager: otherManager,
            keyWindow: otherWindow,
            mainWindow: otherWindow,
            targetWindow: targetWindow
        ))
    }

    @Test
    func allowsActivationWhenAppHasNoKeyAndNoMainWindow() {
        let targetManager = TabManager()
        let targetWindow = NSWindow()

        #expect(
            shouldAllowEnsureFocusWindowActivation(
                activeTabManager: nil,
                targetTabManager: targetManager,
                keyWindow: nil,
                mainWindow: nil,
                targetWindow: targetWindow
            )
        )
        #expect(!shouldAllowEnsureFocusWindowActivation(
            activeTabManager: nil,
            targetTabManager: targetManager,
            keyWindow: NSWindow(),
            mainWindow: nil,
            targetWindow: targetWindow
        ))
        #expect(!shouldAllowEnsureFocusWindowActivation(
            activeTabManager: nil,
            targetTabManager: targetManager,
            keyWindow: nil,
            mainWindow: NSWindow(),
            targetWindow: targetWindow
        ))
    }

    @Test
    func backgroundAgentAttentionDoesNotRequestApplicationAttention() throws {
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = tabManager.addWorkspace(select: true)
        var attentionTarget: FeedCoordinator.AttentionTarget?
        defer {
            if let attentionTarget {
                FeedCoordinator.shared.concludeBlockingDecisionAttention(attentionTarget)
            }
            if tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                tabManager.closeWorkspace(workspace)
            }
        }

        let requestCount = ApplicationAttentionRequestRecorder.record {
            attentionTarget = FeedCoordinator.shared.surfaceBlockingDecisionAttention(
                event: WorkstreamEvent(
                    sessionId: "issue-9466-stage-manager",
                    hookEventName: .permissionRequest,
                    source: "claude",
                    workspaceId: workspace.id.uuidString,
                    requestId: "issue-9466-stage-manager-request"
                ),
                resolved: (
                    workspaceId: workspace.id,
                    surfaceId: workspace.focusedPanelId
                ),
                tabManager: tabManager
            )
        }

        let target = try #require(attentionTarget)
        let panelID = try #require(target.panelId)
        #expect(requestCount == 0)
        #expect(workspace.agentLifecycleStatesByPanelId[panelID]?["claude_code"] == .needsInput)
        #expect(workspace.statusEntries["claude_code"]?.value == FeedCoordinator.needsInputStatusValue)
    }

    @Test
    func notificationFlashCoalescesWhileAnimationIsActive() throws {
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = tabManager.addWorkspace(select: true)
        defer {
            if tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                tabManager.closeWorkspace(workspace)
            }
        }

        let terminalPanel = try #require(workspace.focusedTerminalPanel)
        GhosttySurfaceScrollView.resetFlashCounts()

        terminalPanel.hostedView.triggerFlash(style: .notification)
        terminalPanel.hostedView.triggerFlash(style: .notification)
        #expect(GhosttySurfaceScrollView.flashCount(for: terminalPanel.id) == 1)

        terminalPanel.hostedView.triggerFlash(style: .navigation)
        #expect(GhosttySurfaceScrollView.flashCount(for: terminalPanel.id) == 2)
    }

    @Test
    func workspaceOverlayNotificationFlashCoalescesWhileAnimationIsActive() throws {
        let defaults = UserDefaults.standard
        let previousExperimentEnabled = defaults.object(
            forKey: TmuxOverlayExperimentSettings.enabledKey
        )
        let previousExperimentTarget = defaults.object(
            forKey: TmuxOverlayExperimentSettings.targetKey
        )
        let previousPaneFlashEnabled = defaults.object(
            forKey: NotificationPaneFlashSettings.enabledKey
        )
        defaults.set(true, forKey: TmuxOverlayExperimentSettings.enabledKey)
        defaults.set(
            TmuxOverlayExperimentTarget.bonsplitPane.rawValue,
            forKey: TmuxOverlayExperimentSettings.targetKey
        )
        defaults.set(true, forKey: NotificationPaneFlashSettings.enabledKey)
        defer {
            if let previousExperimentEnabled {
                defaults.set(
                    previousExperimentEnabled,
                    forKey: TmuxOverlayExperimentSettings.enabledKey
                )
            } else {
                defaults.removeObject(forKey: TmuxOverlayExperimentSettings.enabledKey)
            }
            if let previousExperimentTarget {
                defaults.set(
                    previousExperimentTarget,
                    forKey: TmuxOverlayExperimentSettings.targetKey
                )
            } else {
                defaults.removeObject(forKey: TmuxOverlayExperimentSettings.targetKey)
            }
            if let previousPaneFlashEnabled {
                defaults.set(
                    previousPaneFlashEnabled,
                    forKey: NotificationPaneFlashSettings.enabledKey
                )
            } else {
                defaults.removeObject(forKey: NotificationPaneFlashSettings.enabledKey)
            }
        }

        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = tabManager.addWorkspace(select: true)
        defer {
            if tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                tabManager.closeWorkspace(workspace)
            }
        }
        let terminalPanel = try #require(workspace.focusedTerminalPanel)
        let initialToken = workspace.tmuxWorkspaceFlashToken

        terminalPanel.triggerFlash(reason: .notificationArrival)
        terminalPanel.triggerFlash(reason: .notificationArrival)
        #expect(workspace.tmuxWorkspaceFlashToken == initialToken + 1)

        terminalPanel.triggerFlash(reason: .navigation)
        #expect(workspace.tmuxWorkspaceFlashToken == initialToken + 2)
    }

    @Test
    func backgroundTerminalBellMarksPaneUnreadWithoutRequestingApplicationAttention() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let previousAppDelegate = AppDelegate.shared
            let appDelegate = AppDelegate()
            defer {
                appDelegate.tabManager = nil
                AppDelegate.shared = previousAppDelegate
            }

            let tabManager = TabManager(autoWelcomeIfNeeded: false)
            appDelegate.tabManager = tabManager
            let targetWorkspace = tabManager.addWorkspace(select: true)
            let targetTerminal = try #require(targetWorkspace.focusedTerminalPanel)
            let targetPanelID = try #require(targetWorkspace.focusedPanelId)
            let selectedWorkspace = tabManager.addWorkspace(select: true)
            defer {
                if tabManager.tabs.contains(where: { $0.id == targetWorkspace.id }) {
                    tabManager.closeWorkspace(targetWorkspace)
                }
                if tabManager.tabs.contains(where: { $0.id == selectedWorkspace.id }) {
                    tabManager.closeWorkspace(selectedWorkspace)
                }
            }

            #expect(targetWorkspace.manualUnreadPanelIds.isEmpty)
            #expect(tabManager.selectedTabId == selectedWorkspace.id)

            let requestCount = ApplicationAttentionRequestRecorder.record {
                let presentation = TerminalBellPresentation(
                    systemSoundEnabled: false,
                    customAudioPath: nil,
                    customAudioVolume: 0.5,
                    visualBellEnabled: true
                )
                GhosttyApp.shared.ringBell(
                    surface: targetTerminal.surface,
                    presentation: presentation
                )
                GhosttyApp.shared.ringBell(
                    surface: targetTerminal.surface,
                    presentation: presentation
                )
            }

            #expect(requestCount == 0)
            #expect(targetWorkspace.manualUnreadPanelIds == Set([targetPanelID]))
            #expect(tabManager.selectedTabId == selectedWorkspace.id)
        }
    }

    @Test
    func remoteTmuxMirrorBellRoutesThroughProjectedPaneOwnership() throws {
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        let targetWorkspace = tabManager.addWorkspace(select: true)
        let containerPanelID = try #require(targetWorkspace.focusedPanelId)
        let paneIDs = [11: PaneID(), 22: PaneID()]
        let connection = RemoteTmuxControlConnection(
            host: RemoteTmuxHost(destination: "user@host"),
            sessionName: "issue-9466-attention"
        )
        let layout = RemoteTmuxLayoutNode(
            width: 80,
            height: 24,
            x: 0,
            y: 0,
            content: .horizontal([
                RemoteTmuxLayoutNode(
                    width: 40,
                    height: 24,
                    x: 0,
                    y: 0,
                    content: .pane(11)
                ),
                RemoteTmuxLayoutNode(
                    width: 39,
                    height: 24,
                    x: 41,
                    y: 0,
                    content: .pane(22)
                ),
            ])
        )
        let mirror = RemoteTmuxWindowMirror(
            windowId: 1,
            panelId: containerPanelID,
            connection: connection,
            layout: layout,
            controlPaneID: { [paneIDs] in paneIDs[$0] },
            makePanel: { [targetWorkspace] _ in
                targetWorkspace.makeRemoteTmuxPanePanel(onInput: { _ in })
            }
        )
        mirror.noteRemoteActivePane(11)
        targetWorkspace.isRemoteTmuxMirror = true
        targetWorkspace.setRemoteTmuxWindowMirror(
            mirror,
            forPanelId: containerPanelID
        )
        let activeTerminal = try #require(mirror.panel(forPane: 11))
        let backgroundTerminal = try #require(mirror.panel(forPane: 22))
        let selectedWorkspace = tabManager.addWorkspace(select: true)
        defer {
            targetWorkspace.setRemoteTmuxWindowMirror(nil, forPanelId: containerPanelID)
            targetWorkspace.isRemoteTmuxMirror = false
            mirror.teardown()
            if tabManager.tabs.contains(where: { $0.id == targetWorkspace.id }) {
                tabManager.closeWorkspace(targetWorkspace)
            }
            if tabManager.tabs.contains(where: { $0.id == selectedWorkspace.id }) {
                tabManager.closeWorkspace(selectedWorkspace)
            }
        }

        #expect(targetWorkspace.isFocusedTerminalInputSurface(activeTerminal.id))
        #expect(!targetWorkspace.isFocusedTerminalInputSurface(backgroundTerminal.id))
        #expect(targetWorkspace.manualUnreadPanelIds.isEmpty)
        #expect(tabManager.selectedTabId == selectedWorkspace.id)

        let visualBell = try #require(backgroundTerminal.surface.onVisualBell)
        visualBell()

        #expect(targetWorkspace.manualUnreadPanelIds == Set([containerPanelID]))
        #expect(tabManager.selectedTabId == selectedWorkspace.id)
    }

    @Test
    func terminalBellInNonKeyCmuxWindowMarksPaneUnread() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let previousAppDelegate = AppDelegate.shared
            let previousFocusOverride = AppFocusState.overrideIsFocused
            let appDelegate = AppDelegate()
            let tabManager = TabManager(autoWelcomeIfNeeded: false)
            let ownerWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 240, height: 180),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            ownerWindow.isReleasedWhenClosed = false
            ownerWindow.identifier = NSUserInterfaceItemIdentifier("cmux.main.bell-owner")
            tabManager.window = ownerWindow
            appDelegate.tabManager = tabManager
            AppDelegate.shared = appDelegate
            AppFocusState.overrideIsFocused = true

            let workspace = tabManager.addWorkspace(select: true)
            let terminal = try #require(workspace.focusedTerminalPanel)
            let panelID = try #require(workspace.focusedPanelId)
            defer {
                if tabManager.tabs.contains(where: { $0.id == workspace.id }) {
                    tabManager.closeWorkspace(workspace)
                }
                ownerWindow.orderOut(nil)
                ownerWindow.close()
                tabManager.window = nil
                appDelegate.tabManager = nil
                AppFocusState.overrideIsFocused = previousFocusOverride
                AppDelegate.shared = previousAppDelegate
            }

            // CI app hosts cannot reliably make a programmatic peer window key.
            // The routing contract only requires this terminal's owner to be non-key.
            ownerWindow.orderOut(nil)
            #expect(NSApp.keyWindow !== ownerWindow)
            #expect(workspace.manualUnreadPanelIds.isEmpty)

            let visualBell = try #require(terminal.surface.onVisualBell)
            visualBell()

            #expect(workspace.manualUnreadPanelIds == Set([panelID]))
            #expect(tabManager.selectedTabId == workspace.id)
            #expect(NSApp.keyWindow !== ownerWindow)
        }
    }

    @Test
    func terminalBellWhileRightSidebarOwnsInputMarksSelectedPaneUnread() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let previousAppDelegate = AppDelegate.shared
            let previousFocusOverride = AppFocusState.overrideIsFocused
            let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
            let appDelegate = AppDelegate()
            let tabManager = TabManager(autoWelcomeIfNeeded: false)
            let fileExplorerState = FileExplorerState()
            let windowID = UUID()
            let ownerWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            ownerWindow.isReleasedWhenClosed = false
            ownerWindow.identifier = NSUserInterfaceItemIdentifier(
                "cmux.main.\(windowID.uuidString)"
            )
            let contentView = NSView(frame: ownerWindow.contentRect(forFrameRect: ownerWindow.frame))
            let rightSidebarResponder = StageManagerRightSidebarResponder(frame: contentView.bounds)
            contentView.addSubview(rightSidebarResponder)
            ownerWindow.contentView = contentView

            AppDelegate.shared = appDelegate
            appDelegate.tabManager = tabManager
            TerminalController.shared.setActiveTabManager(tabManager)
            appDelegate.registerMainWindow(
                ownerWindow,
                windowId: windowID,
                tabManager: tabManager,
                sidebarState: SidebarState(),
                sidebarSelectionState: SidebarSelectionState(),
                fileExplorerState: fileExplorerState
            )
            AppFocusState.overrideIsFocused = true

            let workspace = try #require(tabManager.selectedWorkspace)
            let terminal = try #require(workspace.focusedTerminalPanel)
            let panelID = terminal.id
            defer {
                TerminalController.shared.setActiveTabManager(previousManager)
                appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
                tabManager.tabs.forEach { $0.teardownAllPanels() }
                ownerWindow.orderOut(nil)
                ownerWindow.close()
                appDelegate.tabManager = nil
                AppFocusState.overrideIsFocused = previousFocusOverride
                AppDelegate.shared = previousAppDelegate
            }

            ownerWindow.makeKeyAndOrderFront(nil)
            #expect(NSApp.keyWindow === ownerWindow)
            #expect(ownerWindow.makeFirstResponder(rightSidebarResponder))
            appDelegate.keyboardFocusCoordinator(for: ownerWindow)?
                .noteRightSidebarInteraction(mode: .feed)

            #expect(tabManager.selectedTabId == workspace.id)
            #expect(workspace.isFocusedTerminalInputSurface(terminal.id))
            #expect(workspace.manualUnreadPanelIds.isEmpty)

            let visualBell = try #require(terminal.surface.onVisualBell)
            visualBell()

            #expect(workspace.manualUnreadPanelIds == Set([panelID]))
            #expect(ownerWindow.firstResponder === rightSidebarResponder)
        }
    }
}
