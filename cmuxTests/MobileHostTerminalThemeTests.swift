import CMUXMobileCore
import Foundation
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

    @Test func rendererEffectiveThemeWinsOverRawOSCOverrides() throws {
        var effective = TerminalTheme.monokai
        effective.background = "#eeeeee"
        effective.foreground = "#111111"
        let frame = try MobileTerminalRenderGridFrame(
            surfaceID: "surface-reverse-theme",
            stateSeq: 1,
            columns: 2,
            rows: 1,
            rowSpans: [],
            terminalForeground: "#eeeeee",
            terminalBackground: "#111111",
            terminalTheme: effective
        )

        let resolved = TerminalTheme.monokai.applyingSurfaceColors(from: frame)

        #expect(resolved == effective)
    }

    @Test func reverseModeMakesRawV1DefaultsEffectiveForChrome() throws {
        let frame = try MobileTerminalRenderGridFrame(
            surfaceID: "surface-reverse-theme",
            stateSeq: 1,
            columns: 2,
            rows: 1,
            rowSpans: [],
            modes: [.init(code: 5, ansi: false, on: true)],
            terminalForeground: "#111111",
            terminalBackground: "#eeeeee"
        )

        let resolved = TerminalTheme.monokai.applyingSurfaceColors(from: frame)

        #expect(resolved.background == "#111111")
        #expect(resolved.foreground == "#eeeeee")
    }

    @MainActor
    @Test func producerThemeInvalidationsCoalesceToLatestSurfaceBatch() {
        let first = UUID()
        let second = UUID()
        var batches: [Set<UUID>] = []
        let scheduler = MobileTerminalThemeInvalidationScheduler(delay: .seconds(60)) {
            batches.append($0)
        }

        scheduler.schedule(surfaceID: first)
        scheduler.schedule(surfaceID: first)
        scheduler.schedule(surfaceID: second)
        scheduler.flushForTesting()

        #expect(batches == [Set([first, second])])
    }

    @Test func ordinaryTicksDeferChangedThemeUntilProducerBatch() {
        var cached = TerminalTheme.monokai
        cached.background = "#101522"
        var candidate = TerminalTheme.monokai
        candidate.background = "#f4f0df"

        let ordinaryTick = MobileTerminalThemeEmissionDecision.resolve(
            candidate: candidate,
            cached: cached,
            forceCandidate: false
        )
        let invalidationBatch = MobileTerminalThemeEmissionDecision.resolve(
            candidate: candidate,
            cached: cached,
            forceCandidate: true
        )

        #expect(ordinaryTick.theme == cached)
        #expect(ordinaryTick.shouldScheduleCandidate)
        #expect(invalidationBatch.theme == candidate)
        #expect(!invalidationBatch.shouldScheduleCandidate)
    }
}
