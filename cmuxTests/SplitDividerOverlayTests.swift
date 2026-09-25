import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct SplitDividerOverlayTests {
    @Test
    func placementRepairsAllIntrudersAndThenStaysIdle() throws {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let divider = SplitDividerOverlayView(frame: host.bounds)
        let paneSwap = NSView(frame: host.bounds)
        host.addSubview(divider)
        host.addSubview(paneSwap)
        let intruders = [NSView(), NSView(), NSView()]
        for view in intruders { host.addSubview(view) }

        divider.ensurePlacement(in: host, below: paneSwap)
        host.addSubview(paneSwap, positioned: .above, relativeTo: nil)
        let dividerIndex = try #require(host.subviews.firstIndex(of: divider))
        for view in intruders {
            #expect(try #require(host.subviews.firstIndex(of: view)) < dividerIndex)
        }
        let before = divider.repaintRequestCount
        for _ in 0..<3 { divider.ensurePlacement(in: host, below: paneSwap) }
        #expect(divider.repaintRequestCount == before)
        #expect(host.subviews.last === paneSwap)
    }

    @Test
    func appearanceInvalidatesWithoutGeometryChange() {
        let divider = SplitDividerOverlayView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        divider.refreshIfGeometryChanged()
        let before = divider.repaintRequestCount
        divider.viewDidChangeEffectiveAppearance()
        #expect(divider.repaintRequestCount == before + 1)
        divider.refreshIfGeometryChanged()
        #expect(divider.repaintRequestCount == before + 1)
    }

    @Test
    func boundsChangesInvalidateButRepeatedSnapshotsDoNot() {
        let divider = SplitDividerOverlayView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        divider.refreshIfGeometryChanged()
        let before = divider.repaintRequestCount
        divider.refreshIfGeometryChanged()
        #expect(divider.repaintRequestCount == before)
        divider.setBoundsSize(NSSize(width: 300, height: 200))
        divider.refreshIfGeometryChanged()
        #expect(divider.repaintRequestCount == before + 1)
        divider.refreshIfGeometryChanged()
        #expect(divider.repaintRequestCount == before + 1)
    }
}
