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
    func terminalCreationFailuresKeepTheirKnownCause() {
        #expect(CloudDiagnosticFailure.classify(CmuxTuiSurfaceProvider.ProviderError.remoteTabNotFound("tab_source")) == .notFound)
        #expect(CloudDiagnosticFailure.classify(CmuxTuiSurfaceProvider.ProviderError.invalidSnapshot("machine")) == .response)
        #expect(CloudDiagnosticFailure.classify(CmuxTuiSurfaceProvider.ProviderError.terminalAttachTimedOut(
            terminalID: "term_created", failure: .transportUnavailable
        )) == .timeout)
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
