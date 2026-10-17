import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct SidebarResizerOcclusionResolverTests {
    @Test func draggingBypassesPointerWindowGate() {
        var queryCount = 0
        let resolver = SidebarResizerOcclusionResolver { _ in
            queryCount += 1
            return 11
        }

        #expect(
            resolver.bandMayActivate(
                isDragging: true,
                isInDividerBand: false,
                screenPoint: .zero,
                observedWindowNumber: 10
            )
        )
        #expect(queryCount == 0)
    }

    @Test func inBandSameWindowActivates() {
        let resolver = SidebarResizerOcclusionResolver { _ in 10 }

        #expect(
            resolver.bandMayActivate(
                isDragging: false,
                isInDividerBand: true,
                screenPoint: .zero,
                observedWindowNumber: 10
            )
        )
    }

    @Test func inBandDifferentWindowDoesNotActivate() {
        let resolver = SidebarResizerOcclusionResolver { _ in 11 }

        #expect(
            !resolver.bandMayActivate(
                isDragging: false,
                isInDividerBand: true,
                screenPoint: .zero,
                observedWindowNumber: 10
            )
        )
    }

    @Test func inBandNilPointerWindowDoesNotActivate() {
        let resolver = SidebarResizerOcclusionResolver { _ in nil }

        #expect(
            !resolver.bandMayActivate(
                isDragging: false,
                isInDividerBand: true,
                screenPoint: .zero,
                observedWindowNumber: 10
            )
        )
    }

    @Test func outOfBandDoesNotActivate() {
        var queryCount = 0
        let resolver = SidebarResizerOcclusionResolver { _ in
            queryCount += 1
            return 10
        }

        #expect(
            !resolver.bandMayActivate(
                isDragging: false,
                isInDividerBand: false,
                screenPoint: .zero,
                observedWindowNumber: 10
            )
        )
        #expect(queryCount == 0)
    }

    /// The band's content side lies over a Chromium page, whose child window
    /// is the topmost window at the pointer: it acts for the observed window,
    /// so the resizer still activates there (and the page leaves a hole).
    @Test func inBandOverOwnChromiumPageWindowActivates() {
        let resolver = SidebarResizerOcclusionResolver(
            topmostMouseEventWindowNumber: { _ in 99 },
            actingWindowNumber: { $0 == 99 ? 10 : $0 }
        )

        #expect(
            resolver.bandMayActivate(
                isDragging: false,
                isInDividerBand: true,
                screenPoint: .zero,
                observedWindowNumber: 10
            )
        )
    }

    @Test func inBandOverAnotherWindowsChromiumPageDoesNotActivate() {
        let resolver = SidebarResizerOcclusionResolver(
            topmostMouseEventWindowNumber: { _ in 99 },
            actingWindowNumber: { $0 == 99 ? 11 : $0 }
        )

        #expect(
            !resolver.bandMayActivate(
                isDragging: false,
                isInDividerBand: true,
                screenPoint: .zero,
                observedWindowNumber: 10
            )
        )
    }
}
