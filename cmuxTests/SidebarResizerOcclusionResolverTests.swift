import AppKit
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

    // App activation reaches the app as an AppKit-defined event. Swallowing
    // it while the pointer rests on the divider leaves the app unable to
    // become active, so the keyboard stops working.
    @Test(arguments: [NSEvent.EventType.appKitDefined, .systemDefined])
    func appAndSystemEventsPassWhileBandIsActive(eventType: NSEvent.EventType) {
        let resolver = SidebarResizerOcclusionResolver { _ in 10 }

        #expect(
            !resolver.consumesPointerMonitorEvent(ofType: eventType, isBandActive: true, isDragging: false)
        )
        #expect(
            !resolver.consumesPointerMonitorEvent(ofType: eventType, isBandActive: false, isDragging: true)
        )
    }

    @Test(arguments: [NSEvent.EventType.cursorUpdate, .mouseMoved, .mouseEntered, .mouseExited])
    func pointerEventsAreConsumedOnlyWhileBandIsActiveOrDragging(eventType: NSEvent.EventType) {
        let resolver = SidebarResizerOcclusionResolver { _ in 10 }

        #expect(
            resolver.consumesPointerMonitorEvent(ofType: eventType, isBandActive: true, isDragging: false)
        )
        #expect(
            resolver.consumesPointerMonitorEvent(ofType: eventType, isBandActive: false, isDragging: true)
        )
        #expect(
            !resolver.consumesPointerMonitorEvent(ofType: eventType, isBandActive: false, isDragging: false)
        )
    }

    @Test(arguments: [NSEvent.EventType.leftMouseDown, .leftMouseUp, .leftMouseDragged])
    func clicksAndDragsAlwaysPass(eventType: NSEvent.EventType) {
        let resolver = SidebarResizerOcclusionResolver { _ in 10 }

        #expect(
            !resolver.consumesPointerMonitorEvent(ofType: eventType, isBandActive: true, isDragging: true)
        )
    }
}
