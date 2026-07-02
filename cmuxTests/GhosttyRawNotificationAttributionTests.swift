import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Ghostty raw notification attribution")
struct GhosttyRawNotificationAttributionTests {
    @Test("Surface-less notifications are not attributed to any workspace")
    func surfacelessNotificationRecordsNothing() {
        #expect(
            GhosttyApp.rawNotificationRecordingTabId(surfaceTabId: nil) == nil,
            "A surface-less (app-target) notification has no known origin and must record nothing."
        )
    }

    @Test("Surface notifications are attributed to the emitting workspace")
    func surfaceNotificationIsAttributedToEmittingWorkspace() {
        let emittingWorkspace = UUID()
        #expect(GhosttyApp.rawNotificationRecordingTabId(surfaceTabId: emittingWorkspace) == emittingWorkspace)
    }
}
