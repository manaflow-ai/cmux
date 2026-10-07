import CmuxiOSDesign
import CmuxiOSWorkspacesCore
import UIKit

extension WorkspaceListViewController {
    func target(for row: WorkspaceListRow) -> WorkspaceActions.Target {
        WorkspaceActions.Target(workspaceID: row.workspaceID, title: row.title, machineName: row.machineName,
                                unreadCount: row.unreadCount, isReachable: row.isReachable, capabilities: row.capabilities,
                                color: row.color, icon: row.icon, groupID: row.groupID)
    }

    func leadingSwipe(at path: IndexPath) -> UISwipeActionsConfiguration? {
        guard let row = row(at: path) else { return nil }
        let target = target(for: row)
        let actions = feature.actions
        guard actions.canMarkRead(target) else { return nil }
        let read = UIContextualAction(style: .normal, title: WorkspacesText.markRead) { [weak self] _, _, done in
            if let self { actions.markRead(target, from: self) }
            done(true)
        }
        read.image = UIImage(systemName: "envelope.open")
        read.backgroundColor = .systemGray
        return UISwipeActionsConfiguration(actions: [read])
    }

    func trailingSwipe(at path: IndexPath) -> UISwipeActionsConfiguration? {
        guard let row = row(at: path) else { return nil }
        let target = target(for: row)
        let actions = feature.actions
        var items: [UIContextualAction] = []
        if actions.canClose(target) {
            let close = UIContextualAction(style: .destructive, title: WorkspacesText.close) { [weak self] _, view, done in
                if let self { actions.close(target, from: self, sourceView: view) }
                done(false)
            }
            close.image = UIImage(systemName: "xmark")
            items.append(close)
        }
        if actions.canRename(target) {
            let rename = UIContextualAction(style: .normal, title: WorkspacesText.rename) { [weak self] _, _, done in
                if let self { actions.rename(target, from: self) }
                done(true)
            }
            rename.image = UIImage(systemName: "pencil")
            rename.backgroundColor = .systemGray2
            items.append(rename)
        }
        return items.isEmpty ? nil : UISwipeActionsConfiguration(actions: items)
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard indexPaths.count == 1, let path = indexPaths.first, let row = row(at: path) else { return nil }
        let target = target(for: row)
        let actions = feature.actions
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            var items: [UIMenuElement] = []
            if actions.canMarkRead(target) {
                items.append(UIAction(title: WorkspacesText.markRead, image: UIImage(systemName: "envelope.open")) { [weak self] _ in
                    if let self { actions.markRead(target, from: self) }
                })
            }
            items.append(UIAction(title: WorkspacesText.rename, image: UIImage(systemName: "pencil"),
                                  attributes: actions.canRename(target) ? [] : .disabled) { [weak self] _ in
                if let self { actions.rename(target, from: self) }
            })
            if actions.canCustomize(target) {
                items.append(UIAction(title: WorkspacesText.customize, image: UIImage(systemName: "paintpalette")) { [weak self] _ in
                    if let self { actions.customize(target, from: self) }
                })
            }
            if let move = self.moveMenu(for: row, target: target) { items.append(move) }
            items.append(UIAction(title: WorkspacesText.close, image: UIImage(systemName: "xmark"),
                                  attributes: actions.canClose(target) ? .destructive : [.destructive, .disabled]) { [weak self] _ in
                guard let self else { return }
                let cell = self.collectionView.indexPathsForVisibleItems.first { self.row(at: $0)?.id == row.id }
                    .flatMap { self.collectionView.cellForItem(at: $0) }
                actions.close(target, from: self, sourceView: cell)
            })
            return UIMenu(children: items)
        }
    }

    /// VoiceOver custom actions mirroring the swipe actions.
    func accessibilityActions(for row: WorkspaceListRow) -> [UIAccessibilityCustomAction] {
        let target = target(for: row)
        let actions = feature.actions
        var made: [UIAccessibilityCustomAction] = []
        if actions.canMarkRead(target) {
            made.append(UIAccessibilityCustomAction(name: WorkspacesText.markRead) { [weak self] _ in
                guard let self else { return false }
                actions.markRead(target, from: self)
                return true
            })
        }
        if actions.canRename(target) {
            made.append(UIAccessibilityCustomAction(name: WorkspacesText.rename) { [weak self] _ in
                guard let self else { return false }
                actions.rename(target, from: self)
                return true
            })
        }
        if actions.canCustomize(target) {
            made.append(UIAccessibilityCustomAction(name: WorkspacesText.customize) { [weak self] _ in
                guard let self else { return false }
                actions.customize(target, from: self)
                return true
            })
        }
        if actions.canClose(target) {
            made.append(UIAccessibilityCustomAction(name: WorkspacesText.close) { [weak self] _ in
                guard let self else { return false }
                actions.close(target, from: self)
                return true
            })
        }
        return made
    }

    /// Move to Group: the host's groups and No Group, the current one checked.
    func moveMenu(for row: WorkspaceListRow, target: WorkspaceActions.Target) -> UIMenu? {
        let actions = feature.actions
        guard actions.canMove(target), let host = host(row.hostID) else { return nil }
        var groups = host.groups
        for workspace in host.workspaces {
            if let group = workspace.group, !groups.contains(where: { $0.id == group.id }) { groups.append(group) }
        }
        guard !groups.isEmpty else { return nil }
        let choices: [(String?, String)] = groups.map { ($0.id, $0.name) } + [(nil, WorkspacesText.noGroup)]
        let children = choices.map { id, name in
            UIAction(title: name, state: row.groupID == id ? .on : .off) { [weak self] _ in
                if let self { actions.move(target, toGroup: id, from: self) }
            }
        }
        return UIMenu(title: WorkspacesText.moveToGroup, image: UIImage(systemName: "folder"), children: children)
    }
}
