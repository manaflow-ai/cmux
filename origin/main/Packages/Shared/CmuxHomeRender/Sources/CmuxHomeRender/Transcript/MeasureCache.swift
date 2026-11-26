import CmuxHomeCore
import CoreGraphics
import Foundation

/// Measured bubbles by (item key, part index). A wrap-width change re-asks
/// Core Text only for parts whose lines can change (`TextLayout.isValid`);
/// every other part keeps its layout, so its row spec and bitmap stay equal.
@MainActor
final class MeasureCache {
    struct Key: Hashable {
        var item: IdempotencyKey
        var part: Int
    }

    struct Entry {
        var text: String
        var bold: [NSRange]
        var wrapWidth: CGFloat
        var layout: TextLayout
        var size: CGSize
    }

    private var entries: [Key: Entry] = [:]
    /// Core Text measurements made (tests read it to prove reflow skips rows).
    private(set) var measureCount = 0

    func measure(item: IdempotencyKey, part: Int, text: String, bold: [NSRange], wrapWidth: CGFloat) -> Entry {
        let key = Key(item: item, part: part)
        if var cached = entries[key], cached.text == text, cached.bold == bold {
            if cached.layout.isValid(atMaxWidth: wrapWidth, measuredAt: cached.wrapWidth) {
                if cached.wrapWidth != wrapWidth {
                    cached.wrapWidth = wrapWidth
                    entries[key] = cached
                }
                return cached
            }
        }
        measureCount += 1
        let layout = TextLayout.make(text, bold: bold, maxWidth: wrapWidth, font: Style.bodyFont)
        let size = CGSize(width: min(layout.width, wrapWidth) + 2 * Style.bubblePadX,
                          height: CGFloat(layout.lines.count) * Style.lineHeight + 2 * Style.bubblePadY)
        let entry = Entry(text: text, bold: bold, wrapWidth: wrapWidth, layout: layout, size: size)
        entries[key] = entry
        return entry
    }

    /// Drops measurements of items that left the transcript.
    func trim(keeping items: Set<IdempotencyKey>) {
        guard entries.count > 2 * items.count + 200 else { return }
        entries = entries.filter { items.contains($0.key.item) }
    }
}
