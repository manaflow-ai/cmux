import CmuxiOSDesign
import CmuxiOSFeatureKit
import CmuxiOSWorkspacesCore
import UIKit

/// Show or hide each Mac in the list and drag to reorder them. Both are
/// this device's view state; hiding never unpairs.
@MainActor
final class MachinesViewController: UITableViewController {
    private let feature: WorkspacesFeature
    private var hosts: [HostWorkspaces]

    init(feature: WorkspacesFeature, hosts: [HostWorkspaces]) {
        self.feature = feature
        self.hosts = feature.preferences.ordered(hosts, id: \.hostID)
        super.init(style: .insetGrouped)
        title = WorkspacesText.machines
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "machine")
        tableView.isEditing = true
        tableView.allowsSelectionDuringEditing = false
        view.accessibilityIdentifier = "workspaces.machines"
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { hosts.count }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        WorkspacesText.machinesFooter
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "machine", for: indexPath)
        let host = hosts[indexPath.row]
        var content = UIListContentConfiguration.cell()
        content.text = host.hostName
        content.textProperties.adjustsFontForContentSizeCategory = true
        content.image = UIImage(systemName: "desktopcomputer")
        content.imageProperties.tintColor = MachineColor(hostID: host.hostID).uiColor
        cell.contentConfiguration = content
        let toggle = UISwitch()
        toggle.isOn = !feature.preferences.hiddenHosts.contains(host.hostID)
        toggle.accessibilityLabel = WorkspacesText.format(WorkspacesText.show, host.hostName)
        let id = host.hostID
        toggle.addAction(UIAction { [weak self, weak toggle] _ in
            guard let self, let toggle else { return }
            let visible = toggle.isOn
            self.feature.updatePreferences { preferences in
                if visible { preferences.hiddenHosts.remove(id) } else { preferences.hiddenHosts.insert(id) }
            }
        }, for: .valueChanged)
        cell.editingAccessoryView = toggle
        cell.selectionStyle = .none
        cell.accessibilityIdentifier = "workspaces.machine." + host.hostID.rawValue
        return cell
    }

    override func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        .none
    }

    override func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool { false }

    override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool { true }

    override func tableView(_ tableView: UITableView, moveRowAt source: IndexPath, to destination: IndexPath) {
        let order = hosts.map(\.hostID)
        let moved = hosts.remove(at: source.row)
        hosts.insert(moved, at: destination.row)
        feature.updatePreferences { $0.move(moved.hostID, to: destination.row, in: order) }
    }
}
