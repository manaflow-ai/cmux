import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct SentryEventNoiseFilterTests {
    @Test(arguments: [
        "socket.listener.start.failed",
        "socket.listener.unhealthy",
        "socket.listener.accept.failed",
        "Scroll lag detected"
    ])
    func dropsOperationalNoise(_ message: String) {
        #expect(SentryEventNoiseFilter.shouldDrop(message: message))
    }

    /// Crashes and app-hang (ANR) reports do not carry these messages, so the
    /// filter must never drop them. This is the guardrail that keeps the quota
    /// fix from silencing the signal it exists to protect.
    @Test(arguments: [
        "App Hanging: App hanging for at least 8000 ms.",
        "EXC_BAD_ACCESS",
        "Fatal error: Unexpectedly found nil while unwrapping an Optional value",
        "SIGSEGV",
        "ghostty initialization failed",
        "Failed to write to socket"
    ])
    func keepsCrashesAndRealErrors(_ message: String) {
        #expect(!SentryEventNoiseFilter.shouldDrop(message: message))
    }

    @Test func keepsEventsWithoutMessage() {
        #expect(!SentryEventNoiseFilter.shouldDrop(message: nil))
    }
}
