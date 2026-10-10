@testable import CNBrowserUI
import CoreGraphics
import Testing

/// iPhone 17 Pro Max: 440 x 956 pt, 62 pt top / 34 pt bottom safe area.
private func proMax(count: Int) -> OverviewLayout {
    OverviewLayout(size: CGSize(width: 440, height: 956), safeTop: 62, safeBottom: 34, count: count)
}

struct OverviewLayoutTests {
    /// Grid metrics measured on the device recordings.
    @Test func proMaxMetricsMatchSafari() {
        let g = proMax(count: 7)
        #expect(g.cardWidth == 196)
        #expect(abs(g.cardHeight - 276) < 0.5)
        #expect(g.card(0).origin == CGPoint(x: 16, y: 122))
        #expect(g.card(1).minX == 228)
        #expect(abs(g.card(5).minY - 752) < 0.5)
        // safari-scroll-into-view-device.mp4: fully scrolled, row 2 sits at 244.
        #expect(abs(g.maxOffset - 508) < 2)
    }

    /// The zoom endpoint is the card's frame converted to the screen at the
    /// grid's scroll offset, also for cards partly or wholly off screen.
    @Test(arguments: [0.0, 120, 315, 400, 508])
    func endpointIsTheCardsScreenFrame(offset: CGFloat) {
        let g = proMax(count: 7)
        for i in 0..<7 {
            let e = g.screenFrame(i, offset: offset)
            #expect(e == g.card(i).offsetBy(dx: 0, dy: -offset))
            #expect(e.size == CGSize(width: g.cardWidth, height: g.cardHeight))
        }
        // At offset 400 the first row is above the screen and the last row is
        // cut off by the bottom: frames still follow the content exactly.
        if offset == 400 {
            #expect(g.screenFrame(0, offset: 400).maxY < 0)
            #expect(!g.isFullyVisible(6, offset: 400))
        }
    }

    /// Recorded cases: index 5 and 6 of 7 from offset 0 both end at 508.
    @Test func revealMatchesTheRecording() {
        let g = proMax(count: 7)
        #expect(abs(g.offset(revealing: 5, from: 0) - g.maxOffset) < 0.5)
        #expect(abs(g.offset(revealing: 6, from: 0) - g.maxOffset) < 0.5)
        // Already fully visible: the offset is kept.
        #expect(g.offset(revealing: 2, from: 0) == 0)
        #expect(g.offset(revealing: 4, from: 508) == 508)
    }

    @Test func revealedCardIsFullyVisible() {
        let g = proMax(count: 24)
        for i in 0..<24 {
            for start in stride(from: 0.0, through: Double(g.maxOffset), by: 137) {
                let o = g.offset(revealing: i, from: CGFloat(start))
                #expect(o >= 0 && o <= g.maxOffset)
                #expect(g.isFullyVisible(i, offset: o), "card \(i) from \(start)")
            }
        }
    }

    @Test func revealScrollsUpToACardAboveTheScreen() {
        let g = proMax(count: 24)
        let o = g.offset(revealing: 2, from: 2000)
        #expect(abs(g.screenFrame(2, offset: o).minY - g.top) < 0.5)
    }
}
