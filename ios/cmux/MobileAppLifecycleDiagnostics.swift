import CMUXMobileCore
import UIKit

/// Owns app-wide UIKit lifecycle observations outside the application delegate.
///
/// Each callback records only a fixed diagnostic event. The observer tokens are
/// removed with the composition root, so no task or notification callback can
/// outlive the app graph that supplied its log.
final class MobileAppLifecycleDiagnostics: @unchecked Sendable {
    private let notificationCenter: NotificationCenter
    private let observers: [NSObjectProtocol]

    init(
        diagnosticLog: DiagnosticLog,
        notificationCenter: NotificationCenter = .default
    ) {
        self.notificationCenter = notificationCenter
        let events: [(Notification.Name, DiagnosticAppEventKind)] = [
            (UIApplication.didReceiveMemoryWarningNotification, .appMemoryWarningReceived),
            (UIApplication.protectedDataWillBecomeUnavailableNotification, .appProtectedDataUnavailable),
            (UIApplication.protectedDataDidBecomeAvailableNotification, .appProtectedDataAvailable),
            (UIApplication.userDidTakeScreenshotNotification, .appScreenshotCaptured),
        ]
        self.observers = events.map { name, event in
            notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: nil
            ) { _ in
                diagnosticLog.recordAppEvent(event)
            }
        }
    }

    deinit {
        for observer in observers {
            notificationCenter.removeObserver(observer)
        }
    }
}
