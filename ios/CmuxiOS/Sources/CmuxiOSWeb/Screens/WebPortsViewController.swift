import CmuxiOSBrowser
import CmuxiOSDesign
import CmuxiOSFeatureKit
import CmuxiOSWebCore
import UIKit

/// The machine's ports for the tunnel browser: the Mac's advertised dev
/// servers (read on appear and on pull to refresh, never polled), a row to
/// open any localhost port, and the Mac's booted simulators (C2 screen in
/// the device chrome). Keeps the machine's route alive while it is shown.
@MainActor
final class WebPortsViewController: UITableViewController {
    private enum Section: Int, CaseIterable {
        case ports, open, simulators
    }

    private let feature: WebFeature
    private let target: WebTarget
    private var ports: [WebPort] = []
    private var portsFailed = false
    private var simulators: [BrowserTabInfo] = []
    private var loadTask: Task<Void, Never>?

    init(feature: WebFeature, target: WebTarget) {
        self.feature = feature
        self.target = target
        super.init(style: .insetGrouped)
        title = target.ports == nil ? target.name : WebText.portsTitle
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        tableView.accessibilityIdentifier = "web.ports"
        if target.ports != nil {
            let refresh = UIRefreshControl()
            refresh.addAction(UIAction { [weak self] _ in self?.reload() }, for: .valueChanged)
            refreshControl = refresh
        }
        reload()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent || navigationController?.isBeingDismissed == true {
            loadTask?.cancel()
        }
    }

    private var shownSections: [Section] {
        var sections: [Section] = []
        if target.ports != nil { sections.append(.ports) }
        sections.append(.open)
        if target.ports != nil, feature.simulators != nil { sections.append(.simulators) }
        return sections
    }

    private func reload() {
        guard let portsSource = target.ports else { return }
        loadTask?.cancel()
        let host = target.host
        let simulatorSource = feature.simulators?.source
        loadTask = Task { [weak self] in
            let loaded = try? await portsSource()
            var devices: [BrowserTabInfo] = []
            if let simulatorSource {
                for await snapshot in await simulatorSource.tabs(on: host) {
                    devices = snapshot.value
                    break
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.ports = loaded ?? []
            self.portsFailed = loaded == nil
            self.simulators = devices
            self.refreshControl?.endRefreshing()
            self.tableView.reloadData()
        }
    }

    // MARK: Table

    override func numberOfSections(in tableView: UITableView) -> Int {
        shownSections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch shownSections[section] {
        case .ports: ports.count
        case .open: 1
        case .simulators: simulators.count
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch shownSections[section] {
        case .ports: WebText.portsSection
        case .open: nil
        case .simulators: WebText.simulatorsSection
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch shownSections[section] {
        case .ports: portsFailed ? WebText.portsFailed : (ports.isEmpty ? WebText.portsEmpty : nil)
        case .open: target.ports == nil ? WebText.sshFooter : nil
        case .simulators: simulators.isEmpty ? WebText.simulatorsEmpty : nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var content = UIListContentConfiguration.subtitleCell()
        switch shownSections[indexPath.section] {
        case .ports:
            let port = ports[indexPath.row]
            content.text = "localhost:\(port.port)"
            content.secondaryText = [port.process, port.source == .detected ? WebText.detected : WebText.allowed]
                .compactMap { $0 }.joined(separator: " · ")
            content.image = UIImage(systemName: "network")
            cell.accessoryType = .disclosureIndicator
        case .open:
            content = .cell()
            content.text = WebText.openPort
            content.image = UIImage(systemName: "plus.circle")
            cell.accessoryType = .none
        case .simulators:
            let device = simulators[indexPath.row]
            content.text = device.title
            content.image = UIImage(systemName: "iphone")
            cell.accessoryType = .disclosureIndicator
        }
        content.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch shownSections[indexPath.section] {
        case .ports: openBrowser(WebAddress(port: ports[indexPath.row].port))
        case .open: askForPort()
        case .simulators:
            guard let screen = feature.simulators?.makeDeviceScreen(device: simulators[indexPath.row], host: target.host) else { return }
            navigationController?.pushViewController(screen, animated: true)
        }
    }

    private func askForPort() {
        let alert = UIAlertController(title: WebText.openPortTitle, message: WebText.openPortMessage, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = WebText.addressPlaceholder
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: WebText.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: WebText.open, style: .default) { [weak self, weak alert] _ in
            guard let text = alert?.textFields?.first?.text, let address = WebAddress(text) else { return }
            self?.openBrowser(address)
        })
        present(alert, animated: true)
    }

    private func openBrowser(_ address: WebAddress) {
        let screen = WebBrowserViewController(feature: feature, target: target, address: address)
        navigationController?.pushViewController(screen, animated: true)
    }
}
