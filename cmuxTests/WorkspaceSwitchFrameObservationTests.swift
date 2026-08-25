import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct WorkspaceSwitchFrameObservationTests {
    private final class ReleaseProbe {
        var didRelease = false
    }

    @Test
    func deinitRemovesObserverAndReleasesFrameDemand() {
        let notificationCenter = NotificationCenter()
        let notificationName = Notification.Name("WorkspaceSwitchFrameObservationTests.frame")
        let releaseProbe = ReleaseProbe()
        let observer = notificationCenter.addObserver(
            forName: notificationName,
            object: nil,
            queue: nil
        ) { _ in
            Issue.record("Observer must be removed when its owner deinitializes")
        }
        var observation: WorkspaceSwitchFrameObservation? =
            WorkspaceSwitchFrameObservation(
                notificationCenter: notificationCenter,
                observer: observer,
                releaseRenderedFrameNotifications: {
                    releaseProbe.didRelease = true
                }
            )

        #expect(observation != nil)
        #expect(!releaseProbe.didRelease)
        observation = nil

        #expect(releaseProbe.didRelease)
        notificationCenter.post(name: notificationName, object: nil)
    }

    @Test
    func sourceRetirementReleasesUnresolvedFrameDemand() {
        let notificationCenter = NotificationCenter()
        let sourceWorkspaceID = UUID()
        let targetWorkspaceID = UUID()
        let targetSurfaceID = UUID()
        let targetView = GhosttyNSView(frame: .zero)
        let coordinator = WorkspaceSwitchCoordinator(
            notificationCenter: notificationCenter,
            beginRendererProtection: { _, _, _ in },
            endRendererProtection: { _ in }
        )

        coordinator.selectionWillCommit(
            from: sourceWorkspaceID,
            to: targetWorkspaceID,
            targetSurfaceID: targetSurfaceID,
            targetTerminalView: targetView,
            targetRendererPresented: false,
            targetRenderedFrameSequence: 0
        )
        coordinator.beginPresentation(
            WorkspaceSwitchPresentationTarget(
                workspaceID: targetWorkspaceID,
                contentKind: .terminal,
                terminalSurfaceID: targetSurfaceID,
                terminalView: targetView,
                terminalRendererPresented: false,
                terminalRenderedFrameSequence: 0,
                browserWebView: nil,
                portalPresented: false,
                interactionReady: false,
                requiresInteraction: true
            ),
            retiringWorkspaceID: sourceWorkspaceID
        )

        #expect(targetView.localRenderedFrameNotificationDemandIsActive)
        coordinator.sourceDidRetire(workspaceID: sourceWorkspaceID)
        #expect(!targetView.localRenderedFrameNotificationDemandIsActive)
        #expect(!coordinator.isMeasuringSwitch)
    }
}
