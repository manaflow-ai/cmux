import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for #12756: `cmux events --reconnect` exited with
/// `Failed to configure socket receive timeout (Invalid argument, errno 22)`
/// at the replay→live transition instead of reconnecting. A typed
/// receive-timeout configuration failure is a transport-level transient; the
/// reconnect loop must survive it.
@MainActor
struct EventStreamTransientErrorTests {
    @Test
    func receiveTimeoutReconfigurationFailureIsTransient() {
        let error = CLIError(
            message: "Failed to configure socket receive timeout (Invalid argument, errno 22)",
            socketFailureKind: .receiveTimeoutConfiguration
        )
        #expect(CMUXCLI(args: []).isTransientEventStreamError(error))
    }

    @Test
    func malformedFrameMentioningErrnoTextStaysFatal() {
        // Event *content* that happens to contain the old substring markers
        // must never be classified as transient: a malformed frame is a
        // protocol error and --reconnect must not retry it forever.
        let frameError = CLIError(message:
            "Invalid event stream frame: {\"text\":\"failed to configure socket receive timeout (Invalid argument, errno 22)\"}")
        #expect(!CMUXCLI(args: []).isTransientEventStreamError(frameError))
    }

    @Test
    func permanentProtocolErrorsStayFatal() {
        let error = CLIError(message: "Invalid event stream frame: not json")
        #expect(!CMUXCLI(args: []).isTransientEventStreamError(error))
    }
}
