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

    @Test(arguments: [false, true])
    func colorOnlyUpdatesInvalidateOnce(backgroundChanges: Bool) throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = try #require(window.contentView)
        let split = MutableColorSplitView(frame: root.bounds)
        split.wantsLayer = true
        split.layer?.backgroundColor = NSColor.white.cgColor
        split.color = NSColor.red.withAlphaComponent(backgroundChanges ? 0.5 : 1)
        split.addArrangedSubview(NSView())
        split.addArrangedSubview(NSView())
        root.addSubview(split)
        let overlay = SplitDividerOverlayView(frame: root.bounds)
        root.addSubview(overlay)

        // Seed the colors through the real draw traversal, even with no occluding terminal.
        let image = NSImage(size: root.bounds.size)
        image.lockFocus()
        overlay.draw(overlay.bounds)
        image.unlockFocus()
        let before = overlay.repaintRequestCount
        if backgroundChanges {
            split.layer?.backgroundColor = NSColor.black.cgColor
        } else {
            split.color = .blue
        }
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        #expect(overlay.repaintRequestCount == before + 1)
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        #expect(overlay.repaintRequestCount == before + 1)
    }

    @Test
    func dynamicDividerColorUsesTheWindowsAppearanceOutsideDrawing() throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        defer { window.close() }
        let root = try #require(window.contentView)
        let split = MutableColorSplitView(frame: root.bounds)
        split.color = .separatorColor
        split.addArrangedSubview(NSView())
        split.addArrangedSubview(NSView())
        root.addSubview(split)
        let overlay = SplitDividerOverlayView(frame: root.bounds)
        root.addSubview(overlay)
        let image = NSImage(size: root.bounds.size)
        image.lockFocus()
        overlay.effectiveAppearance.performAsCurrentDrawingAppearance {
            overlay.draw(overlay.bounds)
        }
        image.unlockFocus()
        let before = overlay.repaintRequestCount
        try #require(NSAppearance(named: .aqua)).performAsCurrentDrawingAppearance {
            NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        }
        #expect(overlay.repaintRequestCount == before)
    }
}

@MainActor
private final class MutableColorSplitView: NSSplitView {
    var color: NSColor = .red
    override var dividerColor: NSColor { color }
}
