public import CmuxiOSFeatureKit
public import CmuxiOSWorkspacesCore
public import CmuxiOSTerminal
public import CmuxTerminalRenderCore
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
    /// The device's terminal look (C11) for every host terminal it opens.
    let appearance: (any TerminalAppearanceProviding)?
    let isMock: Bool
    private let store: WorkspaceViewPreferencesStore
    /// Client view state: filter, sort, grouping, hidden and ordered Macs.
    private(set) var preferences: WorkspaceViewPreferences
    /// The list re-renders when the machines sheet changes preferences.
    var onPreferencesChange: (() -> Void)?
    /// Lane C13: Changes and Files rows in the workspace detail; nil hides them.
    public var viewers: (any WorkspaceViewerOpening)?
    private weak var navigation: UINavigationController?
    /// Lane E4: the composer bar of a host terminal; nil offers none.
    public var terminalComposer: (@MainActor (WorkspaceTerminalTarget) -> (any TerminalComposerProviding)?)?
    /// Lane E4: the terminal More menu's composer toggle (writes the setting).
    public var onComposerToggle: (@MainActor (Bool) -> Void)?
    /// Lane C3: "Remote Desktop" in a workspace's menu opens the Mac's
    /// screen. Set by the composition root with its localized title.
    public var remoteDesktop: RemoteDesktopHook?

    /// How the workspace detail offers remote desktop for its Mac.
    public struct RemoteDesktopHook {
        public var title: String
        public var open: @MainActor (HostID, String, UIViewController) -> Void

        public init(title: String, open: @escaping @MainActor (HostID, String, UIViewController) -> Void) {
            self.title = title
            self.open = open
        }
    }

    public init(source: any WorkspaceSource, terminalSources: any WorkspaceTerminalSourceFactory,
                surfaces: SurfaceScreenFactories = SurfaceScreenFactories(),
                appearance: (any TerminalAppearanceProviding)? = nil,
                preferences: WorkspaceViewPreferencesStore = WorkspaceViewPreferencesStore(), isMock: Bool = false) {
        self.source = source
        self.terminalSources = terminalSources
        self.surfaces = surfaces
        self.appearance = appearance
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
        let screen = TerminalViewController(source: source, title: target.title, appearance: appearance)
        screen.composerProvider = terminalComposer?(target)
        screen.onComposerToggle = onComposerToggle
        screen.hidesBottomBarWhenPushed = true
        screen.navigationItem.largeTitleDisplayMode = .never
        // The title bar holds the terminal's title, badge and menu: a bare back chevron.
        presenter.navigationItem.backButtonDisplayMode = .minimal
        presenter.navigationController?.pushViewController(screen, animated: true)
    }

    /// Opens a Mac browser tab through the injected factory (lane C2).
    func openBrowser(_ tab: BrowserTabInfo, hostID: HostID, from presenter: UIViewController) {
        guard let screen = surfaces.browser?(tab, hostID) else { return }
        screen.navigationItem.largeTitleDisplayMode = .never
        presenter.navigationController?.pushViewController(screen, animated: true)
    }

    func openViewer(_ target: WorkspaceViewerTarget, kind: WorkspaceViewerKind, from presenter: UIViewController) {
        guard let viewers else { return }
        let screen = switch kind {
        case .changes: viewers.changesScreen(for: target)
        case .files: viewers.filesScreen(for: target)
        case .todo: viewers.todoScreen(for: target)
        }
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
