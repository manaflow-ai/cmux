import CmuxiOSDesign
import CmuxiOSFeatureKit
import CmuxiOSWorkspacesCore
import UIKit

/// E3: group headers (collapse, rename) and drag reorder. A drop becomes
/// one `move` intent with a fresh key; the source's overlay keeps the row
/// where it landed until the Mac's echo, and a refusal re-renders it back.
extension WorkspaceListViewController {
    func host(_ id: HostID?) -> HostWorkspaces? {
        guard let id else { return nil }
        return hosts?.first { $0.hostID == id }
    }

    /// Edit appears only where reordering can do something.
    func updateEditButton() {
        let available = WorkspaceReorder.isAvailable(feature.preferences)
            && (hosts ?? []).contains { $0.isReachable && $0.capabilities.contains(.move) }
        if available {
            navigationItem.leftBarButtonItem = editButtonItem
        } else {
            navigationItem.leftBarButtonItem = nil
            if isEditing { setEditing(false, animated: false) }
        }
    }

    func canReorder(_ row: WorkspaceListRow) -> Bool {
        guard WorkspaceReorder.isAvailable(feature.preferences), let host = host(row.hostID) else { return false }
        return WorkspaceReorder(host: host).canMove(row.workspaceID)
    }

    func configureHeader(_ cell: WorkspaceSectionHeaderCell, section: WorkspaceListSection) {
        guard case .group(let groupID, let name) = section.kind, let hostID = section.hostID else {
            WorkspaceSectionHeader.configure(cell, section: section, toggle: nil, renameGroup: nil)
            return
        }
        let toggle: () -> Void = { [weak self] in
            self?.feature.updatePreferences { $0.toggleCollapsed(host: hostID, group: groupID) }
        }
        var rename: (() -> Void)?
        if section.isReachable, section.capabilities.contains(.renameGroup) {
            let machineName = host(hostID)?.hostName ?? ""
            rename = { [weak self] in
                guard let self else { return }
                self.feature.actions.renameGroup(host: hostID, group: WorkspaceGroup(id: groupID, name: name),
                                                 machineName: machineName, from: self)
            }
        }
        WorkspaceSectionHeader.configure(cell, section: section, toggle: toggle, renameGroup: rename)
    }

    // MARK: Reorder

    /// Keeps a drag inside its machine's group and ungrouped sections.
    func collectionView(_ collectionView: UICollectionView,
                        targetIndexPathForMoveOfItemFromOriginalIndexPath originalIndexPath: IndexPath,
                        atCurrentIndexPath currentIndexPath: IndexPath,
                        toProposedIndexPath proposedIndexPath: IndexPath) -> IndexPath {
        guard let row = row(at: originalIndexPath),
              let id = dataSource.sectionIdentifier(for: proposedIndexPath.section),
              let section = sectionsByID[id], section.hostID == row.hostID,
              section.kind.dropPlacement != nil, !section.isCollapsed || section.rows.isEmpty else {
            return currentIndexPath
        }
        return proposedIndexPath
    }

    func didReorder(_ transaction: NSDiffableDataSourceTransaction<String, String>) {
        let final = transaction.finalSnapshot
        let moved = transaction.difference.insertions.compactMap { change -> String? in
            if case .insert(_, let item, _) = change { return item }
            return nil
        }
        guard let id = moved.first, let row = rowsByID[id], let host = host(row.hostID),
              let sectionID = final.sectionIdentifier(containingItem: id), let section = sectionsByID[sectionID],
              let drop = section.kind.dropPlacement else {
            render(animated: true)
            return
        }
        let items = final.itemIdentifiers(inSection: sectionID)
        let next = items.firstIndex(of: id).flatMap { $0 + 1 < items.count ? items[$0 + 1] : nil }
        let before = next.flatMap { rowsByID[$0]?.workspaceID }
        guard let intent = WorkspaceReorder(host: host).intent(moving: row.workspaceID, to: drop, before: before) else {
            render(animated: true)
            return
        }
        feature.actions.perform(reorder: intent, target: target(for: row), from: self)
    }
}
