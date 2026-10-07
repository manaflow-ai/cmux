import UIKit

/// Bolds the matched characters of a row label. Ranges are character
/// offsets (from `SearchMatcher`), converted to UTF-16 here.
struct SearchHighlighter {
    let font: UIFont
    let color: UIColor

    func attributed(_ text: String, ranges: [Range<Int>]) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        guard !ranges.isEmpty else { return result }
        let bold = UIFont(descriptor: font.fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.semibold],
        ]), size: 0)
        let count = text.count
        for range in ranges where range.lowerBound < count {
            let lower = text.index(text.startIndex, offsetBy: range.lowerBound)
            let upper = text.index(text.startIndex, offsetBy: min(range.upperBound, count))
            result.addAttribute(.font, value: bold, range: NSRange(lower..<upper, in: text))
        }
        return result
    }
}
