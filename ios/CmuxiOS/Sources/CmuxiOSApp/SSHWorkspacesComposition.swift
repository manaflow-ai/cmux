import CmuxiOSFeatureKit
import CmuxiOSSSHCore
import CmuxiOSSSHWorkspacesCore
import CmuxiOSWorkspaces
import CmuxiOSWorkspacesCore
import Foundation

/// Lane E3: SSH hosts' tmux, screen and cmux-tui sessions in the Workspaces
/// list. One catalog per process is shared by the discovery channels and
/// the terminal factory, so an attach only ever opens a listed session.
/// Discovery and attach check host keys against the pins without asking
/// (`PinnedHostKeyVerifier`); a host is trusted from the Hosts tab.
struct SSHWorkspacesComposition: Sendable {
    let hosts: any HostsStore
    let device: SSHDeviceState
    let catalog: SSHSessionCatalog
    let reasons: SSHWorkspaceReasons

    @MainActor
    init(hosts: any HostsStore, device: SSHDeviceState, catalog: SSHSessionCatalog) {
        self.hosts = hosts
        self.device = device
        self.catalog = catalog
        let texts = WorkspacesFeature.sshReasons
        reasons = SSHWorkspaceReasons(untrustedKey: texts.untrustedKey, needsLogin: texts.needsLogin,
                                      unreachable: texts.unreachable, refused: texts.refused)
    }

    var directory: any WorkspaceHostDirectory { SSHHostDirectory(store: hosts) }

    /// `.ssh` hosts over discovery, the rest over `fallback`.
    func channels(fallback: any WorkspaceChannelFactory) -> any WorkspaceChannelFactory {
        let composition = self
        return SSHWorkspaceChannelFactory(fallback: fallback, catalog: catalog, reasons: reasons) { host in
            { NIOSSHCommandRunner(dialer: try await composition.dialer(for: host)) }
        }
    }

    /// Terminals of SSH session surfaces; the rest go to `fallback`.
    @MainActor
    func terminalSources(fallback: any WorkspaceTerminalSourceFactory) -> any WorkspaceTerminalSourceFactory {
        let composition = self
        return SSHWorkspaceTerminalSourceFactory(fallback: fallback, catalog: catalog) { host, target in
            NIOSSHShellConnector(dialer: try await composition.dialer(for: host), attaching: target) {
                await composition.catalog.sessionEnded(on: host)
            }
        }
    }

    /// The signed-out shell's workspace source: SSH hosts only (no account,
    /// so no Macs or Cloud machines).
    func guestSource() -> any WorkspaceSource {
        ControlPlaneWorkspaceSource(
            directory: directory,
            channels: channels(fallback: UnavailableWorkspaceChannelFactory(reason: reasons.refused)))
    }

    /// The host's chain from the current records, with this device's logins.
    func dialer(for host: HostID) async throws -> SSHChainDialer {
        var records: [HostRecord] = []
        for await snapshot in await hosts.updates() {
            records = snapshot.value
            break
        }
        let chain = try SSHHostChain(target: host, records: records)
        for hop in chain.hops where await device.settings.settings(for: hop.hostID).auth == .unset {
            throw SSHSessionFailure.missingCredentials
        }
        return SSHChainDialer(chain: chain, credentials: device.credentials,
                              verifier: PinnedHostKeyVerifier(knownHosts: device.knownHosts))
    }
}
