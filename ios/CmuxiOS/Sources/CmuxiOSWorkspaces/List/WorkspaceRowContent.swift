import CmuxiOSDesign
import CmuxiOSWorkspacesCore
import UIKit

/// Fills a list cell for one workspace row: status glyph, title, preview
/// line, unread badge; in the flat list a machine color bar and the
/// machine name lead.
@MainActor
enum WorkspaceRowContent {
    static func configure(_ cell: UICollectionViewListCell, row: WorkspaceListRow, flat: Bool,
                          actions: [UIAccessibilityCustomAction]) {
        var content = UIListContentConfiguration.subtitleCell()
        content.text = row.title
        content.textProperties.font = ShellTypography.rowTitle
        content.textProperties.adjustsFontForContentSizeCategory = true
        content.textProperties.color = row.isReachable ? ShellPalette.primaryText : ShellPalette.secondaryText
        content.textProperties.numberOfLines = 1
        content.secondaryText = subtitle(row, flat: flat)
        content.secondaryTextProperties.font = ShellTypography.rowSubtitle
        content.secondaryTextProperties.adjustsFontForContentSizeCategory = true
        content.secondaryTextProperties.color = ShellPalette.secondaryText
        content.secondaryTextProperties.numberOfLines = 1
        content.image = UIImage(systemName: row.status.symbolName)
        content.imageProperties.tintColor = row.isReachable ? row.status.tint : ShellPalette.statusIdle
        content.imageProperties.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .subheadline)
        content.textToSecondaryTextVerticalPadding = ShellMetrics.rowSpacing / 2
        cell.contentConfiguration = content

        var accessories: [UICellAccessory] = []
        if flat {
            let bar = UICellAccessory.CustomViewConfiguration(
                customView: MachineBar(color: row.machineColor.uiColor), placement: .leading(), reservedLayoutWidth: .custom(3))
            accessories.append(.customView(configuration: bar))
        }
        if row.unreadCount > 0 {
            let badge = UICellAccessory.CustomViewConfiguration(
                customView: UnreadBadge(count: row.unreadCount), placement: .trailing(displayed: .always))
            accessories.append(.customView(configuration: badge))
        }
        accessories.append(.disclosureIndicator())
        cell.accessories = accessories

        cell.accessibilityIdentifier = "workspaces.row." + row.workspaceID
        cell.isAccessibilityElement = true
        cell.accessibilityLabel = accessibilityLabel(row)
        cell.accessibilityTraits = .button
        cell.accessibilityCustomActions = actions
    }

    static func subtitle(_ row: WorkspaceListRow, flat: Bool) -> String {
        let detail = row.preview?.isEmpty == false ? row.preview! : WorkspacesText.paneCount(row.paneCount)
        return flat ? row.machineName + " · " + detail : detail
    }

    static func accessibilityLabel(_ row: WorkspaceListRow) -> String {
        var parts = [row.title, row.machineName]
        parts.append(row.isReachable ? row.status.label : WorkspacesText.offline)
        if row.unreadCount > 0 { parts.append(WorkspacesText.unreadCount(row.unreadCount)) }
        if let preview = row.preview, !preview.isEmpty { parts.append(preview) }
        return parts.joined(separator: ", ")
    }
}
