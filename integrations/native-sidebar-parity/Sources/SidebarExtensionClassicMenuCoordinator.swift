import AppKit
@_spi(CmuxHostTransport) import CmuxExtensionKit
import CmuxSidebar
import SwiftUI

/// Presents the exact AppKit menu shared with CMUX's classic sidebar.
/// Never copies menu labels, availability, palettes, shortcuts, or mutations.
@MainActor
struct SidebarExtensionClassicMenuCoordinator {
    let tabManager: TabManager
    let notificationStore: TerminalNotificationStore
    var colorScheme: ColorScheme = .dark
    var readSelectedIDs: () -> Set<UUID> = { [] }
    var writeSelectedIDs: (Set<UUID>) -> Void = { _ in }
    var readSelectionIndex: () -> Int? = { nil }
    var writeSelectionIndex: (Int?) -> Void = { _ in }
    var selectTabs: () -> Void = {}
    var refreshSnapshot: () -> Void = {}
    var groupConfiguration: ((UUID) -> SidebarWorkspaceTableRowConfiguration?)?
    var presentMenu: (NSMenu) -> Void = {
        $0.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    func perform(_ action: CmuxSidebarClassicMenuAction) -> CmuxSidebarActionResult {
        switch action {
        case .presentWorkspaceMenu(let id, let selected):
            guard selected.count <= 256, Set(selected).count == selected.count,
                  let index = tabManager.tabs.firstIndex(where: { $0.id == id }),
                  let capture = SidebarClassicMenuParity(nativeOrder: tabManager.tabs.map(\.id),
                    anchorID: id, selectedWorkspaceIDs: selected) else { return unavailable }
            let tab = tabManager.tabs[index]
            let targets = capture.selectedWorkspaceIDs
            let remoteTargets = tabManager.tabs.filter { targets.contains($0.id) && $0.isRemoteWorkspace && !$0.isManagedCloudVMWorkspace }
            writeSelectedIDs(Set(targets))
            let snapshot = SidebarWorkspaceSnapshotFactory(workspace: tab,
                settings: SidebarTabItemSettingsSnapshot(), showsAgentActivity: true).makeSnapshot()
            let commands = SidebarWorkspaceRowCommands(tab: tab, tabManager: tabManager,
                notificationStore: notificationStore, index: index,
                contextMenuWorkspaceIds: targets, remoteContextMenuWorkspaceIds: remoteTargets.map(\.id),
                allRemoteContextMenuTargetsConnecting: !remoteTargets.isEmpty && remoteTargets.allSatisfy { $0.remoteConnectionState == .connecting || $0.remoteConnectionState == .reconnecting },
                allRemoteContextMenuTargetsDisconnected: !remoteTargets.isEmpty && remoteTargets.allSatisfy { $0.remoteConnectionState == .disconnected },
                contextMenuPinState: WorkspaceActionDispatcher.pinState(in: tabManager,
                    target: .init(workspaceIds: targets, anchorWorkspaceId: id)),
                workspaceGroupMenuSnapshot: .init(items: tabManager.workspaceGroups.map { .init(id: $0.id, name: $0.name) }),
                colorScheme: colorScheme, refreshSnapshot: refreshSnapshot,
                readSelectedTabIds: readSelectedIDs, writeSelectedTabIds: writeSelectedIDs,
                readLastSelectionIndex: readSelectionIndex, writeLastSelectionIndex: writeSelectionIndex,
                setSelectionToTabs: selectTabs, snapshotProvider: { snapshot })
            let menu = commands.makeContextMenu(onOpen: {}, onClose: refreshSnapshot, beginInlineRename: {
                _ = SidebarExtensionManagementCoordinator(tabManager: tabManager, notificationStore: notificationStore)
                    .perform(.renameWorkspace(workspaceID: id, title: nil))
            })
            appendTargetHeading(to: menu, title: targets.count > 1 ? "\(tab.title) · \(targets.count) workspaces" : tab.title)
            presentMenu(menu)
            return .accepted
        case .presentGroupMenu(let id):
            guard tabManager.workspaceGroups.contains(where: { $0.id == id }),
                  let row = groupConfiguration?(id), let model = row.appKitGroupHeaderModel,
                  let actions = row.appKitGroupHeaderActions else { return unavailable }
            let cell = SidebarGroupHeaderTableCellView(frame: .zero)
            cell.configure(model: model, actions: actions, isPointerHovering: false,
                contextMenuDidOpen: {}, contextMenuDidClose: refreshSnapshot)
            let menu = cell.makeHeaderMenu()
            appendTargetHeading(to: menu, title: model.name)
            // NSMenu targets the cell; retain it throughout native tracking.
            withExtendedLifetime(cell) { presentMenu(menu) }
            return .accepted
        }
    }
    private func appendTargetHeading(to menu: NSMenu, title: String) {
        let heading = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.insertItem(.separator(), at: 0)
        menu.insertItem(heading, at: 0)
    }
    private var unavailable: CmuxSidebarActionResult { .rejected("Native sidebar menu is unavailable") }
}
