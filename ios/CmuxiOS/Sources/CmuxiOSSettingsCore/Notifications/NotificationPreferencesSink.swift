public import CmuxFeedPushCore
public import CmuxiOSFeatureKit

/// Seam for lane C7: delivers this device's notification preferences to the
/// push owner (B1's per-device push filter) and to the Notification Service
/// extension. The whole value is sent each time; the key makes a replay a no-op.
public protocol NotificationPreferencesSink: Sendable {
    func apply(_ preferences: NotificationPreferences, key: IntentKey) async throws -> IntentReceipt
}
