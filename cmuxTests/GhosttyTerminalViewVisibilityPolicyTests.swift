import AppKit
import Bonsplit
import CmuxTerminal
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Ghostty terminal visibility policy")
struct GhosttyTerminalViewVisibilityPolicyTests {
    @MainActor
    @Test
    func portalMutationSchedulerDefersCommitPastCurrentCallback() async {
        let scheduler = TerminalPortalMutationScheduler()
        var didCommit = false

        let commit = scheduler.schedule {
            didCommit = true
        }

        #expect(!didCommit)
        await commit.value
        #expect(didCommit)
    }

    @MainActor
    @Test
    func portalMutationSchedulerCommitsOnlyLatestGeneration() async {
        let scheduler = TerminalPortalMutationScheduler()
        var committedValues: [Int] = []

        let staleCommit = scheduler.schedule {
            committedValues.append(1)
        }
        let latestCommit = scheduler.schedule {
            committedValues.append(2)
        }

        await staleCommit.value
        await latestCommit.value
        #expect(committedValues == [2])
    }

    @MainActor
    @Test
    func portalMutationSchedulerOriginalDrainIncludesFollowUpScheduledDuringCommit() async {
        let scheduler = TerminalPortalMutationScheduler()
        var committedValues: [Int] = []
        var originalDrainWasCancelled = false

        let drain = scheduler.schedule {
            committedValues.append(1)
            scheduler.schedule {
                committedValues.append(2)
            }
            originalDrainWasCancelled = Task.isCancelled
        }

        await drain.value
        #expect(!originalDrainWasCancelled)
        #expect(
            committedValues == [1, 2],
            "A commit-triggered update must stay on the live drain instead of replacing it"
        )
    }

    @MainActor
    @Test
    func portalMutationSchedulerCancelInvalidatesPendingCommit() async {
        let scheduler = TerminalPortalMutationScheduler()
        var didCommit = false

        let commit = scheduler.schedule {
            didCommit = true
        }
        scheduler.cancel()

        await commit.value
        #expect(!didCommit)
    }

    @MainActor
    @Test
    func portalMutationSchedulerReadsLiveWorkspaceSelection() async throws {
        let manager = TabManager()
        defer { manager.tabs.forEach { $0.teardownAllPanels() } }
        let workspace = try #require(manager.selectedWorkspace)
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        let originalPanel = try #require(workspace.focusedTerminalPanel)
        let replacementPanel = try #require(
            workspace.newTerminalSurface(inPane: pane, focus: false)
        )
        let scheduler = TerminalPortalMutationScheduler()
        var committedPresentation: TerminalPortalPresentation?

        let commit = scheduler.schedule {
            committedPresentation = workspace.terminalPortalPresentation(
                panelId: originalPanel.id,
                paneId: pane
            )
        }
        workspace.focusPanel(replacementPanel.id)

        await commit.value
        #expect(committedPresentation == .hidden)
    }

    @MainActor
    @Test
    func dockPresentationReadsLiveSidebarFocusOwnership() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let previousAppDelegate = AppDelegate.shared
            let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
            let appDelegate = AppDelegate()
            let manager = TabManager(autoWelcomeIfNeeded: false)
            let fileExplorerState = FileExplorerState()
            AppDelegate.shared = appDelegate
            appDelegate.tabManager = manager
            TerminalController.shared.setActiveTabManager(manager)
            let windowId = appDelegate.registerMainWindowContextForTesting(
                tabManager: manager,
                fileExplorerState: fileExplorerState
            )
            defer {
                TerminalController.shared.setActiveTabManager(previousManager)
                appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
                manager.tabs.forEach { $0.teardownAllPanels() }
                AppDelegate.shared = previousAppDelegate
            }

            let workspace = try #require(manager.tabs.first)
            let dock = workspace.dockSplit
            let pane = try #require(dock.bonsplitController.allPaneIds.first)
            dock.setVisibleInUI(true)
            let panelId = try #require(dock.newSurface(kind: .terminal, inPane: pane, focus: true))
            let tabId = try #require(dock.surfaceId(forPanelId: panelId))

            fileExplorerState.rightSidebarOwnsInputFocus = false
            #expect(
                dock.terminalPortalPresentation(panelId: panelId, tabId: tabId, paneId: pane) ==
                    .visible(isActive: false, zPriority: 1)
            )

            fileExplorerState.rightSidebarOwnsInputFocus = true
            #expect(
                dock.terminalPortalPresentation(panelId: panelId, tabId: tabId, paneId: pane) ==
                    .visible(isActive: true, zPriority: 1)
            )
        }
    }

    @MainActor
    @Test
    func retainedPriorityLetsNextWorkspacePromotionComeToFront() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let portal = WindowTerminalPortal(window: window)
        let contentView = try #require(window.contentView)
        let firstAnchor = NSView(frame: NSRect(x: 20, y: 20, width: 220, height: 180))
        let secondAnchor = NSView(frame: NSRect(x: 80, y: 60, width: 220, height: 180))
        contentView.addSubview(firstAnchor)
        contentView.addSubview(secondAnchor)

        let firstTerminal = GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        let firstHosted = GhosttySurfaceScrollView(surfaceView: firstTerminal)
        let secondTerminal = GhosttyNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        let secondHosted = GhosttySurfaceScrollView(surfaceView: secondTerminal)

        portal.bind(hostedView: secondHosted, to: secondAnchor, visibleInUI: true, zPriority: 1)
        portal.bind(hostedView: firstHosted, to: firstAnchor, visibleInUI: true, zPriority: 2)
        portal.updateEntryPriority(forHostedId: ObjectIdentifier(firstHosted), zPriority: 1)
        portal.bind(hostedView: secondHosted, to: secondAnchor, visibleInUI: true, zPriority: 2)

        let overlapInWindow = contentView.convert(NSPoint(x: 120, y: 100), to: nil)
        #expect(
            portal.terminalViewAtWindowPoint(overlapInWindow) === secondTerminal,
            "The newly selected workspace should rise above the retained workspace"
        )
    }

    @Test
    func immediateStateUpdateAllowedWhenDesiredStateIsHidden() {
        #expect(
            GhosttyTerminalView.shouldApplyImmediateHostedStateUpdate(
                desiredVisibleInUI: false,
                hostedViewHasSuperview: true,
                isBoundToCurrentHost: false
            )
        )
    }

    @Test
    func visibleHostRebindsAfterHiddenPresentationInvalidatesVisibilityCache() {
        #expect(
            GhosttyTerminalView.shouldBindPortalHost(
                boundHostMatches: true,
                hostedViewHasSuperview: true,
                portalEntryMatchesHost: true,
                lastAppliedIsVisibleInUI: false,
                lastAppliedPortalZPriority: 2,
                desiredPortalZPriority: 2
            )
        )
    }

    @Test
    func immediateStateUpdateAllowedWhenBoundToCurrentHost() {
        #expect(
            GhosttyTerminalView.shouldApplyImmediateHostedStateUpdate(
                desiredVisibleInUI: true,
                hostedViewHasSuperview: true,
                isBoundToCurrentHost: true
            )
        )
    }

    @Test
    func immediateStateUpdateSkippedForStaleHostBoundElsewhere() {
        #expect(
            !GhosttyTerminalView.shouldApplyImmediateHostedStateUpdate(
                desiredVisibleInUI: true,
                hostedViewHasSuperview: true,
                isBoundToCurrentHost: false
            )
        )
    }

    @Test
    func immediateStateUpdateAllowedWhenUnboundAndNotAttachedAnywhere() {
        #expect(
            GhosttyTerminalView.shouldApplyImmediateHostedStateUpdate(
                desiredVisibleInUI: true,
                hostedViewHasSuperview: false,
                isBoundToCurrentHost: false
            )
        )
    }

    @Test
    func swiftUIHostGeometryCallbackDefersPortalMutationUntilAfterLayout() {
        switch GhosttyTerminalView.hostCallbackPortalGeometrySynchronizationAction(window: 3873) {
        case .synchronizeWithoutLayoutFlush:
            Issue.record("A host callback must not mutate the portal during SwiftUI layout")
        case .skip:
            break
        }
    }

    @Test
    func swiftUIHostGeometryCallbackSkipsWithoutWindow() {
        switch GhosttyTerminalView.hostCallbackPortalGeometrySynchronizationAction(window: Optional<Int>.none) {
        case .synchronizeWithoutLayoutFlush:
            Issue.record("Detached host callbacks must not synchronize terminal portal geometry")
        case .skip:
            break
        }
    }
}
