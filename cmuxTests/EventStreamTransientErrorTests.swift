import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for #12756: `cmux events --reconnect` exited with
/// `Failed to configure socket receive timeout (Invalid argument, errno 22)`
/// at the replay→live transition instead of reconnecting. A timeout
/// reconfiguration hiccup is a transport-level transient, so the reconnect
/// loop must survive it.
@MainActor
struct EventStreamTransientErrorTests {
    @Test
    func receiveTimeoutReconfigurationEINVALIsTransient() {
        let error = CLIError(message:
            "Failed to configure socket receive timeout (Invalid argument, errno 22)")
        #expect(CMUXCLI(args: []).isTransientEventStreamError(error))
    }

    @Test
    func permanentProtocolErrorsStayFatal() {
        let error = CLIError(message: "Invalid event stream frame: not json")
        #expect(!CMUXCLI(args: []).isTransientEventStreamError(error))
    }
}
