import CmuxiOSDesign
import CmuxiOSWorkspacesCore
import UIKit

/// Section headers: a machine header (color dot, name, state, count) on the
/// first section of each Mac, a plain title on the others.
@MainActor
enum WorkspaceSectionHeader {
    /// Group sections get a disclosure chevron (tap toggles) and, when the
    /// host renames groups, a menu with Rename Group.
    static func configure(_ cell: WorkspaceSectionHeaderCell, section: WorkspaceListSection,
                          toggle: (() -> Void)?, renameGroup: (() -> Void)?) {
        configure(cell, section: section)
        cell.onToggle = toggle
        guard case .group = section.kind, toggle != nil else {
            cell.accessories = []
            return
        }
        let chevron = UIImageView(image: UIImage(systemName: section.isCollapsed ? "chevron.right" : "chevron.down"))
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .footnote, scale: .small)
        chevron.tintColor = ShellPalette.secondaryText
        var accessories: [UICellAccessory] = [.customView(configuration: UICellAccessory.CustomViewConfiguration(
            customView: chevron, placement: .trailing(displayed: .always)))]
        var actions: [UIAccessibilityCustomAction] = []
        if let renameGroup {
            let button = UIButton(type: .system)
            button.setImage(UIImage(systemName: "ellipsis.circle"), for: .normal)
            button.showsMenuAsPrimaryAction = true
            button.menu = UIMenu(children: [UIAction(title: WorkspacesText.renameGroup, image: UIImage(systemName: "pencil")) { _ in
                renameGroup()
            }])
            button.accessibilityLabel = WorkspacesText.groupActions
            accessories.append(.customView(configuration: UICellAccessory.CustomViewConfiguration(
                customView: button, placement: .trailing(displayed: .always), reservedLayoutWidth: .custom(44))))
            actions.append(UIAccessibilityCustomAction(name: WorkspacesText.renameGroup) { _ in
                renameGroup()
                return true
            })
        }
        cell.accessories = accessories
        if section.isCollapsed, var content = cell.contentConfiguration as? UIListContentConfiguration {
            content.secondaryText = WorkspacesText.workspaceCount(section.memberCount)
            cell.contentConfiguration = content
        }
        cell.accessibilityTraits = [.header, .button]
        cell.accessibilityValue = section.isCollapsed ? WorkspacesText.collapsed : WorkspacesText.expanded
        cell.accessibilityHint = section.isCollapsed ? WorkspacesText.expand : WorkspacesText.collapse
        cell.accessibilityCustomActions = actions
    }

    static func configure(_ cell: UICollectionViewListCell, section: WorkspaceListSection) {
        if let machine = section.machine {
            var content = UIListContentConfiguration.prominentInsetGroupedHeader()
            content.text = machine.name
            content.textProperties.adjustsFontForContentSizeCategory = true
            content.secondaryText = machineDetail(machine, section: section)
            content.secondaryTextProperties.color = ShellPalette.secondaryText
            content.secondaryTextProperties.adjustsFontForContentSizeCategory = true
            content.image = UIImage(systemName: machine.isReachable ? "circle.fill" : "circle")
            content.imageProperties.tintColor = machine.color.uiColor
            content.imageProperties.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .caption2)
            cell.contentConfiguration = content
            cell.accessibilityLabel = [machine.name, content.secondaryText].compactMap { $0 }.joined(separator: ", ")
        } else {
            var content = UIListContentConfiguration.groupedHeader()
            content.text = title(section.kind)
            content.textProperties.adjustsFontForContentSizeCategory = true
            cell.contentConfiguration = content
            cell.accessibilityLabel = content.text
        }
        cell.accessibilityTraits = .header
        cell.isAccessibilityElement = true
    }

    static func machineDetail(_ machine: WorkspaceMachineHeader, section: WorkspaceListSection) -> String {
        var parts: [String] = []
        if !machine.isReachable {
            parts.append(machine.offlineReason.map { WorkspacesText.offline + " · " + $0 } ?? WorkspacesText.offline)
        } else if machine.isResyncing {
            parts.append(WorkspacesText.updating)
        }
        if section.kind == .empty {
            parts.append(WorkspacesText.noWorkspacesOnMachine)
        } else {
            parts.append(WorkspacesText.workspaceCount(machine.workspaceCount))
        }
        if section.kind != .empty, let title = title(section.kind) { parts.append(title) }
        return parts.joined(separator: " · ")
    }

    static func title(_ kind: WorkspaceListSectionKind) -> String? {
        switch kind {
        case .pinned: WorkspacesText.pinned
        case .group(_, let name): name
        case .workspaces: WorkspacesText.workspaces
        case .flat: WorkspacesText.allWorkspaces
        case .empty: nil
        }
    }
}
