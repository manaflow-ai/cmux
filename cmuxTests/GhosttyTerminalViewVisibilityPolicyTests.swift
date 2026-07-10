import XCTest
import AppKit
import Bonsplit
import CmuxTerminal

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class GhosttyTerminalViewVisibilityPolicyTests: XCTestCase {
    @MainActor
    func testPortalMutationSchedulerDefersCommitPastCurrentCallback() async {
        let scheduler = TerminalPortalMutationScheduler()
        var didCommit = false

        let commit = scheduler.schedule {
            didCommit = true
        }

        XCTAssertFalse(didCommit)
        await commit.value
        XCTAssertTrue(didCommit)
    }

    @MainActor
    func testPortalMutationSchedulerCommitsOnlyLatestGeneration() async {
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
        XCTAssertEqual(committedValues, [2])
    }

    @MainActor
    func testPortalMutationSchedulerOriginalDrainIncludesFollowUpScheduledDuringCommit() async {
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
        XCTAssertFalse(originalDrainWasCancelled)
        XCTAssertEqual(
            committedValues,
            [1, 2],
            "A commit-triggered update must stay on the live drain instead of replacing it"
        )
    }

    @MainActor
    func testPortalMutationSchedulerCancelInvalidatesPendingCommit() async {
        let scheduler = TerminalPortalMutationScheduler()
        var didCommit = false

        let commit = scheduler.schedule {
            didCommit = true
        }
        scheduler.cancel()

        await commit.value
        XCTAssertFalse(didCommit)
    }

    func testImmediateStateUpdateAllowedWhenDesiredStateIsHidden() {
        XCTAssertTrue(
            GhosttyTerminalView.shouldApplyImmediateHostedStateUpdate(
                desiredVisibleInUI: false,
                hostedViewHasSuperview: true,
                isBoundToCurrentHost: false
            )
        )
    }

    func testImmediateStateUpdateAllowedWhenBoundToCurrentHost() {
        XCTAssertTrue(
            GhosttyTerminalView.shouldApplyImmediateHostedStateUpdate(
                desiredVisibleInUI: true,
                hostedViewHasSuperview: true,
                isBoundToCurrentHost: true
            )
        )
    }

    func testImmediateStateUpdateSkippedForStaleHostBoundElsewhere() {
        XCTAssertFalse(
            GhosttyTerminalView.shouldApplyImmediateHostedStateUpdate(
                desiredVisibleInUI: true,
                hostedViewHasSuperview: true,
                isBoundToCurrentHost: false
            )
        )
    }

    func testImmediateStateUpdateAllowedWhenUnboundAndNotAttachedAnywhere() {
        XCTAssertTrue(
            GhosttyTerminalView.shouldApplyImmediateHostedStateUpdate(
                desiredVisibleInUI: true,
                hostedViewHasSuperview: false,
                isBoundToCurrentHost: false
            )
        )
    }

    func testSwiftUIHostGeometryCallbackDefersPortalMutationUntilAfterLayout() {
        switch GhosttyTerminalView.hostCallbackPortalGeometrySynchronizationAction(window: 3873) {
        case .synchronizeWithoutLayoutFlush:
            XCTFail("A host callback must not mutate the portal during SwiftUI layout")
        case .skip:
            break
        }
    }

    func testSwiftUIHostGeometryCallbackSkipsWithoutWindow() {
        switch GhosttyTerminalView.hostCallbackPortalGeometrySynchronizationAction(window: Optional<Int>.none) {
        case .synchronizeWithoutLayoutFlush:
            XCTFail("Detached host callbacks must not synchronize terminal portal geometry")
        case .skip:
            break
        }
    }
}

@MainActor
final class TerminalPortalHostAuthorityTests: XCTestCase {
    private func makeSurface() -> TerminalSurface {
        TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
    }

    func testOlderHostCannotStealLeaseAfterNewHostBinds() {
        let surface = makeSurface()
        let oldHost = NSView(), newHost = NSView()
        let oldPane = PaneID(), newPane = PaneID()
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)

        XCTAssertTrue(surface.claimPortalHost(
            hostId: ObjectIdentifier(oldHost), paneId: oldPane, instanceSerial: 1,
            inWindow: true, bounds: bounds, reason: "test.old.initial"
        ))
        XCTAssertTrue(surface.claimPortalHost(
            hostId: ObjectIdentifier(newHost), paneId: newPane, instanceSerial: 2,
            inWindow: true, bounds: bounds, reason: "test.new.bind"
        ))
        XCTAssertFalse(surface.claimPortalHost(
            hostId: ObjectIdentifier(oldHost), paneId: oldPane, instanceSerial: 1,
            inWindow: true, bounds: bounds, reason: "test.old.delayed"
        ))
        XCTAssertEqual(
            surface.debugPortalHostLease().hostId,
            String(describing: ObjectIdentifier(newHost))
        )
    }

    func testDetachedHostCannotReplaceLiveHost() {
        let surface = makeSurface()
        let oldHost = NSView(), newHost = NSView()
        let oldPane = PaneID(), newPane = PaneID()
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)

        XCTAssertTrue(surface.claimPortalHost(
            hostId: ObjectIdentifier(oldHost), paneId: oldPane, instanceSerial: 1,
            inWindow: true, bounds: bounds, reason: "test.old.initial"
        ))
        XCTAssertFalse(surface.claimPortalHost(
            hostId: ObjectIdentifier(newHost), paneId: newPane, instanceSerial: 2,
            inWindow: false, bounds: bounds, reason: "test.new.detached"
        ))
        XCTAssertEqual(
            surface.debugPortalHostLease().hostId,
            String(describing: ObjectIdentifier(oldHost))
        )
        XCTAssertTrue(surface.claimPortalHost(
            hostId: ObjectIdentifier(oldHost), paneId: oldPane, instanceSerial: 1,
            inWindow: true, bounds: bounds, reason: "test.old.afterDetachedCandidate"
        ))
        XCTAssertTrue(surface.claimPortalHost(
            hostId: ObjectIdentifier(newHost), paneId: newPane, instanceSerial: 2,
            inWindow: true, bounds: bounds, reason: "test.new.attached"
        ))
        XCTAssertEqual(
            surface.debugPortalHostLease().hostId,
            String(describing: ObjectIdentifier(newHost))
        )
    }

    func testOlderHostCannotReclaimAfterNewHostLeaseReleases() {
        let surface = makeSurface()
        let oldHost = NSView(), newHost = NSView()
        let oldPane = PaneID(), newPane = PaneID()
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 300)

        XCTAssertTrue(surface.claimPortalHost(
            hostId: ObjectIdentifier(oldHost), paneId: oldPane, instanceSerial: 1,
            inWindow: true, bounds: bounds, reason: "test.old.initial"
        ))
        XCTAssertTrue(surface.claimPortalHost(
            hostId: ObjectIdentifier(newHost), paneId: newPane, instanceSerial: 2,
            inWindow: true, bounds: bounds, reason: "test.new.bind"
        ))
        surface.releasePortalHostIfOwned(
            hostId: ObjectIdentifier(newHost), reason: "test.new.release"
        )
        XCTAssertFalse(surface.claimPortalHost(
            hostId: ObjectIdentifier(oldHost), paneId: oldPane, instanceSerial: 1,
            inWindow: true, bounds: bounds, reason: "test.old.afterRelease"
        ))
    }
}
