import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct SidebarResizerOcclusionResolverTests {
    @Test func eitherLeftColumnDividerIsInsideTheOcclusionBand() {
        let resolver = SidebarResizerOcclusionResolver { _ in 10 }
        let bounds = NSRect(x: 0, y: 0, width: 1_000, height: 800)

        #expect(
            resolver.dividerBandContains(
                point: NSPoint(x: 168, y: 400),
                contentBounds: bounds,
                isLeftSidebarVisible: true,
                leftDividerXs: [168, 408],
                isRightSidebarVisible: false,
                rightDividerX: 1_000
            )
        )
        #expect(
            resolver.dividerBandContains(
                point: NSPoint(x: 408, y: 400),
                contentBounds: bounds,
                isLeftSidebarVisible: true,
                leftDividerXs: [168, 408],
                isRightSidebarVisible: false,
                rightDividerX: 1_000
            )
        )
    }

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
}
