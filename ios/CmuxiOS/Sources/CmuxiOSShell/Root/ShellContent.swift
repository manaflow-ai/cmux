public import CmuxiOSFeatureKit
public import CmuxiOSFeed
public import UIKit
import SwiftUI

/// Builds each tab's root controller from the feature seams. Lanes replace
/// their placeholder here with their screen, keeping the seam they get.
@MainActor
public struct ShellContent {
    private let sources: FeatureSources
    private let home: UIViewController
    private let settings: ShellSettingsModel
    private let feedNavigator: FeedNavigator?
    private let deviceName: String?

    /// `home` is the existing Home screen in its navigation controller.
    /// `feedNavigator` opens feed items from push taps; `deviceName` is
    /// stamped on answers sent from this device.
    public init(sources: FeatureSources, home: UIViewController, settings: ShellSettingsModel,
                feedNavigator: FeedNavigator? = nil, deviceName: String? = nil) {
        self.sources = sources
        self.home = home
        self.settings = settings
        self.feedNavigator = feedNavigator
        self.deviceName = deviceName
    }

    public func controller(for tab: ShellTab) -> UIViewController {
        switch tab {
        case .home:
            return home
        case .feed:
            let feed = FeedViewController(source: sources.feed, navigator: feedNavigator,
                                          isMock: isMock(.feed), device: deviceName)
            let navigation = UINavigationController(rootViewController: feed)
            navigation.navigationBar.prefersLargeTitles = true
            return navigation
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
