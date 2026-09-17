import CmuxMobileShellUI
import CmuxMobileTransport

/// Adapts the transport layer's ``CmuxMobileTransport/TailscaleStatusMonitor``
/// onto the shell UI's read-only ``CmuxMobileShellUI/TailscaleStatusObserving``
/// port, so `CmuxMobileShellUI` stays decoupled from the concrete system
/// detector (which owns `NWPathMonitor` and the interface walk).
///
/// Not itself `@Observable`: reads of ``status`` forward to the monitor's
/// observable `status`, so SwiftUI observation tracks the underlying change
/// source directly.
@MainActor
public final class TailscaleStatusMonitorAdapter: TailscaleStatusObserving {
    private let monitor: TailscaleStatusMonitor

    /// Wraps the given system detector.
    /// - Parameter monitor: The transport-layer monitor to expose to the UI.
    public init(monitor: TailscaleStatusMonitor) {
        self.monitor = monitor
    }

    public var status: TailnetStatus {
        switch monitor.status {
        case .active: .active
        case .inactiveOrNotInstalled: .inactiveOrNotInstalled
        case .unknown: .unknown
        }
    }

    public func refresh() {
        monitor.refresh()
    }
}
