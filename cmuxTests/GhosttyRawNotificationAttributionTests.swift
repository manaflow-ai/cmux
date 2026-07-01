import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Ghostty raw notification attribution")
struct GhosttyRawNotificationAttributionTests {
    @Test("Surface-less notifications are not attributed to the active workspace")
    func surfacelessNotificationIsNotAttributedToActiveWorkspace() {
        let activeWorkspace = UUID()
        #expect(
            GhosttyApp.rawNotificationRecordingTabId(surfaceTabId: nil, activeTabId: activeWorkspace) == nil,
            "A surface-less (app-target) notification has no known origin and must not fall back to the active workspace."
        )
    }

    @Test("Surface notifications are attributed to the emitting workspace")
    func surfaceNotificationIsAttributedToEmittingWorkspace() {
        let emittingWorkspace = UUID()
        let activeWorkspace = UUID()
        #expect(
            GhosttyApp.rawNotificationRecordingTabId(
                surfaceTabId: emittingWorkspace,
                activeTabId: activeWorkspace
            ) == emittingWorkspace
        )
    }
}
