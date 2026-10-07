import CmuxiOSOnboarding
import CmuxiOSOnboardingCore
import CmuxiOSSettingsCore

/// Settings' view of the notification permission over the app's permission
/// center, which also lets push registration continue after a grant.
@MainActor
final class SystemNotificationAuthorization: NotificationAuthorizationReading {
    private let permissions: any PermissionCenter

    init(permissions: any PermissionCenter) {
        self.permissions = permissions
    }

    func status() async -> NotificationAuthorization {
        Self.map(await permissions.status(of: .notifications))
    }

    func request() async -> NotificationAuthorization {
        Self.map(await permissions.request(.notifications))
    }

    private static func map(_ status: PermissionStatus) -> NotificationAuthorization {
        switch status {
        case .notDetermined: .notDetermined
        case .granted: .authorized
        case .denied: .denied
        }
    }
}
