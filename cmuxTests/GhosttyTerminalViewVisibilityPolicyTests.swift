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

            fileExplorerState.rightSidebarOwnsInputFocus = false
            #expect(
                dock.terminalPortalPresentation(panelId: panelId, paneId: pane) ==
                    .visible(isActive: false, zPriority: 1)
            )

            fileExplorerState.rightSidebarOwnsInputFocus = true
            #expect(
                dock.terminalPortalPresentation(panelId: panelId, paneId: pane) ==
                    .visible(isActive: true, zPriority: 1)
            )
        }
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

@Suite("Terminal portal host authority")
struct TerminalPortalHostAuthorityTests {
    @MainActor
    private func makeSurface() -> TerminalSurface {
        TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
    }

    @MainActor
    @Test
    func workspaceOwnershipTransferDoesNotInvalidateBindingLifecycle() {
        let surface = makeSurface()
        let bindingGeneration = surface.portalBindingGeneration()
        let ownershipGeneration = surface.currentPortalHostOwnershipGeneration()

        surface.updateWorkspaceId(UUID())

        #expect(surface.portalBindingGeneration() == bindingGeneration)
        #expect(surface.currentPortalHostOwnershipGeneration() > ownershipGeneration)
    }

    @MainActor
    @Test
    func olderHostCannotStealLeaseAfterNewHostBinds() {
        let surface = makeSurface()
        let oldHost = NSView(), newHost = NSView()
        let oldPane = PaneID(), newPane = PaneID()
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)

