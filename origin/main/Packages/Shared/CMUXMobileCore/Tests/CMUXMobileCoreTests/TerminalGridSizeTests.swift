import Foundation
import Testing
@testable import CMUXMobileCore

@Suite struct TerminalGridSizeTests {
    @Test func codableRoundTripPreservesAllFields() throws {
        let original = TerminalGridSize(columns: 100, rows: 32, pixelWidth: 900, pixelHeight: 650)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TerminalGridSize.self, from: data)
        #expect(decoded == original)
        #expect(decoded.columns == 100)
        #expect(decoded.rows == 32)
        #expect(decoded.pixelWidth == 900)
        #expect(decoded.pixelHeight == 650)
    }

    @Test func equalityRequiresEveryFieldToMatch() {
        let base = TerminalGridSize(columns: 80, rows: 24, pixelWidth: 720, pixelHeight: 480)
        #expect(base == TerminalGridSize(columns: 80, rows: 24, pixelWidth: 720, pixelHeight: 480))
        #expect(base != TerminalGridSize(columns: 81, rows: 24, pixelWidth: 720, pixelHeight: 480))
        #expect(base != TerminalGridSize(columns: 80, rows: 25, pixelWidth: 720, pixelHeight: 480))
        #expect(base != TerminalGridSize(columns: 80, rows: 24, pixelWidth: 721, pixelHeight: 480))
        #expect(base != TerminalGridSize(columns: 80, rows: 24, pixelWidth: 720, pixelHeight: 481))
    }

    @Test func equalValuesHashEqually() {
        let a = TerminalGridSize(columns: 120, rows: 40, pixelWidth: 1080, pixelHeight: 800)
        let b = TerminalGridSize(columns: 120, rows: 40, pixelWidth: 1080, pixelHeight: 800)
        var set: Set<TerminalGridSize> = []
        set.insert(a)
        set.insert(b)
        #expect(set.count == 1)
    }
}
