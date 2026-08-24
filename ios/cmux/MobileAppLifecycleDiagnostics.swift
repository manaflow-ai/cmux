import CMUXMobileCore
import UIKit

/// Owns app-wide UIKit lifecycle observations outside the application delegate.
///
/// Each callback records only a fixed diagnostic event. The observer tokens are
/// removed by ``stop()`` when the composition root shuts down (the live backend
/// switch), with `deinit` as the backstop, so no task or notification callback
/// can outlive the app graph that supplied its log.
final class MobileAppLifecycleDiagnostics: @unchecked Sendable {
    private let notificationCenter: NotificationCenter
    // Mutated only by MainActor `stop()` and, after the last reference is
    // gone, by `deinit`; the two can never run concurrently.
    private var observers: [NSObjectProtocol]

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

    /// Removes the lifecycle observers with the app graph. Before the live
    /// backend switch existed, removal happened only in `deinit`; a rebuilt
    /// root must not leave the old graph's observers recording into a
    /// diagnostic log nothing reads anymore.
    @MainActor
    func stop() {
        for observer in observers {
            notificationCenter.removeObserver(observer)
        }
        observers = []
    }

    deinit {
        for observer in observers {
            notificationCenter.removeObserver(observer)
        }
    }
}
