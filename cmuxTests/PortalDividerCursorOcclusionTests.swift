import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct PortalDividerCursorOcclusionTests {
    @Test func sameTopmostWindowMayAssertCursor() {
        let occlusion = PortalDividerCursorOcclusion { _ in 10 }

        #expect(occlusion.mayAssertDividerCursor(screenPoint: .zero, windowNumber: 10))
    }

    @Test func overlappingWindowSuppressesCursor() {
        let occlusion = PortalDividerCursorOcclusion { _ in 11 }

        #expect(!occlusion.mayAssertDividerCursor(screenPoint: .zero, windowNumber: 10))
    }

    @Test func nilPointerWindowSuppressesCursor() {
        let occlusion = PortalDividerCursorOcclusion { _ in nil }

        #expect(!occlusion.mayAssertDividerCursor(screenPoint: .zero, windowNumber: 10))
    }

    @Test func nilHostWindowSuppressesCursor() {
        let occlusion = PortalDividerCursorOcclusion { _ in 10 }

        #expect(!occlusion.mayAssertDividerCursor(in: nil))
    }

    @Test func hitTestKeepsCursorDuringLeftButtonDrag() {
        let occlusion = PortalDividerCursorOcclusion(
            topmostMouseEventWindowNumber: { _ in 11 },
            isLeftMouseButtonPressed: { true }
        )

        #expect(occlusion.mayAssertDividerCursorDuringHitTest(in: nil))
    }

    @Test func hitTestSuppressesHoverCursorWhenNotDragging() {
        let occlusion = PortalDividerCursorOcclusion(
            topmostMouseEventWindowNumber: { _ in 11 },
            isLeftMouseButtonPressed: { false }
        )

        #expect(!occlusion.mayAssertDividerCursorDuringHitTest(in: nil))
    }
}
