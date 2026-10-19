import CmuxPhonePush
import Foundation
import OSLog
import UserNotifications

private let notificationServiceLog = Logger(
    subsystem: "ai.manaflow.cmux",
    category: "notification-service"
)

final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var deliveredContent: UNMutableNotificationContent?
    private var suppressOnExpiration = false

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ??
            UNMutableNotificationContent()
        deliveredContent = content
        guard let cmux = request.content.userInfo["cmux"] as? [String: Any],
              let raw = cmux["encryptedPayloads"] as? [[String: Any]] else {
            finish(content)
            return
        }
        suppressOnExpiration = true
        guard let installation = try? PhonePushKeyMaterial.current(
            bundleID: Bundle.main.object(forInfoDictionaryKey: "CMUXHostBundleIdentifier") as? String ?? "dev.cmux.ios",
            accessGroup: Bundle.main.object(forInfoDictionaryKey: "CMUXKeychainAccessGroup") as? String
        ) else {
            finishSuppressed(content, reason: "key_material_unavailable")
            return
        }
        let candidates = raw.compactMap { try? JSONSerialization.data(withJSONObject: $0) }
            .compactMap { try? JSONDecoder().decode(PhonePushEncryptedPayload.self, from: $0) }
        guard let envelope = candidates.first(where: {
            $0.installationID == installation.installationID
                && $0.tuple.iosInstallationID == installation.installationID
                && $0.tuple.iosBuildID == (Bundle.main.object(forInfoDictionaryKey: "CMUXHostBundleIdentifier") as? String ?? "dev.cmux.ios")
        }) else {
            finishSuppressed(content, reason: "no_envelope_for_installation")
            return
        }
        guard PhonePushActiveAccountStore().current() == envelope.tuple.accountID else {
            finishSuppressed(content, reason: "account_mismatch")
            return
        }
        guard let sender = PhonePushPeerKeyStore().pinnedDescriptor(for: envelope.tuple) else {
            finishSuppressed(content, reason: "sender_not_pinned")
            return
        }
        let senderPublicKey = sender.publicKey
        guard let data = try? PhonePushCrypto().decrypt(
            envelope: envelope,
            tuple: envelope.tuple,
            recipientInstallationID: installation.installationID,
            recipientKeyID: installation.keyID,
            trustedSenderKeyID: sender.keyID,
            senderPublicKey: senderPublicKey,
            privateKey: installation.privateKey
        ), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            finishSuppressed(content, reason: "decrypt_failed")
            return
        }
        guard let expiration = object["expirationEpochSeconds"] as? NSNumber,
              expiration.doubleValue > Date().timeIntervalSince1970 else {
            finishSuppressed(content, reason: "expired")
            return
        }
        if let title = object["title"] as? String { content.title = title }
        if let subtitle = object["subtitle"] as? String { content.subtitle = subtitle }
        if let body = object["body"] as? String { content.body = body }
        if let category = object["category"] as? String {
            content.categoryIdentifier = category
        }
        content.userInfo = Self.mergedUserInfo(
            original: request.content.userInfo,
            payload: object,
            macPushPublicKey: object["macPushPublicKey"] as? String
        )
        suppressOnExpiration = false
        finish(content)
    }

    override func serviceExtensionTimeWillExpire() {
        if suppressOnExpiration {
            finishSuppressed(deliveredContent ?? UNMutableNotificationContent(), reason: "time_expired")
        } else {
            finish(deliveredContent ?? UNMutableNotificationContent())
        }
    }

    private func finish(_ content: UNNotificationContent) {
        guard let contentHandler else { return }
        self.contentHandler = nil
        contentHandler(content)
    }

    /// Without the notification-filtering entitlement iOS ignores empty
    /// content and shows the payload's own alert. For a notify push that is
    /// the generic "An agent needs your attention" placeholder.
    private func finishSuppressed(_ content: UNMutableNotificationContent, reason: String) {
        notificationServiceLog.error("encrypted push not opened: \(reason, privacy: .public)")
        content.title = ""
        content.subtitle = ""
        content.body = ""
        content.sound = nil
        content.badge = nil
        content.categoryIdentifier = ""
        content.userInfo = [:]
        suppressOnExpiration = false
        finish(content)
    }

    private static func mergedUserInfo(
        original: [AnyHashable: Any],
        payload: [String: Any],
        macPushPublicKey: String?
    ) -> [AnyHashable: Any] {
        var result = original
        let originalCmux = (original["cmux"] as? [String: Any]) ?? [:]
        var cmux: [String: Any] = [:]
        for key in ["encryptedPayloads", "macDeviceId", "macInstanceTag", "correlationId"] {
            if let value = originalCmux[key] { cmux[key] = value }
        }
        for key in ["workspaceId", "surfaceId", "retargetsToLiveSurfaceOwner", "macDeviceId", "macInstanceTag", "macBuildID", "notificationId", "dismissedIds", "category", "macInstallationID", "macPushPublicKey"] {
            if let value = payload[key] { cmux[key] = value }
        }
        if let notificationIds = payload["notificationIds"] {
            cmux["dismissedIds"] = notificationIds
        }
        if let macPushPublicKey { cmux["macPushPublicKey"] = macPushPublicKey }
        if let macInstallationID = payload["macInstallationID"] as? String {
            cmux["macInstallationID"] = macInstallationID
        }
        result["cmux"] = cmux
        return result
    }
}
