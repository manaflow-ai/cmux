import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Hosted inspector resize geometry")
struct HostedInspectorResizeGeometryTests {
    @Test func resolvesBottomDockWithTolerantEpsilon() {
        let page = NSRect(x: 0, y: 100, width: 300, height: 200)
        let inspector = NSRect(x: 0, y: 0, width: 300, height: 102)

        #expect(HostedInspectorDockSide.resolve(pageFrame: page, inspectorFrame: inspector) == .bottom)
    }

    @Test func resolvesSideDockWithSmallJitter() {
        let page = NSRect(x: 0, y: 0, width: 180, height: 220)
        let inspector = NSRect(x: 182, y: 0, width: 118, height: 220)

        #expect(HostedInspectorDockSide.resolve(pageFrame: page, inspectorFrame: inspector) == .trailing)
    }

    @Test func dividerHitRectsFollowDividerOrientation() {
        let bounds = NSRect(x: 0, y: 0, width: 300, height: 220)
        let page = NSRect(x: 0, y: 90, width: 300, height: 130)
        let bottomInspector = NSRect(x: 0, y: 0, width: 300, height: 90)
        let sideInspector = NSRect(x: 180, y: 0, width: 120, height: 220)

        let bottom = HostedInspectorDockSide.bottom.dividerHitRect(
            in: bounds,
            pageFrame: page,
            inspectorFrame: bottomInspector,
            expansion: 6
        )
        let trailing = HostedInspectorDockSide.trailing.dividerHitRect(
            in: bounds,
            pageFrame: NSRect(x: 0, y: 0, width: 180, height: 220),
            inspectorFrame: sideInspector,
            expansion: 6
        )

        #expect(bottom.width == 300)
        #expect(bottom.height == 12)
        #expect(trailing.width == 12)
        #expect(trailing.height == 220)
    }

    @Test func proportionalClampNeverCreatesEmptyRangeForTinyContainers() {
        let policy = HostedInspectorMinimumSizePolicy(minimumInspectorExtent: 120, minimumPageExtent: 120)

        #expect(policy.clampedInspectorExtent(0, containerExtent: 80) == 40)
        #expect(policy.clampedInspectorExtent(200, containerExtent: 80) == 40)
        #expect(policy.clampedInspectorExtent(40, containerExtent: 320) == 120)
        #expect(policy.clampedInspectorExtent(280, containerExtent: 320) == 200)
    }

    @Test func resizedBottomFramesTileContainer() {
        let bounds = NSRect(x: 0, y: 0, width: 300, height: 220)
        let frames = HostedInspectorDockSide.bottom.resizedFrames(
            preferredExtent: 110,
            in: bounds,
            pageFrame: NSRect(x: 0, y: 90, width: 300, height: 130),
            inspectorFrame: NSRect(x: 0, y: 0, width: 300, height: 90),
            policy: HostedInspectorMinimumSizePolicy(dockSide: .bottom)
        )

        #expect(frames.inspectorFrame == NSRect(x: 0, y: 0, width: 300, height: 110))
        #expect(frames.pageFrame == NSRect(x: 0, y: 110, width: 300, height: 110))
    }

    @Test func resizedSideFramesTileContainer() {
        let bounds = NSRect(x: 0, y: 0, width: 300, height: 220)
        let frames = HostedInspectorDockSide.trailing.resizedFrames(
            preferredExtent: 130,
            in: bounds,
            pageFrame: NSRect(x: 0, y: 0, width: 180, height: 220),
            inspectorFrame: NSRect(x: 180, y: 0, width: 120, height: 220),
            policy: HostedInspectorMinimumSizePolicy(dockSide: .trailing)
        )

        #expect(frames.pageFrame == NSRect(x: 0, y: 0, width: 170, height: 220))
        #expect(frames.inspectorFrame == NSRect(x: 170, y: 0, width: 130, height: 220))
    }

    @Test func attachedSizeSyncJavaScriptUsesGuardedIntegerHeightAndWidth() {
        let height = HostedInspectorAttachedSizeSync.javaScript(dockSide: .bottom, extent: 120.6)
        let width = HostedInspectorAttachedSizeSync.javaScript(dockSide: .trailing, extent: 119.4)

        #expect(height.contains("typeof InspectorFrontendHost"))
        #expect(height.contains("setAttachedWindowHeight"))
        #expect(height.contains("121"))
        #expect(width.contains("setAttachedWindowWidth"))
        #expect(width.contains("119"))
    }
}
