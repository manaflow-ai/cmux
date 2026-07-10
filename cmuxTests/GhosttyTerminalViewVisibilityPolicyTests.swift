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
    func olderHostCannotStealLeaseAfterNewHostBinds() {
        let surface = makeSurface()
        let oldHost = NSView(), newHost = NSView()
        let oldPane = PaneID(), newPane = PaneID()
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)

        #expect(surface.claimPortalHost(
            hostId: ObjectIdentifier(oldHost), paneId: oldPane, instanceSerial: 1,
            inWindow: true, bounds: bounds, reason: "test.old.initial"
        ))
        #expect(surface.claimPortalHost(
            hostId: ObjectIdentifier(newHost), paneId: newPane, instanceSerial: 2,
            inWindow: true, bounds: bounds, reason: "test.new.bind"
        ))
        #expect(!surface.claimPortalHost(
            hostId: ObjectIdentifier(oldHost), paneId: oldPane, instanceSerial: 1,
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
            hostId: ObjectIdentifier(oldHost), paneId: oldPane, instanceSerial: 1,
            inWindow: true, bounds: bounds, reason: "test.old.initial"
        ))
        #expect(!surface.claimPortalHost(
            hostId: ObjectIdentifier(newHost), paneId: newPane, instanceSerial: 2,
            inWindow: false, bounds: bounds, reason: "test.new.detached"
        ))
        #expect(
            surface.debugPortalHostLease().hostId ==
                String(describing: ObjectIdentifier(oldHost))
        )
        #expect(surface.claimPortalHost(
            hostId: ObjectIdentifier(oldHost), paneId: oldPane, instanceSerial: 1,
            inWindow: true, bounds: bounds, reason: "test.old.afterDetachedCandidate"
        ))
        #expect(surface.claimPortalHost(
            hostId: ObjectIdentifier(newHost), paneId: newPane, instanceSerial: 2,
            inWindow: true, bounds: bounds, reason: "test.new.attached"
        ))
        #expect(
            surface.debugPortalHostLease().hostId ==
                String(describing: ObjectIdentifier(newHost))
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
            hostId: ObjectIdentifier(oldHost), paneId: oldPane, instanceSerial: 1,
            inWindow: true, bounds: bounds, reason: "test.old.initial"
        ))
        #expect(surface.claimPortalHost(
            hostId: ObjectIdentifier(newHost), paneId: newPane, instanceSerial: 2,
            inWindow: true, bounds: bounds, reason: "test.new.bind"
        ))
        surface.releasePortalHostIfOwned(
            hostId: ObjectIdentifier(newHost), reason: "test.new.release"
        )
        #expect(!surface.claimPortalHost(
            hostId: ObjectIdentifier(oldHost), paneId: oldPane, instanceSerial: 1,
            inWindow: true, bounds: bounds, reason: "test.old.afterRelease"
        ))
    }
}
