import CmuxMobileContract
import Foundation

// MobileAnalyticsEventName, MobileAnalyticsTeamKind, MobileAnalyticsProperties,
// MobileAnalyticsTracking, and MobileAnalyticsClient now live in CmuxMobileContract. The app-side
// convenience initializer below supplies the Environment + AuthManager + bundle id defaults the
// call sites rely on.

extension MobileAnalyticsClient {
    convenience init(
        baseURL: URL = URL(string: Environment.current.apiBaseURL)!,
        session: URLSession = .shared,
        authManager: AuthManager? = nil,
        platform: String = "ios",
        bundleId: String? = Bundle.main.bundleIdentifier
    ) {
        self.init(
            baseURL: baseURL,
            session: session,
            tokenProvider: authManager ?? AuthManager.shared,
            platform: platform,
            bundleId: bundleId
        )
    }
}
