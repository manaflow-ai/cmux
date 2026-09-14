import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for the post-#12505 Cloud startup path.
@Suite("Cloud terminal startup latency")
struct CloudTerminalStartupLatencyTests {
    @Test
    func readinessRetainsReplayAndFrameUntilAttachAcknowledges() {
        var readiness = CloudTerminalStartupReadiness()
        readiness.begin(baselineFrame: 40)
        readiness.markReplayApplied()
        #expect(!readiness.markFramePresented(
            sequence: 41,
            rendererPresented: true,
            effectivelyVisible: true
        ))
        #expect(readiness.markAttached())
        #expect(readiness.isReady)
    }

    @Test
    func hiddenReadinessDoesNotClaimReadyUntilAVisibleFrame() {
        var readiness = CloudTerminalStartupReadiness()
        readiness.begin(baselineFrame: 7)
        readiness.markAttached()
        readiness.markReplayApplied()
        #expect(!readiness.markFramePresented(
            sequence: 8,
            rendererPresented: true,
            effectivelyVisible: false
        ))
        #expect(!readiness.isReady)
        #expect(readiness.markFramePresented(
            sequence: 9,
            rendererPresented: true,
            effectivelyVisible: true
        ))
    }

    @Test @MainActor
    func unresolvedSurfaceCannotStartAnAttachStream() async throws {
        let fixture = try CloudManualMirrorSocketFixture()
        defer { fixture.close() }
        let session = CloudTuiManualMirrorSession(
            machineID: "machine",
            terminalID: "term_new-machine",
            remoteSurfaceID: 0,
            onNeedsReconnect: {}
        )
        defer { session.stop() }

        session.reconnect(socketPath: fixture.socketPath)

        #expect(session.phase == .idle)
        #expect(await fixture.nextCommand(timeout: .milliseconds(200)) == nil)
    }
}
