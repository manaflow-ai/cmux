import CMUXMobileCore
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct MobileHostRenderCaptureRevisionTests {
    @Test func testRenderCaptureRevisionStaysStableWhenTheSameFrameIsReplayed() {
        let surfaceID = UUID()
        let first = MobileTerminalByteTee.shared.nextRenderCaptureIdentity(surfaceID: surfaceID)
        let replay = MobileTerminalByteTee.shared.nextRenderCaptureIdentity(surfaceID: surfaceID)
        #expect(replay.epoch == first.epoch)
        #expect(replay.revision == first.revision)
    }
}
