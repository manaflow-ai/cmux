import CmuxiOSAuth
import CmuxiOSBrowser
import CmuxiOSComposer
import CmuxiOSFeatureKit
import CmuxiOSFeed
import CmuxiOSSearch
import CmuxiOSSearchCore
import CmuxiOSSettingsCore
import CmuxiOSShell
import CmuxiOSSSH
import CmuxiOSViewers
import CmuxiOSWorkspaces
import UIKit

/// Builds the signed-in shell from the container: Home in its navigation
/// controller, the feature tabs over the account's seams, and Settings.
@MainActor
enum ShellComposition {
    static func makeShell(
        container: AppContainer, account: SignedInAccount, home: UIViewController,
        searchOpener: any SearchOpening, replayTour: @escaping @MainActor () -> Void
    ) -> (shell: ShellRootController, features: ShellFeatures) {
        let sources = container.featureSources(for: account)
        // Lane C4: built with the seams so background transfer handling runs
        // for the whole signed-in session.
        _ = container.filesFeature(for: sources)
        let settings = ShellSettingsModel(
            account: ShellAccount(displayName: account.displayName, email: account.email),
            about: ShellAbout.current(),
            registry: sources.devices,
            developer: developerScreen(container: container),
            links: PlatformComposition.settingsLinks(container: container),
            replayTour: replayTour,
            accountController: StackAccountController(gate: container.auth),
            linkDiagnostics: linkDiagnostics(container: container, sources: sources),
            terminal: container.terminalPreferences,
            notifications: container.notificationPreferences,
            notificationAuthorization: SystemNotificationAuthorization(permissions: container.permissions),
            privacy: container.privacy,
            signOut: { [weak container] in await container?.auth.signOut() }
        )
        // Lane C9: the Hosts tab over this account's host records and the
        // device's SSH logins, keys and pinned host keys; terminals follow
        // the device's terminal settings (C11).
        let ssh = SSHFeature(hosts: sources.hosts, device: container.sshDevice,
                             appearance: container.terminalPreferences)
        // Lane C6: the Feed tab over the account's feed seam.
        let feedSource = sources.feed
        let feedIsMock = sources.resolved[.feed] != .real
        let feedNavigator = container.feedNavigator
        let deviceName = UIDevice.current.name
        // Lane C2: Mac browser tabs open from workspace surfaces over the browser seam.
        let browser = BrowserFeature(source: sources.browser, isMock: sources.resolved[.browser] != .real)
        // Lane C5: the Workspaces tab; real Macs' terminals open over C1's
        // link sources, mock workspaces over A2's mock host. `workspaces.makePicker` is the
        // picker the composer (C8) presents.
        let workspacesAreReal = sources.resolved[.workspaces] == .real
        let terminalSources = workspacesAreReal ? container.terminalSources : nil
        let workspaces = WorkspacesFeature(
            source: sources.workspaces, terminalSources: terminalSources ?? MockWorkspaceTerminalSourceFactory(),
            // Real Macs' browser tabs need the real browser seam; mock tabs open on the mock.
            surfaces: sources.resolved[.browser] == .real || !workspacesAreReal ? browser.surfaceFactories : SurfaceScreenFactories(),
            appearance: container.terminalPreferences,
            isMock: !workspacesAreReal)
        // Lane C13: Changes and Files in the workspace detail, and the viewer
        // for finished downloads.
        workspaces.viewers = WorkspaceViewersAdapter(feature: container.viewersFeature(for: sources, real: workspacesAreReal))
        // Lane C8: the Compose tab and the floating compose button over Feed
        // and Workspaces. The picker and "open workspace" are C5's, passed as
        // closures so the composer never imports the Workspaces feature.
        let shellBox = WeakControllerBox()
        let composer = ComposerFeature(
            sink: sources.composer,
            makePicker: { request, completion in workspaces.makePicker(request: request, completion: completion) },
            openWorkspace: { hostID, workspaceID in
                guard let shell = shellBox.controller as? ShellRootController, shell.select(.workspaces) else { return }
                workspaces.open(hostID: hostID, workspaceID: workspaceID)
            },
            isMock: sources.resolved[.composer] != .real)
        let floatingCompose = container.flags.isEnabled(.composeTab)
        // Lane C15: universal search over the same seams.
        let search = SearchComposition.makeFeature(
            sources: sources, visibleTabs: container.flags.visibleTabs, opener: searchOpener)
        let content = ShellContent(sources: sources, home: home, settings: settings, screens: [
            .search: { search.makeSearchScreen() },
            .hosts: { ssh.makeHostsScreen() },
            .workspaces: {
                let screen = workspaces.makeWorkspacesScreen()
                if floatingCompose, let navigation = screen as? UINavigationController {
                    composer.installFloatingButton(on: navigation)
                }
                return screen
            },
            .compose: { composer.makeComposeScreen() },
            .feed: {
                let feed = FeedViewController(source: feedSource, navigator: feedNavigator, isMock: feedIsMock, device: deviceName)
                let navigation = UINavigationController(rootViewController: feed)
                navigation.navigationBar.prefersLargeTitles = true
                if floatingCompose { composer.installFloatingButton(on: navigation) }
                return navigation
            },
        ], surfaces: browser.surfaceFactories)
        let shell = ShellRootController(
            tabs: container.flags.visibleTabs,
            sidebar: container.flags.isEnabled(.iPadSidebar),
            content: { content.controller(for: $0) }
        )
        shellBox.controller = shell
        return (shell, ShellFeatures(workspaces: workspaces, ssh: ssh, settings: settings, search: search))
    }

    /// Live link badges per device: the real owner once B5/D1 register it;
    /// the mock badges only while the device list itself is mocked, so real
    /// devices never show fake paths.
    static func linkDiagnostics(container: AppContainer, sources: FeatureSources) -> (any LinkDiagnosticsSource)? {
        if let factory = container.linkDiagnosticsFactory { return factory() }
        return sources.resolved[.devices] == .mock ? MockLinkDiagnosticsSource() : nil
    }

    /// The DEV sources screen; nil in Release so Settings has no Developer row.
    static func developerScreen(container: AppContainer) -> (@MainActor () -> DevSourcesModel)? {
        #if DEBUG
        // The container lives for the process (CmuxiOSApplication), and it
        // never holds the shell, so a strong capture makes no cycle.
        return { devModel(container: container) }
        #else
        return nil
        #endif
    }

    static func devModel(container: AppContainer) -> DevSourcesModel {
        let registered = Set(FeatureSeam.allCases.filter(container.realFactories.isRegistered))
        return DevSourcesModel(
            flags: container.flags, modes: container.sourceModes, registered: registered,
            mockOffline: container.mockOffline,
            setMockOffline: { [weak container] offline in await container?.setMockOffline(offline) }
        )
    }

    /// DEBUG: `CMUX_IOS_SHELL_TAB=<tab>` opens that tab at launch (screenshots).
    static func selectLaunchTab(in shell: ShellRootController) {
        #if DEBUG
        guard let raw = ProcessInfo.processInfo.environment["CMUX_IOS_SHELL_TAB"],
              let tab = ShellTab(rawValue: raw) else { return }
        shell.select(tab)
        #endif
    }
}
