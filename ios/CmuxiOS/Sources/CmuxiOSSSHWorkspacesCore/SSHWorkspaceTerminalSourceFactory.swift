public import CmuxiOSFeatureKit
public import CmuxiOSSSHCore
public import CmuxiOSWorkspacesCore
public import CmuxTerminalRenderCore
import Foundation

/// Terminal sources for the Workspaces list: an SSH session surface
/// (`ssh:` ids from discovery) attaches through `SSHTerminalByteSource`
/// over the catalog; every other surface goes to `fallback` (C1's link
/// sources or the mock host).
@MainActor
public final class SSHWorkspaceTerminalSourceFactory: WorkspaceTerminalSourceFactory {
    private let fallback: any WorkspaceTerminalSourceFactory
    private let catalog: SSHSessionCatalog
    private let make: SSHCatalogAttachConnector.Make

    public init(fallback: any WorkspaceTerminalSourceFactory, catalog: SSHSessionCatalog,
                make: @escaping SSHCatalogAttachConnector.Make) {
        self.fallback = fallback
        self.catalog = catalog
        self.make = make
    }

    public func makeSource(for target: WorkspaceTerminalTarget) -> any TerminalByteSource {
        guard target.terminalID.hasPrefix("ssh:") else { return fallback.makeSource(for: target) }
        let connector = SSHCatalogAttachConnector(hostID: target.hostID, surfaceID: target.terminalID, catalog: catalog, make: make)
        return SSHTerminalByteSource(terminalID: target.terminalID, title: target.title, connector: connector)
    }
}
