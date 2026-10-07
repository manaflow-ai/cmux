import CmuxiOSFeatureKit
import CmuxiOSWebCore
import WebKit

/// The open tunnel routes of the app, one per machine while any of its
/// screens is open. Each route has its own non-persistent data store, so
/// cookies and storage never mix across machines or with other browsing,
/// and the store holds the route's token cookie.
@MainActor
final class WebRoutes {
    final class Entry {
        let route: WebRoute
        let store: WKWebsiteDataStore
        let onStop: @Sendable () async -> Void
        var users = 0

        init(route: WebRoute, store: WKWebsiteDataStore, onStop: @escaping @Sendable () async -> Void) {
            self.route = route
            self.store = store
            self.onStop = onStop
        }
    }

    private var entries: [WebRouteID: Entry] = [:]

    func acquire(_ target: WebTarget, dialer: any TunnelDialer) -> Entry {
        if let entry = entries[target.id] {
            entry.users += 1
            return entry
        }
        let entry = Entry(route: WebRoute(id: target.id, dialer: dialer), store: .nonPersistent(), onStop: target.onStop)
        entry.users = 1
        entries[target.id] = entry
        return entry
    }

    func entry(_ id: WebRouteID) -> Entry? {
        entries[id]
    }

    func release(_ id: WebRouteID) {
        guard let entry = entries[id] else { return }
        entry.users -= 1
        guard entry.users <= 0 else { return }
        entries[id] = nil
        let route = entry.route
        let onStop = entry.onStop
        Task {
            await route.stop()
            await onStop()
        }
    }
}
