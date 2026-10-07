import CmuxiOSDesign
import UIKit

/// Cell content for placeholder rows: symbol, title, subtitle, status tint
/// and an unread count. Gray-scale except the small status glyph.
@MainActor
enum PlaceholderCellStyle {
    static func configure(_ cell: UICollectionViewListCell, with row: PlaceholderRow) {
        var content = UIListContentConfiguration.subtitleCell()
        content.text = row.title
        content.secondaryText = row.subtitle
        content.textProperties.font = ShellTypography.rowTitle
        content.textProperties.color = ShellPalette.primaryText
        content.secondaryTextProperties.font = ShellTypography.rowSubtitle
        content.secondaryTextProperties.color = ShellPalette.secondaryText
        content.secondaryTextProperties.numberOfLines = 3
        content.image = UIImage(systemName: row.symbolName)
        content.imageProperties.tintColor = tint(for: row.status)
        content.directionalLayoutMargins.top = ShellMetrics.rowVerticalPadding
        content.directionalLayoutMargins.bottom = ShellMetrics.rowVerticalPadding
        content.textToSecondaryTextVerticalPadding = ShellMetrics.rowSpacing
        cell.contentConfiguration = content
        var accessories: [UICellAccessory] = []
        if let badge = row.badge, badge > 0 {
            accessories.append(.label(text: String(badge), options: .init(font: ShellTypography.chip)))
        }
        cell.accessories = accessories
        cell.accessibilityLabel = [row.title, row.subtitle, row.status.map(ShellText.status)]
            .compactMap { $0 }.joined(separator: ", ")
    }

    private static func tint(for status: PlaceholderStatus?) -> UIColor {
        switch status {
        case .running: ShellPalette.statusRunning
        case .waiting: ShellPalette.statusWaiting
        case .failed: ShellPalette.statusFailed
        case .idle: ShellPalette.statusIdle
        case nil: ShellPalette.secondaryText
        }
    }
}
