public import CmuxiOSSearchCore
public import UIKit

/// Lane C15's entry point: the Search tab root, the modal search Cmd-K
/// presents when the tab is hidden, and focusing the field from a route.
/// The composition root makes one per shell; providers wrap the account's
/// seams, so search never holds state of its own beyond recents.
@MainActor
public final class SearchFeature {
    let providers: [any SearchProvider]
    let catalog: SearchCatalog
    let recents: RecentSearchesStore
    let clock: any Clock<Duration>
    let opener: any SearchOpening
    private weak var tabScreen: SearchViewController?
    /// A focus asked for before the tab's screen existed.
    private var parkedFocus: String??

    public init(providers: [any SearchProvider], catalog: SearchCatalog, opener: any SearchOpening,
                recents: RecentSearchesStore = RecentSearchesStore(), clock: any Clock<Duration> = ContinuousClock()) {
        self.providers = providers
        self.catalog = catalog
        self.opener = opener
        self.recents = recents
        self.clock = clock
    }

    /// The Search tab root (a navigation controller with large titles).
    public func makeSearchScreen() -> UIViewController {
        let screen = SearchViewController(feature: self, isModal: false)
        tabScreen = screen
        if let parked = parkedFocus {
            parkedFocus = nil
            screen.focus(query: parked)
        }
        let navigation = UINavigationController(rootViewController: screen)
        navigation.navigationBar.prefersLargeTitles = true
        return navigation
    }

    /// Search as a sheet (Cmd-K while the Search tab is hidden). Present it;
    /// opening a result dismisses it first.
    public func makeModalSearch(query: String? = nil) -> UIViewController {
        let screen = SearchViewController(feature: self, isModal: true)
        screen.focus(query: query)
        return UINavigationController(rootViewController: screen)
    }

    /// Focuses the Search tab's field, optionally with `query` typed. The
    /// tab must be selected first; a screen not built yet focuses on appear.
    public func focus(query: String? = nil) {
        if let tabScreen { tabScreen.focus(query: query) } else { parkedFocus = .some(query) }
    }

    /// Whether the Search tab's screen exists (it is built on first selection).
    public var hasTabScreen: Bool { tabScreen != nil }

    func makeSession() -> SearchSession {
        SearchSession(providers: providers, clock: clock)
    }

    /// Records the query, then opens the destination.
    func open(_ destination: SearchDestination, query: String) {
        recents.record(query)
        opener.open(destination)
    }
}
