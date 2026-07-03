import CoreGraphics
import Foundation
import Testing

@testable import CmuxMobileTerminalKit

/// Pure-math contract for the stretch-to-fill font fit (see
/// `TerminalViewportSpacingTests` for the in-simulator behavior).
@Suite("TerminalRowCapacityFit math")
struct TerminalRowCapacityFitTests {
    @Test("capacity reports base-font rows regardless of the fitted live font")
    func capacityIndependentOfLiveFont() {
        // 1902px container, 35px cells at 10pt: 54 rows of capacity.
        let atBase = TerminalRowCapacityFit(
            containerPixelHeight: 1902, cellPixelHeight: 35, liveFontSize: 10
        )?.capacityRows(atBaseFontSize: 10)
        #expect(atBase == 54)

        // Fitted up to 12pt the cells measure 42px, but capacity is still the
        // base-font answer — the report must not ratchet the negotiation.
        let atFitted = TerminalRowCapacityFit(
            containerPixelHeight: 1902, cellPixelHeight: 42, liveFontSize: 12
        )?.capacityRows(atBaseFontSize: 10)
        #expect(atFitted == 54)
    }

    @Test("fit font makes exactly the granted rows fill the container")
    func fitFontFillsGrantedRows() throws {
        // 54-row capacity, daemon grants 45: the fitted font's cell height
        // must floor the container to exactly 45 rows.
        let font = try #require(TerminalRowCapacityFit(
            containerPixelHeight: 1902, cellPixelHeight: 35, liveFontSize: 10
        )?.fitFontSize(forEffectiveRows: 45))
        #expect(font > 10)
        let fittedCell = 35 * CGFloat(font) / 10
        let renderedRows = Int((1902 / fittedCell).rounded(.down))
        #expect(renderedRows == 45)
    }

    @Test("fit font shrinks below live when granted more rows than rendered")
    func fitFontShrinksForBiggerGrants() throws {
        let font = try #require(TerminalRowCapacityFit(
            containerPixelHeight: 1902, cellPixelHeight: 42, liveFontSize: 12
        )?.fitFontSize(forEffectiveRows: 54))
        #expect(font < 12)
        let fittedCell = 42 * CGFloat(font) / 12
        #expect(Int((1902 / fittedCell).rounded(.down)) == 54)
    }

    @Test("row fit cap preserves base-font column share")
    func rowFitCapPreservesBaseFontColumnShare() throws {
        let uncapped = try #require(TerminalRowCapacityFit(
            containerPixelHeight: 2412, cellPixelHeight: 35, liveFontSize: 10
        )?.fitFontSize(forEffectiveRows: 22))
        let capped = try #require(TerminalRowCapacityFit(
            containerPixelHeight: 2412, cellPixelHeight: 35, liveFontSize: 10
        )?.fitFontSize(forEffectiveRows: 22, baseFontSize: 10, renderedColumns: 66))
        #expect(uncapped > 28)
        #expect(capped < uncapped)
        let preservedColumns = Int((CGFloat(66) * 10 / CGFloat(capped)).rounded(.down))
        #expect(preservedColumns >= 49)
    }

    @Test("hysteresis ignores one-row mismatches and acts on two")
    func refitHysteresis() {
        #expect(!TerminalRowCapacityFit.shouldRefit(renderedRows: 45, effectiveRows: 45))
        #expect(!TerminalRowCapacityFit.shouldRefit(renderedRows: 46, effectiveRows: 45))
        #expect(!TerminalRowCapacityFit.shouldRefit(renderedRows: 44, effectiveRows: 45))
        #expect(TerminalRowCapacityFit.shouldRefit(renderedRows: 47, effectiveRows: 45))
        #expect(TerminalRowCapacityFit.shouldRefit(renderedRows: 43, effectiveRows: 45))
        #expect(!TerminalRowCapacityFit.shouldRefit(renderedRows: 0, effectiveRows: 45))
    }

    @Test("unmeasurable inputs return nil instead of degenerate fits")
    func unmeasurableInputs() {
        #expect(TerminalRowCapacityFit(
            containerPixelHeight: 0, cellPixelHeight: 35, liveFontSize: 10
        ) == nil)
        #expect(TerminalRowCapacityFit(
            containerPixelHeight: 1902, cellPixelHeight: 0, liveFontSize: 10
        ) == nil)
        #expect(TerminalRowCapacityFit(
            containerPixelHeight: 1902, cellPixelHeight: 35, liveFontSize: 10
        )?.capacityRows(atBaseFontSize: 0) == nil)
    }
}
