#if os(iOS)
import CmuxMobileCamera
import CmuxMobileSimulatorStream
import CmuxMobileTerminal
import Foundation
import Testing

@testable import cmuxFeature

@Suite struct MobileSessionReplayMaskingTests {
    /// Pins the privacy contract: every content surface that renders through
    /// Metal, video, or raw layer pixels must stay in the session-replay mask
    /// list. Removing one silently unmasks that surface in uploaded replays.
    @Test func maskListCoversEveryContentSurface() {
        let masked = MobileSessionReplayMasking.maskedViewClasses

        #expect(masked.contains { $0 == GhosttySurfaceView.self })
        // Internal to its package; identified by runtime name instead.
        #expect(masked.contains { NSStringFromClass($0).contains("BrowserStreamContentView") })
        #expect(masked.contains { $0 == SimStreamDisplayView.self })
        #expect(masked.contains { $0 == CameraPreviewHostView.self })
        #expect(masked.count == 4)
    }
}
#endif
