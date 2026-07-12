import CMUXMobileCore
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct MobileHostTerminalThemeTests {
    @Test func surfaceEffectiveColorsOverrideCachedConfigTheme() throws {
        var base = TerminalTheme.monokai
        base.cursorText = "#abcdef"
        let frame = try MobileTerminalRenderGridFrame(
            surfaceID: "surface-theme",
            stateSeq: 1,
            columns: 2,
            rows: 1,
            rowSpans: [],
            terminalForeground: "#112233",
            terminalBackground: "#f0ead6",
            terminalCursorColor: "#445566"
        )

        let resolved = base.applyingSurfaceColors(from: frame)

        #expect(resolved.background == "#f0ead6")
        #expect(resolved.foreground == "#112233")
        #expect(resolved.cursor == "#445566")
        #expect(resolved.cursorText == "#abcdef")
        #expect(resolved.palette == base.palette)
    }
}
