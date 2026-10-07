import CmuxiOSAuth
import CmuxiOSComposer
import CmuxiOSFeatureKit
import CmuxiOSFeed
import CmuxiOSSettingsCore
import CmuxiOSShell
import CmuxiOSSSH
import CmuxiOSWorkspaces
import UIKit

/// Builds the signed-in shell from the container: Home in its navigation
/// controller, the feature tabs over the account's seams, and Settings.
@MainActor
enum ShellComposition {
    static func makeShell(
        container: AppContainer, account: SignedInAccount, home: UIViewController,
        replayTour: @escaping @MainActor () -> Void
    ) -> ShellRootController {
        let sources = container.featureSources(for: account)
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
        // Lane C5: the Workspaces tab; terminals open over C1's sources once
        // registered, else the mock host. `workspaces.makePicker` is the
        // picker the composer (C8) presents.
        let workspaces = WorkspacesFeature(
            source: sources.workspaces, terminalSources: container.terminalSources ?? MockWorkspaceTerminalSourceFactory(),
            isMock: sources.resolved[.workspaces] != .real)
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
        let content = ShellContent(sources: sources, home: home, settings: settings, screens: [
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
        ])
        let shell = ShellRootController(
            tabs: container.flags.visibleTabs,
            sidebar: container.flags.isEnabled(.iPadSidebar),
            content: { content.controller(for: $0) }
        )
        shellBox.controller = shell
        return shell
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
