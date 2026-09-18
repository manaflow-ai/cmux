import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV

/// `update_channel` on every PostHog event: the `updates.channel` selection that tells an
/// RC-channel install apart from a stable one sharing the same bundle id.
@Suite
struct PostHogUpdateChannelPropertyTests {
    /// RC and stable share one bundle id, so `channel` (build flavor) cannot tell an
    /// RC-channel install apart; `update_channel` carries the `updates.channel` selection.
    @Test
    func versionPropertiesCarryTheSelectedUpdateChannel() {
        let info: [String: Any] = ["CFBundleShortVersionString": "0.31.0", "CFBundleVersion": "230"]
        #expect(PostHogAnalytics.superProperties(infoDictionary: info)["update_channel"] as? String == "stable")
        #expect(PostHogAnalytics.superProperties(infoDictionary: info, updateChannel: .rc)["update_channel"] as? String == "rc")
        #expect(PostHogAnalytics.dailyActiveProperties(dayUTC: "2026-02-21", reason: "r", infoDictionary: info, updateChannel: .rc)["update_channel"] as? String == "rc")
        #expect(PostHogAnalytics.hourlyActiveProperties(hourUTC: "2026-02-21T14", reason: "r", infoDictionary: info, updateChannel: .rc)["update_channel"] as? String == "rc")
        #expect(PostHogAnalytics.crashExceptionProperties(reported: nil, infoDictionary: info, updateChannel: .rc)["update_channel"] as? String == "rc")
        // `channel` (build flavor) is untouched by the selection.
        #expect((PostHogAnalytics.superProperties(infoDictionary: info, updateChannel: .rc)["channel"] as? String)?.isEmpty == false)
    }
}
#endif
