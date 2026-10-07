import CmuxiOSDesign
import CmuxiOSFeatureKit
import CmuxiOSWorkspacesCore
import UIKit

/// The composer's workspace picker (C8): live choices per Mac, New
/// Workspace first. Dismisses itself, then reports the choice.
@MainActor
final class WorkspacePickerViewController: UITableViewController {
    private let source: any WorkspaceSource
    private let request: WorkspacePickerRequest
    private let model: WorkspacePickerModel
    private let completion: @MainActor (WorkspaceSelection?) -> Void
    private var sections: [WorkspacePickerSection] = []
    private var subscription: Task<Void, Never>?
    private var finished = false
    /// The choice to report once the dismissal finished.
    private var chosen: WorkspaceSelection?

    init(source: any WorkspaceSource, request: WorkspacePickerRequest, model: WorkspacePickerModel,
         completion: @escaping @MainActor (WorkspaceSelection?) -> Void) {
        self.source = source
        self.request = request
        self.model = model
        self.completion = completion
        super.init(style: .insetGrouped)
        title = WorkspacesText.pickerTitle
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "choice")
        view.accessibilityIdentifier = "workspaces.picker"
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.finish(nil)
        })
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard subscription == nil else { return }
        let source = self.source
        subscription = Task { [weak self] in
            for await snapshot in await source.updates() { self?.update(snapshot.value) }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        subscription?.cancel()
        subscription = nil
        // Reported after the dismissal; a swipe-down leaves `chosen` nil (cancel).
        if isBeingDismissed || navigationController?.isBeingDismissed == true { report(chosen) }
    }

    private func update(_ hosts: [HostWorkspaces]) {
        sections = model.sections(from: hosts, request: request)
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].choices.count }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        let host = sections[section].host
        return host.isReachable ? host.hostName : host.hostName + " · " + WorkspacesText.offline
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "choice", for: indexPath)
        let choice = sections[indexPath.section].choices[indexPath.row]
        var content = UIListContentConfiguration.cell()
        content.text = choice.title ?? WorkspacesText.newWorkspace
        content.textProperties.adjustsFontForContentSizeCategory = true
        content.textProperties.color = choice.isEnabled ? ShellPalette.primaryText : ShellPalette.secondaryText
        content.image = UIImage(systemName: choice.title == nil ? "plus.square" : (choice.status?.symbolName ?? "square"))
        content.imageProperties.tintColor = choice.status.map(\.tint) ?? ShellPalette.secondaryText
        cell.contentConfiguration = content
        cell.selectionStyle = choice.isEnabled ? .default : .none
        cell.accessibilityTraits = choice.isEnabled ? .button : [.button, .notEnabled]
        cell.accessibilityIdentifier = "workspaces.picker." + choice.id
        return cell
    }

    override func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        sections[indexPath.section].choices[indexPath.row].isEnabled ? indexPath : nil
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        finish(sections[indexPath.section].choices[indexPath.row].selection)
    }

    private func finish(_ selection: WorkspaceSelection?) {
        chosen = selection
        (navigationController ?? self).dismiss(animated: true)
    }

    private func report(_ selection: WorkspaceSelection?) {
        guard !finished else { return }
        finished = true
        completion(selection)
    }
}
