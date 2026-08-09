import AppKit
import CMUXAgentLaunch
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Window activation")
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
    func backgroundAgentAttentionStaysInsideCmux() throws {
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

        let target = try #require(attentionTarget)
        let panelID = try #require(target.panelId)
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
    func backgroundTerminalBellMarksPaneUnreadWithoutFocusingIt() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        defer {
            appDelegate.tabManager = nil
            AppDelegate.shared = previousAppDelegate
        }

        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        appDelegate.tabManager = tabManager
        let targetWorkspace = tabManager.addWorkspace(select: true)
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

        let routed = appDelegate.routeTerminalBellAttention(
            preferredTabID: targetWorkspace.id,
            surfaceID: targetPanelID
        )

        #expect(routed)
        #expect(targetWorkspace.manualUnreadPanelIds == Set([targetPanelID]))
        #expect(tabManager.selectedTabId == selectedWorkspace.id)
    }
}
