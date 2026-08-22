import CMUXMobileCore
@_exported import CmuxMobileCampaigns
public import Foundation

/// Builds the app-root campaign center and bridges its events onto the
/// analytics emitter. Lives here (not in `CmuxMobileCampaigns`) so the
/// campaigns package stays analytics-agnostic.
public enum MobileCampaignComposition {
    /// - Parameters:
    ///   - apiBaseURL: The cmux web API base URL, from ``MobileAuthComposition``.
    ///   - rolloutKey: The per-install anonymous id minted by the analytics
    ///     composition, reused so percentage rollouts and analytics describe
    ///     the same install.
    ///   - analytics: The shared app emitter.
    @MainActor
    public static func makeCenter(
        apiBaseURL: String,
        rolloutKey: String,
        analytics: any AnalyticsEmitting
    ) -> MobileCampaignCenter {
        MobileCampaignCenter(
            apiBaseURL: apiBaseURL,
            appVersionString: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            rolloutKey: rolloutKey,
            reporter: CampaignAnalyticsBridge(emitter: analytics)
        )
    }
}

/// Maps campaign lifecycle events onto the allowlisted `ios_campaign_*`
/// analytics events (see the web proxy's `iosEventPolicy.ts`).
@MainActor
struct CampaignAnalyticsBridge: CampaignEventReporting {
    let emitter: any AnalyticsEmitting

    func campaignEvent(_ event: CampaignEvent) {
        switch event {
        case let .impression(campaignID, template):
            emitter.capture("ios_campaign_impression", [
                "campaign_id": .string(campaignID),
                "template": .string(template),
            ])
        case let .dismissed(campaignID, source):
            emitter.capture("ios_campaign_dismissed", [
                "campaign_id": .string(campaignID),
                "source": .string(source),
            ])
        case let .buttonTapped(campaignID, actionType):
            emitter.capture("ios_campaign_button_tapped", [
                "campaign_id": .string(campaignID),
                "action_type": .string(actionType),
            ])
        case let .whatsNewOpened(count):
            emitter.capture("ios_whats_new_opened", [
                "campaign_count": .int(count),
            ])
        }
    }
}
