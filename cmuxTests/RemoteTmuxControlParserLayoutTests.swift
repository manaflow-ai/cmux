import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct RemoteTmuxControlParserLayoutTests {
    private func parse(_ protocolText: String) -> [RemoteTmuxControlMessage] {
        var parser = RemoteTmuxControlStreamParser()
        return parser.feed(Data(protocolText.utf8))
    }

@Test func layoutChangeCarriesBaseVisibleAndZoom() {
        // Real 3.7 shape: base tree, visible tree, window flags. Zoom derives
        // from `Z` in the flags — per event, never latched (tmux auto-unzooms
        // on its own, e.g. killing a hidden pane while zoomed).
        let plain = parse("%layout-change @4 f92f,80x24,0,0,1 f92f,80x24,0,0,1 *\r\n")
        #expect(plain == [.layoutChange(
            windowId: 4, layout: "f92f,80x24,0,0,1",
            visibleLayout: "f92f,80x24,0,0,1", zoomed: false
        )])
        let zoomed = parse(
            "%layout-change @1 95e4,120x40,0,0{60x40,0,0,0,59x40,61,0,1} aafe,120x40,0,0,1 *Z\r\n"
        )
        #expect(zoomed == [.layoutChange(
            windowId: 1,
            layout: "95e4,120x40,0,0{60x40,0,0,0,59x40,61,0,1}",
            visibleLayout: "aafe,120x40,0,0,1",
            zoomed: true
        )])
    }
}
