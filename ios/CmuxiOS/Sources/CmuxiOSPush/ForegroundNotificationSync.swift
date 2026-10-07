public import CmuxiOSFeatureKit
import CmuxiOSNotifyCore
import UIKit
import UserNotifications

/// When the app comes to the front, takes the feed mirror's first live
/// snapshot and makes iOS agree with it: the badge is the owner's count and
/// banners for items that no longer need the user go (c7-notify.md
/// section 3). Background dismiss pushes are throttled by iOS; this is the
/// path that always runs. Leaving the front cancels it; nothing polls.
/// One instance lives for the app's lifetime (the composition root).
@MainActor
public final class ForegroundNotificationSync {
    private let source: @MainActor () -> (any FeedSource)?
    private var task: Task<Void, Never>?
    private var observers: [any NSObjectProtocol] = []

    /// `source` answers the signed-in account's feed seam (nil while signed out).
    public init(source: @escaping @MainActor () -> (any FeedSource)?) {
        self.source = source
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.run() }
        })
        observers.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancel() }
        })
    }

    public func run() {
        task?.cancel()
        guard let source = source() else { return }
        task = Task {
            for await snapshot in await source.updates() {
                guard !Task.isCancelled else { return }
                guard snapshot.connection.isLive else { continue }
                await Self.apply(FeedNotificationReconciler(items: snapshot.value))
                return
            }
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
    }

    private static func apply(_ reconciler: FeedNotificationReconciler) async {
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications().map(\.request.identifier)
        let stale = reconciler.staleIdentifiers(delivered: delivered)
        if !stale.isEmpty { center.removeDeliveredNotifications(withIdentifiers: stale) }
        try? await center.setBadgeCount(reconciler.badge)
    }
}
