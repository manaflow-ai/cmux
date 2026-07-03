#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
extension MarkdownWebRenderer.Coordinator {
    var isShellLoadingForTesting: Bool {
        isShellLoading
    }

    var webContentProcessRecoveryAttemptsForTesting: Int {
        webContentProcessRecoveryAttempts
    }
}
