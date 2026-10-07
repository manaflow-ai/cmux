import CmuxiOSDesign
import CmuxiOSWorkspacesCore
import UIKit

/// Section headers: a machine header (color dot, name, state, count) on the
/// first section of each Mac, a plain title on the others.
@MainActor
enum WorkspaceSectionHeader {
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
        case .group(let name): name
        case .workspaces: WorkspacesText.workspaces
        case .flat: WorkspacesText.allWorkspaces
        case .empty: nil
        }
    }
}
