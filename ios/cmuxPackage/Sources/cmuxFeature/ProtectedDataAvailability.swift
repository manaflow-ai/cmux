import Foundation
import UIKit

@MainActor
final class ProtectedDataAvailability {
    private let notificationCenter: NotificationCenter
    private let availabilityRead: @MainActor () -> Bool
    private var observer: ProtectedDataAvailabilityObserverToken?

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
        let token = notificationCenter.addObserver(
            forName: UIApplication.protectedDataDidBecomeAvailableNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                onBecameAvailable()
            }
        }
        observer = ProtectedDataAvailabilityObserverToken(
            token: token,
            notificationCenter: notificationCenter
        )
    }

    func stopObserving() {
        if let observer {
            observer.remove()
            self.observer = nil
        }
    }

    deinit {
        if let observer {
            observer.remove()
        }
    }
}

/// NotificationCenter observer token owned and removed on the main actor.
final class ProtectedDataAvailabilityObserverToken: @unchecked Sendable {
    // Safety: the token is created, stored, and removed by
    // ProtectedDataAvailability on the main actor. The wrapper is Sendable only
    // so the @MainActor owner can touch it from deinit under Swift 6 checking;
    // it does not permit cross-actor mutation of the token.
    private let token: NSObjectProtocol
    private let notificationCenter: NotificationCenter

    init(token: NSObjectProtocol, notificationCenter: NotificationCenter) {
        self.token = token
        self.notificationCenter = notificationCenter
    }

    func remove() {
        notificationCenter.removeObserver(token)
    }
}
