import CmuxMobileRPC
import Foundation
import UIKit

/// Keeps background launches and protected-data transitions out of dial ownership.
@MainActor
public final class MobileConnectionLifecycle: MobileConnectionReadinessProviding {
    private let applicationState: @MainActor () -> UIApplication.State
    private let protectedDataAvailable: @MainActor () -> Bool
    private var hasBeenActive: Bool
    private var dataAvailable: Bool
    private var observers: [ProtectedDataAvailabilityObserverToken] = []
    private var subscribers: [UUID: AsyncStream<Bool>.Continuation] = [:]

    public init(
        notificationCenter: NotificationCenter = .default,
        applicationState: @escaping @MainActor () -> UIApplication.State = { UIApplication.shared.applicationState },
        protectedDataAvailable: @escaping @MainActor () -> Bool = { UIApplication.shared.isProtectedDataAvailable }
    ) {
        self.applicationState = applicationState
        self.protectedDataAvailable = protectedDataAvailable
        hasBeenActive = applicationState() == .active
        dataAvailable = protectedDataAvailable()
        for name in [UIApplication.didBecomeActiveNotification, UIApplication.didEnterBackgroundNotification,
                     UIApplication.protectedDataDidBecomeAvailableNotification,
                     UIApplication.protectedDataWillBecomeUnavailableNotification] {
            let token = notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                // Capture the Sendable name before crossing the main-actor seam.
                let notificationName = note.name
                MainActor.assumeIsolated { self?.update(for: notificationName) }
            }
            observers.append(ProtectedDataAvailabilityObserverToken(token: token, notificationCenter: notificationCenter))
        }
    }

    public var permitsConnection: Bool {
        (hasBeenActive || applicationState() == .active) && applicationState() != .background
            && dataAvailable && protectedDataAvailable()
    }

    public func changes() -> AsyncStream<Bool> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
        subscribers[id] = continuation
        continuation.yield(permitsConnection)
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.subscribers[id] = nil }
        }
        return stream
    }

    private func update(for notification: Notification.Name) {
        if applicationState() == .active { hasBeenActive = true }
        dataAvailable = notification != UIApplication.protectedDataWillBecomeUnavailableNotification
            && protectedDataAvailable()
        for subscriber in subscribers.values { subscriber.yield(permitsConnection) }
    }

    deinit {
        for observer in observers { observer.remove() }
        for subscriber in subscribers.values { subscriber.finish() }
    }
}
