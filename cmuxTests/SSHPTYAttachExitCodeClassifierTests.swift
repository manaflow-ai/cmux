import Testing

@Suite struct SSHPTYAttachExitCodeClassifierTests {
    @Test(arguments: [
        "Command timed out",
        "request timeout",
        "remote daemon did not respond in time",
        "remote connection is not active",
        "remote daemon is not ready",
        "remote daemon tunnel is not ready",
        "pty_input_queue_full",
        "pty input queue is full",
        // Canonical app-side mapping of the daemon's input-queue-full error
        // (v2RemotePTYUserFacingErrorMessage / RemotePTYBridgeStrings inputBackedUp).
        "remote PTY input is temporarily backed up",
        "connection refused",
        "connection reset by peer",
    ])
    func transientDescriptionsExitRetryable(_ description: String) {
        #expect(
            SSHPTYAttachExitCode.classifyBridgeEstablishmentFailure(description) ==
                SSHPTYAttachExitCode.retryableTransient
        )
    }

    @Test(arguments: [
        "pty_session_not_found",
        "persistent SSH PTY session abc is not running",
        // Canonical app-side RPC message from v2RemotePTYUserFacingErrorMessage.
        "persistent SSH PTY session is no longer running",
    ])
    func sessionNotFoundDescriptionsExitForRespawn(_ description: String) {
        #expect(
            SSHPTYAttachExitCode.classifyBridgeEstablishmentFailure(description) ==
                SSHPTYAttachExitCode.sessionNotFound
        )
    }

    @Test func remotePTYErrorCodeWithSessionLostMessageExitsForRespawn() {
        // The v2 RPC wraps session loss in the generic remote_pty_error code;
        // the canonical message must still classify as session-not-found.
        #expect(
            SSHPTYAttachExitCode.classifyBridgeEstablishmentFailure(
                code: "remote_pty_error",
                message: "persistent SSH PTY session is no longer running"
            ) == SSHPTYAttachExitCode.sessionNotFound
        )
    }

    @Test func remotePTYErrorCodeWithTransientMessageStaysRetryable() {
        // remote_pty_error also wraps transient shapes, so the generic code
        // itself must never force a classification; the message decides.
        #expect(
            SSHPTYAttachExitCode.classifyBridgeEstablishmentFailure(
                code: "remote_pty_error",
                message: "remote connection is not active"
            ) == SSHPTYAttachExitCode.retryableTransient
        )
    }

    @Test(arguments: [
        "missing required capability: pty.session",
        "method_not_found",
        "ssh-pty-attach: unknown flag",
        "invalid bridge status",
        "arbitrary text",
    ])
    func fatalDescriptionsStayFatal(_ description: String) {
        #expect(
            SSHPTYAttachExitCode.classifyBridgeEstablishmentFailure(description) ==
                SSHPTYAttachExitCode.fatal
        )
    }

    @Test func classifierIsCaseInsensitive() {
        #expect(
            SSHPTYAttachExitCode.classifyBridgeEstablishmentFailure("REMOTE CONNECTION IS NOT ACTIVE") ==
                SSHPTYAttachExitCode.retryableTransient
        )
    }

    @Test func bridgeStatusSessionNotFoundCodeExitsForRespawn() {
        #expect(
            SSHPTYAttachExitCode.classifyBridgeEstablishmentFailure(
                code: "pty_session_not_found",
                message: "remote PTY attach failed"
            ) == SSHPTYAttachExitCode.sessionNotFound
        )
    }

    @Test func closedLifecycleCodeOverridesTransientMessage() {
        #expect(
            SSHPTYAttachExitCode.classifyBridgeEstablishmentFailure(
                code: "pty_lifecycle_closed",
                message: "remote daemon tunnel is not ready"
            ) == SSHPTYAttachExitCode.fatal
        )
    }
}
