import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Cloud manual mirror presentation")
struct CloudManualMirrorPresentationTests {
    @Test
    func attachedPaneNeedsReplayAndRendererBeforeHidingItsStatus() {
        #expect(CloudTuiManualMirrorPresentationPolicy.connectionState(
            phase: .attached, replayReceived: false, rendererReady: true
        ) == .connecting)
        #expect(CloudTuiManualMirrorPresentationPolicy.connectionState(
            phase: .attached, replayReceived: true, rendererReady: false
        ) == .error)
        #expect(CloudTuiManualMirrorPresentationPolicy.connectionState(
            phase: .attached, replayReceived: true, rendererReady: true
        ) == .connected)
    }

    /// A failed numeric-surface resolution must remain recoverable. The provider
    /// cannot attach with a stale id, but fencing the stream must schedule the
    /// next authoritative refresh rather than strand the visible tab.
    @Test @MainActor
    func unavailableSurfaceResolutionRequestsRefresh() {
        var reconnectRequests = 0
        let session = CloudTuiManualMirrorSession(
            machineID: "machine",
            terminalID: "term_0123456789abcdef0123456789abcdef",
            remoteSurfaceID: 17,
            onNeedsReconnect: { reconnectRequests += 1 }
        )
        session.markSurfaceResolutionUnavailable()
        #expect(reconnectRequests == 1)
        session.stop()
    }
}
