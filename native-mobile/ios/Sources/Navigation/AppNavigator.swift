import Foundation
import Observation

/// Which screen fills the main card, and whether the sidebar is open.
/// Mirrors the desktop cmux-next sidebar: Home, Feed (notifications), and
/// any terminal of any workspace.
@MainActor
@Observable
final class AppNavigator {
    enum Destination: Hashable {
        case home
        case feed
        case terminal(surface: Int)
    }

    private(set) var destination: Destination = .home
    /// True while the sidebar is open or settling open (driven by the container).
    var sidebarOpen = false
    /// Set by the sidebar's Search item; Home presents its search field.
    var searchRequested = false
    /// App-level sheets and dialogs opened from the sidebar.
    var showSettings = false
    var showPairing = false
    var confirmSignOut = false

    /// The UIKit container that owns the slide animation.
    @ObservationIgnored weak var container: SidebarContainerController?
    @ObservationIgnored private var restoredHost: String?

    func openSidebar() { container?.setOpen(true, animated: true) }
    func closeSidebar() { container?.setOpen(false, animated: true) }

    func select(_ destination: Destination, hostID: String?) {
        self.destination = destination
        if case .terminal(let surface) = destination, let hostID {
            UserDefaults.standard.set(surface, forKey: Self.lastTerminalKey(hostID))
        }
        closeSidebar()
    }

    /// Launch default: the last opened terminal if it still exists, else Home.
    func restore(connection: HostConnection) {
        let hostID = connection.host.id
        guard restoredHost != hostID else { return }
        if let surface = UserDefaults.standard.object(forKey: Self.lastTerminalKey(hostID)) as? Int {
            if connection.tab(surface: surface) != nil {
                restoredHost = hostID
                destination = .terminal(surface: surface)
                return
            }
            // The cached tree may be stale; wait for the live one before giving up.
            guard connection.phase == .connected else { return }
        }
        restoredHost = hostID
        if case .terminal = destination { destination = .home }
    }

    /// Called when the Mac changes: a terminal of the previous Mac is meaningless.
    func hostChanged() {
        restoredHost = nil
        if case .terminal = destination { destination = .home }
    }

    /// The open terminal was closed (here or on the Mac).
    func terminalVanished() {
        destination = .home
    }

    static func lastTerminalKey(_ hostID: String) -> String { "nav.lastTerminal.\(hostID)" }
}
