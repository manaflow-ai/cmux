import CMUXMobileCore
import CmuxAuthRuntime
import CmuxMobileBilling
import Foundation

/// Builds the app's one ``CmuxMobileBilling/BillingModel`` over the auth
/// composition.
///
/// Billing calls the same web origin and native Stack bearer auth as the
/// other account routes (`auth.config.apiBaseURL`). Build it once at the app
/// composition root and call `start()` at launch, so the StoreKit
/// `Transaction.updates` listener runs for the whole process lifetime.
///
/// ```swift
/// let billing = MobileBillingComposition(auth: auth).makeModel(analytics: analytics.emitter)
/// billing?.start()
/// ```
public struct MobileBillingComposition {
    private let auth: MobileAuthComposition
    private let bundleIdentifier: String?

    /// Creates the composition.
    /// - Parameters:
    ///   - auth: The constructed auth graph.
    ///   - bundleIdentifier: The app bundle id sent as `x-cmux-bundle-id`;
    ///     the server derives `<bundleId>.<plan>.monthly` product ids from it.
    public init(auth: MobileAuthComposition, bundleIdentifier: String?) {
        self.auth = auth
        self.bundleIdentifier = bundleIdentifier
    }

    /// Builds the billing model, or nil when the build has no API origin or
    /// bundle id.
    /// - Parameter analytics: The product analytics emitter.
    /// - Returns: The model; the caller starts it.
    @MainActor
    public func makeModel(analytics: any AnalyticsEmitting) -> BillingModel? {
        let baseURL = auth.config.apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baseURL.isEmpty, let bundleIdentifier, !bundleIdentifier.isEmpty else { return nil }
        let coordinator = auth.coordinator
        let api = HTTPBillingAPI(
            baseURL: baseURL,
            bundleID: bundleIdentifier,
            credentials: {
                guard await coordinator.isAuthenticated else { return nil }
                do {
                    let pair = try await coordinator.coherentTokenPair()
                    return BillingAPICredentials(accessToken: pair.accessToken, refreshToken: pair.refreshToken)
                } catch AuthError.unauthorized {
                    return nil
                }
            },
            storeKitEnvironment: { await LiveStoreKitClient.appStoreEnvironment() },
            session: URLSession(configuration: .default)
        )
        return BillingModel(api: api, store: LiveStoreKitClient(), analytics: analytics)
    }
}
