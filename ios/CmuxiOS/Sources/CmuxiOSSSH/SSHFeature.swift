public import CmuxiOSFeatureKit
public import CmuxiOSSSHCore
import CmuxMobileSSH
public import CmuxTerminalRenderCore
import SwiftUI
public import UIKit

/// Lane C9's entry point: builds the Hosts tab over a `HostsStore` (synced
/// records) and `SSHDeviceState` (this device's logins, keys and pins), and
/// opens SSH terminals. The composition root makes one per shell.
@MainActor
public final class SSHFeature {
    let hosts: any HostsStore
    let device: SSHDeviceState
    /// The device's terminal settings (lane C11); nil keeps renderer defaults.
    let appearance: (any TerminalAppearanceProviding)?
    private weak var navigation: UINavigationController?
    /// Opens a paired Mac's row (lane C3: the remote desktop entry). Set by
    /// the composition root; nil leaves paired Macs informational.
    public var openPairedMac: (@MainActor (HostRecord, UIViewController, UIView?) -> Void)?
    private(set) lazy var prompter = SSHTrustAlertPrompter { [weak self] in
        self?.navigation?.topmostPresented
    }

    public init(hosts: any HostsStore, device: SSHDeviceState,
                appearance: (any TerminalAppearanceProviding)? = nil) {
        self.hosts = hosts
        self.device = device
        self.appearance = appearance
    }

    /// The Hosts tab root (a navigation controller with large titles).
    public func makeHostsScreen() -> UIViewController {
        let list = HostsViewController(feature: self)
        let navigation = UINavigationController(rootViewController: list)
        navigation.navigationBar.prefersLargeTitles = true
        self.navigation = navigation
        return navigation
    }

    // MARK: Entry points from other screens (lane C15 search)

    /// Opens `hostID`'s terminal on the Hosts tab (or its editor when it has
    /// no usable login). Select the Hosts tab first.
    public func openHost(_ hostID: HostID) {
        guard let navigation, let list = navigation.viewControllers.first else { return }
        navigation.popToRootViewController(animated: false)
        Task {
            let records = await currentRecords()
            guard let host = records.first(where: { $0.id == hostID }) else { return }
            openTerminal(host, records: records, from: list)
        }
    }

    /// Presents the Add Host editor over the Hosts tab. Select the tab first.
    public func presentAddHost() {
        guard let navigation else { return }
        Task {
            let records = await currentRecords()
            showEditor(.add(IntentKey()), records: records, from: navigation.topmostPresented)
        }
    }

    /// The owner's current records: the store yields its snapshot first.
    private func currentRecords() async -> [HostRecord] {
        for await snapshot in await hosts.updates() { return snapshot.value }
        return []
    }

    // MARK: Routes

    func showEditor(_ mode: HostEditorModel.Mode, records: [HostRecord], from presenter: UIViewController) {
        let model = HostEditorModel(mode: mode, records: records, feature: self)
        let hosting = UIHostingController(rootView: NavigationStack { HostEditorView(model: model) })
        model.dismiss = { [weak hosting] in hosting?.dismiss(animated: true) }
        presenter.present(hosting, animated: true)
    }

    func showImport(records: [HostRecord], from presenter: UIViewController) {
        let model = SSHConfigImportModel(hosts: hosts, existing: records)
        let hosting = UIHostingController(rootView: NavigationStack { SSHConfigImportView(model: model) })
        model.dismiss = { [weak hosting] in hosting?.dismiss(animated: true) }
        presenter.present(hosting, animated: true)
    }

    func showKeys(from navigation: UINavigationController?) {
        let model = SSHKeysModel(device: device)
        let hosting = UIHostingController(rootView: SSHKeysView(model: model))
        hosting.title = SSHText.keysTitle
        navigation?.pushViewController(hosting, animated: true)
    }

    /// Opens a terminal on `host`; a host without a usable login opens the
    /// editor instead, and a broken jump chain shows why.
    func openTerminal(_ host: HostRecord, records: [HostRecord], from list: UIViewController) {
        Task {
            let chain: SSHHostChain
            do {
                chain = try SSHHostChain(target: host.id, records: records)
            } catch {
                showFailure(SSHSessionFailure(error), on: list)
                return
            }
            for hop in chain.hops where await device.settings.settings(for: hop.hostID).auth == .unset {
                showEditor(.edit(hop.hostID), records: records, from: list)
                return
            }
            let verifier = TOFUHostKeyVerifier(knownHosts: device.knownHosts, prompter: prompter, names: chain.names)
            let connector = NIOSSHShellConnector(chain: chain, credentials: device.credentials, verifier: verifier)
            let source = SSHTerminalByteSource(terminalID: "ssh-" + host.id.rawValue, title: host.name, connector: connector)
            let screen = SSHTerminalViewController(source: source, title: host.name,
                                                   appearance: appearance) { [weak self, weak list] in
                guard let self, let list else { return }
                self.showEditor(.edit(host.id), records: records, from: list.topmostPresented)
            }
            list.navigationController?.pushViewController(screen, animated: true)
        }
    }

    func showFailure(_ failure: SSHSessionFailure, on presenter: UIViewController) {
        let alert = UIAlertController(title: SSHText.cannotOpen, message: SSHText.failure(failure), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: SSHText.ok, style: .default))
        presenter.topmostPresented.present(alert, animated: true)
    }

    /// Removes a host and the device state that belongs to it.
    func delete(_ host: HostRecord) async -> String? {
        do {
            let receipt = try await hosts.remove(host.id, key: IntentKey())
            if case .refused(_, let reason) = receipt { return SSHText.refusal(reason) }
        } catch {
            return SSHText.offline
        }
        try? await device.settings.remove(host.id)
        try? await device.vault.removePassword(for: host.id)
        if case .ssh(let endpoint, _) = host.kind {
            let identity = SSHEndpoint(host: endpoint.address, port: Int(endpoint.port ?? 22), username: endpoint.user ?? "").hostKeyIdentity
            await device.knownHosts.forget(identity: identity)
        }
        return nil
    }
}
