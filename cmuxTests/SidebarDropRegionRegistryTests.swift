import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("SidebarDropRegionRegistry")
struct SidebarDropRegionRegistryTests {
    @Test func detectsPointInsideRegisteredProbe() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let probe = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 300))
        window.contentView?.addSubview(probe)
        SidebarDropRegionRegistry.register(probe)
        defer { SidebarDropRegionRegistry.unregister(probe) }

        let inside = probe.convert(NSPoint(x: 50, y: 150), to: nil)
        let outside = probe.convert(NSPoint(x: 300, y: 150), to: nil)
        #expect(SidebarDropRegionRegistry.containsWindowPoint(inside, in: window))
        #expect(!SidebarDropRegionRegistry.containsWindowPoint(outside, in: window))
    }

    @Test func unregisteredProbeIsNotDetected() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let probe = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 300))
        window.contentView?.addSubview(probe)
        let inside = probe.convert(NSPoint(x: 50, y: 150), to: nil)
        #expect(!SidebarDropRegionRegistry.containsWindowPoint(inside, in: window))
    }
}
