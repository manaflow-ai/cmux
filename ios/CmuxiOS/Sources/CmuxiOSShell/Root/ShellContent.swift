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

    /// `home` is the existing Home screen in its navigation controller.
    /// `screens` are feature lanes' tab roots, injected by the composition
    /// root so the shell never imports a feature module; a tab without one
    /// shows its placeholder.
    public init(sources: FeatureSources, home: UIViewController, settings: ShellSettingsModel,
                screens: [ShellTab: @MainActor () -> UIViewController] = [:]) {
        self.sources = sources
        self.home = home
        self.settings = settings
        self.screens = screens
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
            return placeholder(tab, seam: .workspaces, summary: ShellText.workspacesSummary,
                               WorkspacesPlaceholder.stream(sources.workspaces, isMock: isMock(.workspaces)))
        case .compose:
            return placeholder(tab, seam: .composer, summary: ShellText.composeSummary,
                               ComposePlaceholder.stream(sources.composer, isMock: isMock(.composer)))
        case .hosts:
            return placeholder(tab, seam: .hosts, summary: ShellText.hostsSummary,
                               HostsPlaceholder.stream(sources.hosts, isMock: isMock(.hosts)))
        case .settings:
            let root = NavigationStack { ShellSettingsView(model: settings) }
            let hosting = UIHostingController(rootView: root)
            hosting.view.accessibilityIdentifier = "shell.settings"
            return hosting
        }
    }

    private func isMock(_ seam: FeatureSeam) -> Bool { sources.resolved[seam] != .real }

    private func placeholder(
        _ tab: ShellTab, seam: FeatureSeam, summary: String, _ stream: @escaping PlaceholderSnapshot.Factory
    ) -> UIViewController {
        let screen = FeaturePlaceholderViewController(tab: tab, lane: seam.lane, summary: summary, stream: stream)
        let navigation = UINavigationController(rootViewController: screen)
        navigation.navigationBar.prefersLargeTitles = true
        return navigation
    }
}
