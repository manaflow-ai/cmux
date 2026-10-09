public import CmuxiOSFeatureKit
public import UIKit
import SwiftUI

/// Builds each tab's root controller from the feature seams. Lanes replace
/// their placeholder here with their screen, keeping the seam they get.
@MainActor
public struct ShellContent {
    private let sources: FeatureSources
    private let home: UIViewController
    private let settings: ShellSettingsModel
    private let screens: [ShellTab: @MainActor () -> UIViewController]
    private let surfaces: SurfaceScreenFactories

    /// `home` is the existing Home screen in its navigation controller.
    /// `screens` are feature lanes' tab roots, injected by the composition
    /// root so the shell never imports a feature module; a tab without one
    /// shows its placeholder.
    /// `surfaces` opens workspace surfaces (a Mac browser tab) from the
    /// Workspaces tab until lane C5 replaces it.
    public init(sources: FeatureSources, home: UIViewController, settings: ShellSettingsModel,
                screens: [ShellTab: @MainActor () -> UIViewController] = [:],
                surfaces: SurfaceScreenFactories = SurfaceScreenFactories()) {
        self.sources = sources
        self.home = home
        self.settings = settings
        self.screens = screens
        self.surfaces = surfaces
    }

    public func controller(for tab: ShellTab) -> UIViewController {
        if let screen = screens[tab] { return screen() }
        switch tab {
        case .home:
            return home
        case .feed:
            return placeholder(tab, seam: .feed, summary: ShellText.feedSummary,
                               FeedPlaceholder.stream(sources.feed, isMock: isMock(.feed)))
        case .workspaces:
            guard let browser = surfaces.browser else {
                return placeholder(tab, seam: .workspaces, summary: ShellText.workspacesSummary,
                                   WorkspacesPlaceholder.stream(sources.workspaces, isMock: isMock(.workspaces)))
            }
            let source = sources.browser
            let stream = WorkspacesPlaceholder.stream(sources.workspaces, browser: source, isMock: isMock(.workspaces))
            return placeholder(tab, seam: .workspaces, summary: ShellText.workspacesSummary, stream) { section, row in
                guard row.hasPrefix(WorkspacesPlaceholder.browserRowPrefix) else { return nil }
                let id = String(row.dropFirst(WorkspacesPlaceholder.browserRowPrefix.count))
                let host = HostID(rawValue: section)
                return browser(BrowserTabInfo(id: id, workspaceID: nil, title: id, url: nil), host)
            }
        case .compose:
            return placeholder(tab, seam: .composer, summary: ShellText.composeSummary,
                               ComposePlaceholder.stream(sources.composer, isMock: isMock(.composer)))
        case .hosts:
            return placeholder(tab, seam: .hosts, summary: ShellText.hostsSummary,
                               HostsPlaceholder.stream(sources.hosts, isMock: isMock(.hosts)))
        case .search:
            // Lane C15 injects the search screen; without it the tab says so.
            let screen = UIViewController()
            var empty = UIContentUnavailableConfiguration.search()
            empty.text = ShellTab.search.title
            screen.contentUnavailableConfiguration = empty
            screen.title = ShellTab.search.title
            return UINavigationController(rootViewController: screen)
        case .cloud:
            // Lane C12 injects its screen; without it the tab shows its title only.
            let screen = UIViewController()
            screen.title = tab.title
            screen.view.backgroundColor = .systemGroupedBackground
            return UINavigationController(rootViewController: screen)
        case .settings:
            let root = NavigationStack { ShellSettingsView(model: settings) }
            let hosting = UIHostingController(rootView: root)
            hosting.view.accessibilityIdentifier = "shell.settings"
            return hosting
        }
    }

    private func isMock(_ seam: FeatureSeam) -> Bool { sources.resolved[seam] != .real }

    private func placeholder(
        _ tab: ShellTab, seam: FeatureSeam, summary: String, _ stream: @escaping PlaceholderSnapshot.Factory,
        open: ((_ section: String, _ row: String) -> UIViewController?)? = nil
    ) -> UIViewController {
        let screen = FeaturePlaceholderViewController(tab: tab, lane: seam.lane, summary: summary, stream: stream, open: open)
        let navigation = UINavigationController(rootViewController: screen)
        navigation.navigationBar.prefersLargeTitles = true
        return navigation
    }
}
