import CoreGraphics
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Right sidebar mode tab widths")
struct RightSidebarModeBarTabWidthsTests {
    private let natural: [CGFloat] = [60, 56, 62, 58, 64]
    private let floors: [CGFloat] = [30, 30, 30, 30, 30]

    @Test("A wide bar gives every tab its full label and leaves the rest empty")
    func wideBarStopsAtFullLabels() {
        let widths = RightSidebarModeBarTabWidths(natural: natural, floors: floors, selected: 4, available: 600).widths
        #expect(widths == natural)
    }

    @Test("A narrower bar keeps the selected tab whole and shares the rest equally")
    func narrowBarSharesTheRest() {
        let widths = RightSidebarModeBarTabWidths(natural: natural, floors: floors, selected: 4, available: 264).widths
        #expect(widths[4] == 64)
        #expect(widths.prefix(4).allSatisfy { $0 == 50 })
    }

    @Test("A tab whose full label fits its share takes only that, and the others get the rest")
    func shortLabelsReturnTheirSpare() {
        let widths = RightSidebarModeBarTabWidths(natural: [40, 80, 80, 64], floors: [30, 30, 30, 30], selected: 3, available: 224).widths
        #expect(widths == [40, 60, 60, 64])
    }

    @Test("Tabs never shrink below their floor, even when the bar is too small")
    func floorsHold() {
        let widths = RightSidebarModeBarTabWidths(natural: natural, floors: floors, selected: 4, available: 100).widths
        #expect(widths[4] == 64)
        #expect(widths.prefix(4).allSatisfy { $0 == 30 })
    }

    @Test("A tab with a wider floor narrows the others instead of overflowing the bar")
    func widerFloorStaysWithinTheBar() {
        let widths = RightSidebarModeBarTabWidths(natural: natural, floors: [30, 50, 30, 30, 30], selected: 4, available: 214).widths
        #expect(widths[4] == 64)
        #expect(widths[1] == 50)
        #expect(abs(widths.reduce(0, +) - 214) < 0.001)
        #expect(widths.allSatisfy { $0 >= 30 })
    }

    @Test("Without a selected tab every tab shares the bar")
    func noSelection() {
        let widths = RightSidebarModeBarTabWidths(natural: natural, floors: floors, selected: nil, available: 200).widths
        #expect(widths.allSatisfy { $0 == 40 })
    }
}
