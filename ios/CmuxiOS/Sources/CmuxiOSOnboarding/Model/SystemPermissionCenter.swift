import AVFoundation
public import CmuxiOSOnboardingCore
public import Foundation
import UserNotifications

/// Real permission prompts. Local network has no status API: the answer of
/// the probe that raised the prompt is remembered in `defaults`.
@MainActor
public final class SystemPermissionCenter: PermissionCenter {
    static let localNetworkKey = "dev.cmux.ios.next.onboarding.localNetwork"

    private let defaults: UserDefaults
    private let probe: LocalNetworkProbe
    private let onNotificationsGranted: @MainActor () -> Void

    /// `onNotificationsGranted` lets push registration continue after the
    /// notifications step granted permission.
    public init(
        defaults: UserDefaults, clock: any Clock<Duration>,
        onNotificationsGranted: @escaping @MainActor () -> Void
    ) {
        self.defaults = defaults
        probe = LocalNetworkProbe(clock: clock)
        self.onNotificationsGranted = onNotificationsGranted
    }

    public func status(of kind: PermissionKind) async -> PermissionStatus {
        switch kind {
        case .notifications:
            return Self.map(await Self.notificationStatus())
        case .localNetwork:
            return defaults.string(forKey: Self.localNetworkKey).flatMap(PermissionStatus.init(rawValue:)) ?? .notDetermined
        case .camera:
            return Self.map(AVCaptureDevice.authorizationStatus(for: .video))
        }
    }

    public func request(_ kind: PermissionKind) async -> PermissionStatus {
        switch kind {
        case .notifications:
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            if granted { onNotificationsGranted() }
            return granted ? .granted : .denied
        case .localNetwork:
            let answer = await probe.run()
            defaults.set(answer.rawValue, forKey: Self.localNetworkKey)
            return answer
        case .camera:
            return await AVCaptureDevice.requestAccess(for: .video) ? .granted : .denied
        }
    }

    private nonisolated static func notificationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    private static func map(_ status: UNAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        default: .granted
        }
    }

    private static func map(_ status: AVAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .notDetermined: .notDetermined
        case .authorized: .granted
        default: .denied
        }
    }
}
