import CmuxiOSDesign
import CmuxiOSSearchCore
import UIKit

/// How a result row looks: kind glyph, title and subtitle with the matched
/// characters bolded, a status badge, and one combined VoiceOver label.
@MainActor
struct SearchResultCellStyle {
    static func apply(_ result: SearchResult, to cell: UICollectionViewListCell) {
        let item = result.item
        let primary = item.isDimmed ? ShellPalette.secondaryText : ShellPalette.primaryText
        var content = UIListContentConfiguration.subtitleCell()
        content.attributedText = SearchHighlighter(font: ShellTypography.rowTitle, color: primary)
            .attributed(item.title, ranges: result.titleRanges)
        if let subtitle = item.subtitle {
            content.secondaryAttributedText = SearchHighlighter(font: ShellTypography.rowSubtitle, color: ShellPalette.secondaryText)
                .attributed(subtitle, ranges: result.subtitleRanges)
            content.secondaryTextProperties.numberOfLines = 1
        }
        content.textProperties.numberOfLines = 2
        content.image = UIImage(systemName: item.symbolName)
        content.imageProperties.tintColor = ShellPalette.secondaryText
        content.textToSecondaryTextVerticalPadding = ShellMetrics.rowSpacing
        cell.contentConfiguration = content
        if let badge = item.badge {
            cell.accessories = [.label(text: badge, displayed: .always,
                                       options: .init(tintColor: ShellPalette.secondaryText, font: ShellTypography.caption))]
        } else {
            cell.accessories = []
        }
        cell.accessibilityLabel = [item.title, item.subtitle, item.badge, SearchScreenText.title(item.category)]
            .compactMap { $0 }.joined(separator: ", ")
        cell.accessibilityTraits = .button
        cell.accessibilityIdentifier = "search.result." + item.id
    }
}