        #expect(surface.claimPortalHost(
            hostId: ObjectIdentifier(oldHost), paneId: oldPane, ownershipGeneration: 1,
            inWindow: true, bounds: bounds, reason: "test.old.initial"
        ))
        #expect(surface.claimPortalHost(
            hostId: ObjectIdentifier(newHost), paneId: newPane, ownershipGeneration: 2,
            inWindow: true, bounds: bounds, reason: "test.new.bind"
        ))
        #expect(!surface.claimPortalHost(
            hostId: ObjectIdentifier(oldHost), paneId: oldPane, ownershipGeneration: 1,
            inWindow: true, bounds: bounds, reason: "test.old.delayed"
        ))
        #expect(
            surface.debugPortalHostLease().hostId ==
                String(describing: ObjectIdentifier(newHost))
        )
    }

    @MainActor
    @Test
    func detachedHostCannotReplaceLiveHost() {
        let surface = makeSurface()
        let oldHost = NSView(), newHost = NSView()
        let oldPane = PaneID(), newPane = PaneID()
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)

        #expect(surface.claimPortalHost(
            hostId: ObjectIdentifier(oldHost), paneId: oldPane, ownershipGeneration: 1,
            inWindow: true, bounds: bounds, reason: "test.old.initial"
        ))
        #expect(!surface.claimPortalHost(
            hostId: ObjectIdentifier(newHost), paneId: newPane, ownershipGeneration: 2,
            inWindow: false, bounds: bounds, reason: "test.new.detached"
        ))
        #expect(
            surface.debugPortalHostLease().hostId ==
                String(describing: ObjectIdentifier(oldHost))
        )
        #expect(surface.claimPortalHost(
            hostId: ObjectIdentifier(oldHost), paneId: oldPane, ownershipGeneration: 1,
            inWindow: true, bounds: bounds, reason: "test.old.afterDetachedCandidate"
        ))
        #expect(surface.claimPortalHost(
            hostId: ObjectIdentifier(newHost), paneId: newPane, ownershipGeneration: 2,
            inWindow: true, bounds: bounds, reason: "test.new.attached"
        ))
        #expect(
            surface.debugPortalHostLease().hostId ==
                String(describing: ObjectIdentifier(newHost))
        )
    }

    @MainActor
    @Test
    func sameEpochReplacementWaitsForAuthoritativeHostRetirement() {
        let surface = makeSurface()
        let oldHost = NSView(), replacementHost = NSView()
        let pane = PaneID()
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        var retryCount = 0

        #expect(surface.claimPortalHost(
            hostId: ObjectIdentifier(oldHost), paneId: pane, ownershipGeneration: 1,
            inWindow: true, bounds: bounds, reason: "test.visible.initial"
        ))
        #expect(!surface.claimPortalHost(
            hostId: ObjectIdentifier(replacementHost), paneId: pane, ownershipGeneration: 1,
            inWindow: true, bounds: bounds,
            retryWhenAvailable: { retryCount += 1 },
            reason: "test.replacement.wait"
        ))
        #expect(retryCount == 0)
        #expect(surface.preparePortalHostReplacementIfOwned(
            hostId: ObjectIdentifier(oldHost),
            reason: "test.old.retire"
        ))
        #expect(retryCount == 1)
        #expect(surface.claimPortalHost(
            hostId: ObjectIdentifier(replacementHost), paneId: pane, ownershipGeneration: 1,
            inWindow: true, bounds: bounds, reason: "test.replacement.commit"
        ))
        #expect(!surface.claimPortalHost(
            hostId: ObjectIdentifier(oldHost), paneId: pane, ownershipGeneration: 1,
            inWindow: true, bounds: bounds, reason: "test.old.stale"
        ))
    }

    @MainActor
    @Test
    func survivingSameEpochCandidateRetriesAfterLaterCandidateDismantles() {
        let surface = makeSurface()
        let oldHost = NSView(), firstCandidate = NSView(), laterCandidate = NSView()
        let pane = PaneID()
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)
        var firstRetryCount = 0
        var laterRetryCount = 0

        #expect(surface.claimPortalHost(
            hostId: ObjectIdentifier(oldHost), paneId: pane, ownershipGeneration: 1,
            inWindow: true, bounds: bounds, reason: "test.old.initial"
        ))
        #expect(!surface.claimPortalHost(
            hostId: ObjectIdentifier(firstCandidate), paneId: pane, ownershipGeneration: 1,
            inWindow: true, bounds: bounds,
            retryWhenAvailable: { firstRetryCount += 1 },
            reason: "test.first.wait"
        ))
        #expect(!surface.claimPortalHost(
            hostId: ObjectIdentifier(laterCandidate), paneId: pane, ownershipGeneration: 1,
            inWindow: true, bounds: bounds,
            retryWhenAvailable: { laterRetryCount += 1 },
            reason: "test.later.wait"
        ))

        surface.cancelPendingPortalHostRetry(hostId: ObjectIdentifier(laterCandidate))
        #expect(surface.preparePortalHostReplacementIfOwned(
            hostId: ObjectIdentifier(oldHost),
            reason: "test.old.retire"
        ))

        #expect(firstRetryCount == 1)
        #expect(laterRetryCount == 0)
    }

    @MainActor
    @Test
    func currentAuthorityCanRefreshWithoutCedingOwnership() {
        let surface = makeSurface()
        let host = NSView()
        let pane = PaneID()
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)

        #expect(surface.claimPortalHost(
            hostId: ObjectIdentifier(host), paneId: pane, ownershipGeneration: 1,
            inWindow: true, bounds: bounds, reason: "test.visible.initial"
        ))
        #expect(surface.claimPortalHost(
            hostId: ObjectIdentifier(host), paneId: pane, ownershipGeneration: 1,
            inWindow: true, bounds: bounds, reason: "test.current.refresh"
        ))
        #expect(
            surface.debugPortalHostLease().hostId ==
                String(describing: ObjectIdentifier(host))
        )
    }

    @MainActor
    @Test
    func newerModelOwnershipGenerationAllowsRollbackToEarlierHost() {
        let surface = makeSurface()
        let originalHost = NSView(), movedHost = NSView()
        let originalPane = PaneID(), movedPane = PaneID()
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)

        #expect(surface.claimPortalHost(
            hostId: ObjectIdentifier(originalHost), paneId: originalPane, ownershipGeneration: 1,
            inWindow: true, bounds: bounds, reason: "test.original.initial"
        ))
        #expect(surface.claimPortalHost(
            hostId: ObjectIdentifier(movedHost), paneId: movedPane, ownershipGeneration: 2,
            inWindow: true, bounds: bounds, reason: "test.move.commit"
        ))
        surface.releasePortalHostIfOwned(
            hostId: ObjectIdentifier(movedHost), reason: "test.move.rollback"
        )
        #expect(surface.claimPortalHost(
            hostId: ObjectIdentifier(originalHost), paneId: originalPane, ownershipGeneration: 3,
            inWindow: true, bounds: bounds, reason: "test.rollback.commit"
        ))
        #expect(
            surface.debugPortalHostLease().hostId ==
                String(describing: ObjectIdentifier(originalHost))
        )
    }

    @MainActor
    @Test
    func olderHostCannotReclaimAfterNewHostLeaseReleases() {
        let surface = makeSurface()
        let oldHost = NSView(), newHost = NSView()
        let oldPane = PaneID(), newPane = PaneID()
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)

        #expect(surface.claimPortalHost(
            hostId: ObjectIdentifier(oldHost), paneId: oldPane, ownershipGeneration: 1,
            inWindow: true, bounds: bounds, reason: "test.old.initial"
        ))
        #expect(surface.claimPortalHost(
            hostId: ObjectIdentifier(newHost), paneId: newPane, ownershipGeneration: 2,
            inWindow: true, bounds: bounds, reason: "test.new.bind"
        ))
        surface.releasePortalHostIfOwned(
            hostId: ObjectIdentifier(newHost), reason: "test.new.release"
        )
        #expect(!surface.claimPortalHost(
            hostId: ObjectIdentifier(oldHost), paneId: oldPane, ownershipGeneration: 1,
            inWindow: true, bounds: bounds, reason: "test.old.afterRelease"
        ))
    }
}
