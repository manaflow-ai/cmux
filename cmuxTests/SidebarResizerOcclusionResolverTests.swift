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

    /// Verifies a left tool sidebar exposes leading-edge divider hit geometry.
    @Test func leftToolSidebarUsesLeadingEdgeHitGeometry() {
        let resolver = SidebarResizerOcclusionResolver { _ in 10 }
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let dividerX: CGFloat = 220

        #expect(
            resolver.dividerBandContains(
                point: CGPoint(x: dividerX - SidebarResizeInteraction.sidebarSideHitWidth, y: 100),
                contentBounds: bounds,
                isLeftSidebarVisible: false,
                leftDividerX: 0,
                isRightSidebarVisible: true,
                rightDividerX: dividerX,
                rightSidebarEdge: .leading
            )
        )
    }

    /// Verifies a left tool sidebar rejects points unique to trailing-edge geometry.
    @Test func leftToolSidebarDoesNotUseTrailingEdgeHitGeometry() {
        let resolver = SidebarResizerOcclusionResolver { _ in 10 }
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let dividerX: CGFloat = 220
        let trailingOnlyX = dividerX + SidebarResizeInteraction.sidebarSideHitWidth - 1

        #expect(
            !resolver.dividerBandContains(
                point: CGPoint(x: trailingOnlyX, y: 100),
                contentBounds: bounds,
                isLeftSidebarVisible: false,
                leftDividerX: 0,
                isRightSidebarVisible: true,
                rightDividerX: dividerX,
                rightSidebarEdge: .leading
            )
        )
    }
}
