import CmuxPhonePush
import Foundation
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ??
            UNMutableNotificationContent()
        guard let cmux = request.content.userInfo["cmux"] as? [String: Any],
              let raw = cmux["encryptedPayloads"] as? [[String: Any]],
              let installation = try? PhonePushKeyStore.current(
                  bundleID: Bundle.main.object(forInfoDictionaryKey: "CMUXHostBundleIdentifier") as? String ?? "dev.cmux.ios",
                  accessGroup: Bundle.main.object(forInfoDictionaryKey: "CMUXKeychainAccessGroup") as? String
              ) else {
            contentHandler(request.content)
            return
        }
        let candidates = raw.compactMap { try? JSONSerialization.data(withJSONObject: $0) }
            .compactMap { try? JSONDecoder().decode(PhonePushEncryptedPayload.self, from: $0) }
        guard let envelope = candidates.first(where: { $0.installationID == installation.installationID }),
              let macDeviceID = cmux["macDeviceId"] as? String else {
            contentHandler(request.content)
            return
        }
        let tuple = PhonePushDeviceTuple(
            accountID: nil,
            teamID: nil,
            iosBuildID: Bundle.main.object(forInfoDictionaryKey: "CMUXHostBundleIdentifier") as? String ?? "dev.cmux.ios",
            iosInstallationID: installation.installationID,
            macDeviceID: macDeviceID,
            macInstanceTag: cmux["macInstanceTag"] as? String,
            macBuildID: nil
        )
        guard let data = try? PhonePushCrypto.decrypt(
            envelope: envelope,
            tuple: tuple,
            privateKey: installation.privateKey
        ), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            contentHandler(request.content)
            return
        }
        if let title = object["title"] as? String { content.title = title }
        if let subtitle = object["subtitle"] as? String { content.subtitle = subtitle }
        if let body = object["body"] as? String { content.body = body }
        content.userInfo = Self.mergedUserInfo(
            original: request.content.userInfo,
            payload: object,
            macPushPublicKey: cmux["macPushPublicKey"] as? String
        )
        contentHandler(content)
    }

    override func serviceExtensionTimeWillExpire() {
        if let contentHandler { contentHandler(content ?? UNNotificationContent()) }
    }

    private var content: UNMutableNotificationContent?

    private static func mergedUserInfo(
        original: [AnyHashable: Any],
        payload: [String: Any],
        macPushPublicKey: String?
    ) -> [AnyHashable: Any] {
        var result = original
        var cmux = (original["cmux"] as? [String: Any]) ?? [:]
        for key in ["workspaceId", "surfaceId", "retargetsToLiveSurfaceOwner", "macDeviceId", "macInstanceTag", "notificationId"] {
            if let value = payload[key] { cmux[key] = value }
        }
        if let macPushPublicKey { cmux["macPushPublicKey"] = macPushPublicKey }
        result["cmux"] = cmux
        return result
    }
}
