import CmuxiOSAuth
import CmuxiOSFeatureKit
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
            signOut: { [weak container] in await container?.auth.signOut() }
        )
        // Lane C9: the Hosts tab over this account's host records and the
        // device's SSH logins, keys and pinned host keys.
        let ssh = SSHFeature(hosts: sources.hosts, device: container.sshDevice)
        // Lane C5: the Workspaces tab; terminals open over C1's sources once
        // registered, else the mock host. `workspaces.makePicker` is the
        // picker the composer (C8) presents.
        let workspaces = WorkspacesFeature(
            source: sources.workspaces, terminalSources: container.terminalSources ?? MockWorkspaceTerminalSourceFactory(),
            isMock: sources.resolved[.workspaces] != .real)
        let content = ShellContent(sources: sources, home: home, settings: settings,
                                   screens: [.hosts: { ssh.makeHostsScreen() },
                                             .workspaces: { workspaces.makeWorkspacesScreen() }])
        return ShellRootController(
            tabs: container.flags.visibleTabs,
            sidebar: container.flags.isEnabled(.iPadSidebar),
            content: { content.controller(for: $0) }
        )
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
