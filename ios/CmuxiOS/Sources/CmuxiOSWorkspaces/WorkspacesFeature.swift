public import CmuxiOSFeatureKit
public import CmuxiOSWorkspacesCore
import CmuxiOSTerminal
public import UIKit

/// Lane C5's entry point: the Workspaces tab over a `WorkspaceSource`, the
/// workspace detail, terminals through the injected source factory (C1),
/// and the picker the composer presents (C8). The composition root makes
/// one per shell.
@MainActor
public final class WorkspacesFeature {
    public let source: any WorkspaceSource
    let terminalSources: any WorkspaceTerminalSourceFactory
    /// Screens for non-terminal surfaces (C2: a Mac browser tab).
    let surfaces: SurfaceScreenFactories
    let isMock: Bool
    private let store: WorkspaceViewPreferencesStore
    /// Client view state: filter, sort, grouping, hidden and ordered Macs.
    private(set) var preferences: WorkspaceViewPreferences
    /// The list re-renders when the machines sheet changes preferences.
    var onPreferencesChange: (() -> Void)?
    private weak var navigation: UINavigationController?

    public init(source: any WorkspaceSource, terminalSources: any WorkspaceTerminalSourceFactory,
                surfaces: SurfaceScreenFactories = SurfaceScreenFactories(),
                preferences: WorkspaceViewPreferencesStore = WorkspaceViewPreferencesStore(), isMock: Bool = false) {
        self.source = source
        self.terminalSources = terminalSources
        self.surfaces = surfaces
        self.isMock = isMock
        store = preferences
        self.preferences = preferences.load()
    }

    var actions: WorkspaceActions { WorkspaceActions(source: source) }

    /// Offline reasons for the control-plane channels (B1).
    public static var controlPlaneReasons: ControlPlaneChannelReasons {
        ControlPlaneChannelReasons(
            macOffline: String(localized: "workspaces.reason.mac-offline", defaultValue: "Mac is offline", bundle: .module),
            macSleeping: String(localized: "workspaces.reason.sleeping", defaultValue: "Asleep", bundle: .module),
            macPaused: String(localized: "workspaces.reason.paused", defaultValue: "Paused", bundle: .module),
            signedOut: String(localized: "workspaces.reason.signed-out", defaultValue: "Sign in to reach your Macs", bundle: .module),
            refused: String(localized: "workspaces.reason.refused", defaultValue: "Connection refused", bundle: .module))
    }

    /// The offline reason the real source shows while no control-plane
    /// client is registered (B1).
    public static var controlPlaneUnavailable: String {
        String(localized: "workspaces.control-plane.unavailable", defaultValue: "Control plane unavailable", bundle: .module)
    }

    /// The Workspaces tab root (a navigation controller with large titles).
    public func makeWorkspacesScreen() -> UIViewController {
        let list = WorkspaceListViewController(feature: self)
        let navigation = UINavigationController(rootViewController: list)
        navigation.navigationBar.prefersLargeTitles = true
        self.navigation = navigation
        return navigation
    }

    /// The workspace picker for the composer: present the returned
    /// controller modally (not pushed); `completion` gets the choice (nil
    /// when cancelled or swiped away) exactly once, after the picker
    /// dismissed itself.
    public func makePicker(request: WorkspacePickerRequest,
                           completion: @escaping @MainActor (WorkspaceSelection?) -> Void) -> UIViewController {
        let picker = WorkspacePickerViewController(
            source: source, request: request, model: WorkspacePickerModel(preferences: preferences), completion: completion)
        return UINavigationController(rootViewController: picker)
    }

    /// Shows a workspace (notification tap, deep link): pops to the list
    /// and pushes its detail.
    public func open(hostID: HostID, workspaceID: WorkspaceSummary.ID) {
        guard let navigation else { return }
        navigation.popToRootViewController(animated: false)
        navigation.pushViewController(WorkspaceDetailViewController(feature: self, hostID: hostID, workspaceID: workspaceID),
                                      animated: true)
    }

    // MARK: Routes

    func showDetail(hostID: HostID, workspaceID: WorkspaceSummary.ID, from presenter: UIViewController) {
        presenter.navigationController?.pushViewController(
            WorkspaceDetailViewController(feature: self, hostID: hostID, workspaceID: workspaceID), animated: true)
    }

    func openTerminal(_ target: WorkspaceTerminalTarget, from presenter: UIViewController) {
        let source = terminalSources.makeSource(for: target)
        let screen = TerminalViewController(source: source, title: target.title)
        screen.hidesBottomBarWhenPushed = true
        screen.navigationItem.largeTitleDisplayMode = .never
        presenter.navigationController?.pushViewController(screen, animated: true)
    }

    /// Opens a Mac browser tab through the injected factory (lane C2).
    func openBrowser(_ tab: BrowserTabInfo, hostID: HostID, from presenter: UIViewController) {
        guard let screen = surfaces.browser?(tab, hostID) else { return }
        screen.navigationItem.largeTitleDisplayMode = .never
        presenter.navigationController?.pushViewController(screen, animated: true)
    }

    func showMachines(_ hosts: [HostWorkspaces], from presenter: UIViewController) {
        let machines = MachinesViewController(feature: self, hosts: hosts)
        let navigation = UINavigationController(rootViewController: machines)
        presenter.present(navigation, animated: true)
    }

    func updatePreferences(_ change: (inout WorkspaceViewPreferences) -> Void) {
        var next = preferences
        change(&next)
        guard next != preferences else { return }
        preferences = next
        store.save(next)
        onPreferencesChange?()
    }
}
