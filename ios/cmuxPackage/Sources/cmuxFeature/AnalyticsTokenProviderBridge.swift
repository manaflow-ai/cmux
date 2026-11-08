import CmuxAuthRuntime
import CmuxMobileAnalytics

/// Adapts the auth runtime's ``CmuxAuthRuntime/TokenProviding`` to mobile
/// telemetry's ``CmuxMobileAnalytics/AnalyticsTokenProviding``.
///
/// The analytics package must not depend on `CmuxAuthRuntime`, so this bridge
/// lives at the composition-root package and forwards the Stack bearer/refresh
/// tokens. Telemetry is best-effort, so a missing or failed access token resolves
/// to `nil`. Each uploader then applies its own anonymous or retry policy.
struct AnalyticsTokenProviderBridge: AnalyticsTokenProviding {
    private let tokenProvider: any TokenProviding

    /// Wraps an auth token provider (production: ``AuthCoordinator``).
    /// - Parameter tokenProvider: The auth runtime token source.
    init(tokenProvider: any TokenProviding) {
        self.tokenProvider = tokenProvider
    }

    /// Returns the current Stack access token, or `nil` when unavailable.
    func accessToken() async -> String? {
        try? await tokenProvider.accessToken()
    }

    /// Returns the current Stack refresh token, or `nil` when unavailable.
    func refreshToken() async -> String? {
        await tokenProvider.refreshToken()
    }
}
