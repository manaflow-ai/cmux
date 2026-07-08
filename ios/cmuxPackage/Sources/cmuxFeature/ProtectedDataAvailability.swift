import Foundation
import UIKit

@MainActor
final class ProtectedDataAvailability {
    private let notificationCenter: NotificationCenter
    private let availabilityRead: @MainActor () -> Bool
    private var observer: NSObjectProtocol?

    init(
        notificationCenter: NotificationCenter = .default,
        availabilityRead: @escaping @MainActor () -> Bool = {
            UIApplication.shared.isProtectedDataAvailable
        }
    ) {
        self.notificationCenter = notificationCenter
        self.availabilityRead = availabilityRead
    }

    var isAvailable: Bool {
        availabilityRead()
    }

    func startObserving(onBecameAvailable: @escaping @MainActor () -> Void) {
        stopObserving()
        observer = notificationCenter.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                onBecameAvailable()
            }
        }
    }

    func stopObserving() {
        if let observer {
            notificationCenter.removeObserver(observer)
            self.observer = nil
        }
    }

    deinit {
        if let observer {
            notificationCenter.removeObserver(observer)
        }
    }
}
