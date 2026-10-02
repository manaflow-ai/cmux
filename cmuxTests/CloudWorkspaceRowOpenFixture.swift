import AppKit
import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class CloudWorkspaceRowOpenFixture {
    let base: CloudWorkspaceCreationSidebarFixture
    let provider: CloudWorkspaceRowOpenProvider
    let operations = CloudWorkspaceOperationController(isAvailable: { true })
    let remote = SurfaceRemoteWorkspace(id: "ws-open", name: "Existing", index: 0, focused: true)
    var failures: [String] = []
    lazy var panelModel = MachinesPanelViewModel(
        createCoordinator: MachineCreateCoordinator(notifier: { _ in }),
        isCloudEnabled: { false },
        catalogProvider: { [unowned self] in base.catalog.snapshot },
        localWorkspacesProvider: { [] }
    )
    let defaults: UserDefaults
    let defaultsName = "cloud-row-open-\(UUID())"
    lazy var coordinator = CloudTreeOutlineView.Coordinator(
        machineActions: MachineRowActions(openShell: { _ in }, openDesktop: { _ in }, runCommand: { _, _ in },
            confirmDelete: { _ in }, promptRename: { _, _ in }, resizeDisk: { _, _ in }, promptUpgrade: {}),
        nodeActions: CloudTreeNodeActions.bound(
            navigationHost: AppDelegate.makeCloudTerminalNavigationHost(),
            catalog: { [unowned self] in base.catalog },
            selectedWorkspaceID: { [unowned self] in base.manager.selectedTabId },
            selectLocalWorkspace: { [unowned self] in base.manager.selectedTabId = $0 },
            onDidMutate: { [weak self] in self?.panelModel.endOperation() },
            onFailure: { [unowned self] in failures.append($0) }, refresh: {}, operationController: operations,
            workspaceCreationHost: { [unowned self] in CloudWorkspaceCreationHost(manager: base.manager) }
        ),
        expansionStore: CloudTreeExpansionStore(defaults: defaults), tabDragTransferRegistry: { nil }
    )
    lazy var container = CloudTreeContainerView(coordinator: coordinator)

    init() throws {
        defaults = try #require(UserDefaults(suiteName: defaultsName))
        base = try CloudWorkspaceCreationSidebarFixture()
        base.manager.window = nil
        base.catalog.unregister(machine: base.provider.machine)
        provider = CloudWorkspaceRowOpenProvider(machine: base.provider.machine)
        base.catalog.register(provider)
        try publish()
    }

    func publish(includeWorkspace: Bool = true, generation: String = "open", revision: Int = 1) throws {
        let document: [String: Any] = [
            "cursor": ["generation": generation, "revision": String(revision)],
            "workspaces": includeWorkspace ? [["id": remote.id, "name": remote.name]] : [],
            "screens": [["id": "screen", "workspace_id": remote.id, "layout": ["root": [
                "kind": "split", "direction": "horizontal", "ratio": 0.6,
                "first": ["kind": "leaf", "pane_id": "one", "tab_ids": ["tab-one"]],
                "second": ["kind": "leaf", "pane_id": "two", "tab_ids": ["tab-two"]]
            ]]]],
            "panes": [["id": "one", "screen_id": "screen"], ["id": "two", "screen_id": "screen"]],
            "tabs": [["id": "tab-one", "pane_id": "one", "content_kind": "terminal", "content_id": "term-one"],
                     ["id": "tab-two", "pane_id": "two", "content_kind": "terminal", "content_id": "term-two"]],
            "terminals": [["id": "term-one", "lifecycle": "running"], ["id": "term-two", "lifecycle": "running"]],
            "browsers": [], "agents": []
        ]
        let state = try #require(CmuxTuiSnapshotParser.state(fromSnapshot: document, machine: provider.machine))
        var info = provider.info
        info.remoteWorkspaces = includeWorkspace ? [remote] : []
        base.catalog.replaceCloudState(state, resources: CmuxTuiSnapshotParser.resources(from: state), info: info)
        base.catalog.reconcileCloudRemoteState(machine: provider.machine, state: state)
    }

    func row() throws -> CloudTreeNode {
        try #require(base.workspaceRows().first)
    }

    func activate(keyboard: Bool = false) throws {
        _ = container
        let row = try row()
        coordinator.apply(nodes: [row])
        let outline = try #require(coordinator.outlineView)
        outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        if keyboard {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                isARepeat: false, keyCode: 36))
            outline.keyDown(with: event)
        } else {
            coordinator.open(row)
        }
    }

    func close() {
        provider.gate?.resolve(true)
        operations.cancelAll()
        base.close()
        defaults.removePersistentDomain(forName: defaultsName)
    }
}
