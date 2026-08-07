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
            queue: .main
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
}
