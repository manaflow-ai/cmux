public import CmuxiOSFeatureKit
public import CmuxiOSSSHCore
import Foundation

/// Opens a discovered session: looks the surface up in the catalog (a
/// session that is no longer listed fails with `sessionGone`) and attaches
/// through the connector `make` builds for that target. When the attached
/// client exits, the host is rediscovered.
public struct SSHCatalogAttachConnector: SSHShellConnector {
    public typealias Make = @Sendable (HostID, SSHSessionTarget) async throws -> any SSHShellConnector

    private let hostID: HostID
    private let surfaceID: String
    private let catalog: SSHSessionCatalog
    private let make: Make

    public init(hostID: HostID, surfaceID: String, catalog: SSHSessionCatalog, make: @escaping Make) {
        self.hostID = hostID
        self.surfaceID = surfaceID
        self.catalog = catalog
        self.make = make
    }

    public func openShell(cols: Int, rows: Int) async throws -> any SSHShellChannel {
        guard let target = await catalog.target(host: hostID, surfaceID: surfaceID) else { throw SSHSessionFailure.sessionGone }
        do {
            let shell = try await make(hostID, target).openShell(cols: cols, rows: rows)
            return SSHEndingShellChannel(base: shell) { [catalog, hostID] in await catalog.sessionEnded(on: hostID) }
        } catch let failure as SSHSessionFailure {
            // A modern tmux pane can disappear or change while a reconnect is
            // opening. Refresh the host catalog before surfacing the refusal so
            // the next user retry gets a fresh stable pane identity.
            if case .tmuxControl = target, failure == .shellRejected || failure == .sessionGone {
                await catalog.sessionEnded(on: hostID)
            }
            throw failure
        }
    }
}
