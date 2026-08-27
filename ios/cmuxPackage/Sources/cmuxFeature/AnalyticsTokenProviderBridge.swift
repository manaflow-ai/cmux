import CmuxAuthRuntime
import CmuxMobileAnalytics

/// Adapts the auth runtime's ``CmuxAuthRuntime/TokenProviding`` to the analytics
/// package's ``CmuxMobileAnalytics/AnalyticsTokenProviding``.
///
/// The analytics package must not depend on `CmuxAuthRuntime`, so this bridge
/// lives at the composition-root package and forwards the Stack bearer/refresh
/// tokens. Analytics is best-effort, so a missing or failed access token resolves
/// to `nil` (the uploader posts anonymously or the proxy drops it) rather than
/// throwing.
struct AnalyticsTokenProviderBridge: AnalyticsTokenProviding {
    private let tokenProvider: any TokenProviding

    /// Wraps an auth token provider (production: ``AuthCoordinator``).
    /// - Parameter tokenProvider: The auth runtime token source.
    init(tokenProvider: any TokenProviding) {
        self.tokenProvider = tokenProvider
    }

    func accessToken() async -> String? {
        try? await tokenProvider.accessToken()
    }

    func refreshToken() async -> String? {
        await tokenProvider.refreshToken()
    }
}
