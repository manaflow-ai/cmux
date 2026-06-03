import Darwin
import Testing

/// Mirrors how a real `CLIError` / `SocketConnectError` presents to the
/// classifier: it only inspects `String(describing:)`, so a stub with the same
/// text exercises the exact production path.
private struct StubError: Error, CustomStringConvertible {
    let description: String
}

@Suite struct CLISocketErrorClassificationTests {
    @Test func suppressesBrokenPipeWriteByErrno() {
        #expect(CLISocketErrorClassification.isExpectedTransportError(
            StubError(description: "Failed to write to socket (Broken pipe, errno 32)")
        ))
    }

    @Test func suppressesConnectionRefusedConnect() {
        #expect(CLISocketErrorClassification.isExpectedTransportError(
            StubError(description: "Failed to connect to socket at /tmp/cmux.sock (Connection refused, errno 61)")
        ))
    }

    @Test(arguments: [
        "Socket not found at /tmp/cmux.sock",
        "Not connected",
        "Socket closed before reply",
        "Socket closed before complete reply",
        "Command timed out",
        "Path exists at /tmp/cmux.sock but is not a Unix socket",
        "Socket at /tmp/cmux.sock is not owned by the current user — refusing to connect"
    ])
    func suppressesBenignTransportMessages(_ message: String) {
        #expect(CLISocketErrorClassification.isExpectedTransportError(StubError(description: message)))
    }

    @Test(arguments: [
        "Failed to write to socket (Input/output error, errno 5)", // EIO: genuinely unexpected
        "Invalid UTF-8 response",
        "Unexpected internal state",
        "Fatal error: index out of range",
        "EXC_BAD_ACCESS",
        ""
    ])
    func keepsUnexpectedErrors(_ message: String) {
        #expect(!CLISocketErrorClassification.isExpectedTransportError(StubError(description: message)))
    }

    @Test func parsesEmbeddedErrno() {
        #expect(CLISocketErrorClassification.embeddedErrno(in: "Broken pipe, errno 32") == 32)
        #expect(CLISocketErrorClassification.embeddedErrno(in: "no code here") == nil)
        #expect(CLISocketErrorClassification.embeddedErrno(in: "errno 61)") == 61)
    }

    @Test func errnoSetMatchesPosixConstants() {
        #expect(CLISocketErrorClassification.expectedTransportErrnos.contains(EPIPE))
        #expect(CLISocketErrorClassification.expectedTransportErrnos.contains(ECONNREFUSED))
        #expect(CLISocketErrorClassification.expectedTransportErrnos.contains(ENOENT))
        #expect(!CLISocketErrorClassification.expectedTransportErrnos.contains(EIO))
    }
}
