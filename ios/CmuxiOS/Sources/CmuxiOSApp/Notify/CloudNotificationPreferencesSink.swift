import CmuxFeedPushCore
import CmuxiOSFeatureKit
import CmuxiOSSettingsCore
import Foundation

/// C11's notification preferences sink (c7-notify.md section 4): hands the
/// value to the Notification Service extension through the shared store and
/// sends `push.prefs.set` to the push owner (UserDO, per install), which
/// filters what it sends to this device.
struct CloudNotificationPreferencesSink: NotificationPreferencesSink {
    let ops: any CloudOpsSending
    let share: NotificationPreferencesShare

    func apply(_ preferences: NotificationPreferences, key: IntentKey) async throws -> IntentReceipt {
        // The extension filters even when the owner is unreachable.
        share.save(preferences)
        do {
            try await ops.send(.setPushPreferences(preferences, idempotencyKey: "push-prefs-\(key.rawValue)"))
        } catch CloudOpsError.rejected(let code, retryable: false) {
            return .refused(key: key, reason: code)
        } catch CloudOpsError.notConfigured, CloudOpsError.installTokenUnavailable {
            throw FeatureSourceError.offline
        }
        return .committed(key: key, revision: 0)
    }
}
