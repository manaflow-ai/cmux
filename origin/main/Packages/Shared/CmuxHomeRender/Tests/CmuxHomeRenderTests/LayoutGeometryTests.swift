import CmuxHomeCore
import CoreGraphics
import Foundation
import Testing
@testable import CmuxHomeRender

@MainActor
@Suite struct LayoutGeometryTests {
    /// Lines cover the text in order; only hard newlines are skipped; every
    /// soft-wrapped line fits the wrap width.
    @Test(arguments: [120.0, 200.0, 358.4, 900.0])
    func wrapCoversTextAndFits(maxWidth: Double) {
        let texts = [Fixtures.longLine, "one\ntwo\n\nfour", "short", "", "trailing newline\n", String(repeating: "word ", count: 80)]
        for text in texts {
            let tl = TextLayout.make(text, maxWidth: CGFloat(maxWidth), font: Style.bodyFont)
            let ns = text as NSString
            var cursor = 0
            for line in tl.lines {
                #expect(line.range.location == cursor)
                cursor = NSMaxRange(line.range)
                if cursor < ns.length, ns.character(at: cursor) == 10 { cursor += 1 }
                if line.softBreak {
                    let visible = ns.substring(with: line.range).trimmingCharacters(in: .whitespaces)
                    #expect(TextDraw.width(visible, font: Style.bodyFont) <= CGFloat(maxWidth) + 0.5, "\(visible)")
                }
            }
            #expect(cursor == ns.length)
            #expect(tl.lines.count >= 1)
        }
    }

    @Test func bubbleSizeFollowsLines() {
        let cache = MeasureCache()
        let wrap = Metrics(width: 628).maxTextWidth
        let entry = cache.measure(item: IdempotencyKey("k"), part: 0, text: Fixtures.longLine, bold: [], wrapWidth: wrap)
        #expect(entry.layout.lines.count > 1)
        #expect(entry.size.width <= wrap + 2 * Style.bubblePadX)
        #expect(entry.size.height == CGFloat(entry.layout.lines.count) * Style.lineHeight + 2 * Style.bubblePadY)
    }

    @Test func metricsMatchReferenceAndScale() {
        let m = Metrics(width: 628)
        #expect(m.rightEdge == 608)
        #expect(m.receiptRight == 592.2)
        #expect(abs(m.centerX - 313.9) < 1e-9)
        #expect(m.maxTextWidth == 358.4)
        #expect(Metrics(width: 1256).maxTextWidth == 716.8)
    }

    /// Rows stack without overlap, groups use 3 pt gaps, a new author 32 pt,
    /// a gap of more than 15 minutes starts a separator, and only the last
    /// bubble of a group has a tail.
    @Test func rowsStackWithMeasuredGaps() {
        var messages = Fixtures.conversation(6)
        messages.append(Fixtures.message(7, Fixtures.chief, "Back after lunch.", at: 7 * 30 + 3600))
        let builder = RowBuilder(format: RowFormat(calendar: Fixtures.calendar, locale: Locale(identifier: "en_US")))
        let ctx = RowContext(me: Fixtures.me, now: Fixtures.start.addingTimeInterval(7200), metrics: Metrics(width: 628),
                             readByOthers: nil, othersTyping: false)
        let rows = builder.rows(Fixtures.items(messages), ctx)
        #expect(rows.filter { if case .separator = $0.kind { true } else { false } }.count == 2)
        let parts = rows.filter { $0.partRow != nil }
        #expect(parts.count == 7)
        // Messages 1-2 chief, 3-4 me, 5-6 chief, then 7 chief after an hour.
        #expect(parts[1].gap == 3)
        #expect(parts[2].gap == 32)
        #expect(parts.map { $0.partRow?.tail ?? false } == [false, true, false, true, false, true, true])
        let model = TranscriptModel()
        model.set(rows, at: 0, ghosts: false)
        for i in 1..<model.count {
            #expect(model.contentTop(i) >= model.contentTop(i - 1) + model.rows[i - 1].spec.height)
        }
    }

    @Test func bodiesAlignToTheirSide() {
        let m = Metrics(width: 700)
        let builder = RowBuilder(format: RowFormat(calendar: Fixtures.calendar))
        let ctx = RowContext(me: Fixtures.me, now: Fixtures.start, metrics: m, readByOthers: nil, othersTyping: false)
        for spec in builder.rows(Fixtures.items(Fixtures.conversation(4)), ctx) {
            guard let p = spec.partRow else { continue }
            let body = RowArt.bodyRect(spec, metrics: m)
            if p.outgoing { #expect(body.maxX == m.rightEdge) } else { #expect(body.minX == Style.leftEdge) }
            let art = RowArt.frame(spec, metrics: m)
            #expect(art.minX <= body.minX - 22 && art.maxX >= body.maxX + 14.25)
            #expect(art.height >= body.maxY + BubblePath.tailDrop)
        }
    }

    @Test func receiptsMarkReadAndDelivered() {
        let messages = Fixtures.conversation(8)
        let items = Fixtures.items(messages)
        let mine = items.filter { $0.author == Fixtures.me }.compactMap(\.seq)
        let receipts = RowBuilder.receipts(items, me: Fixtures.me, readByOthers: mine[0])
        #expect(receipts.count == 2)
        #expect(receipts[IdempotencyKey("key_\(mine[0])")] == HomeStrings.read)
        #expect(receipts[IdempotencyKey("key_\(mine.last ?? 0)")] == HomeStrings.delivered)
        #expect(RowBuilder.receipts(items, me: Fixtures.me, readByOthers: 99).count == 1)
    }
}
