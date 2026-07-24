import AppKit
import Testing
@testable import cmux_DEV

@Suite
@MainActor
struct SidebarFocusBoundaryLifecycleTests {
    @Test
    func windowlessStaleHostCallbackDoesNotEraseMountedReplacement() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 180))
        let window = NSWindow(
            contentRect: root.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = root
        defer { window.close() }

        let reference = SidebarFocusBoundaryReference()
        let firstHost = makeHost(reference: reference, frame: root.bounds)
        root.addSubview(firstHost)
        let replacementHost = makeHost(reference: reference, frame: root.bounds)
        root.addSubview(replacementHost)

        firstHost.removeFromSuperview()
        SidebarPointerEventHost.dismantleNSView(firstHost, coordinator: ())

        #expect(
            reference.contains(replacementHost, in: window),
            "A windowless callback from the stale host must not replace the mounted boundary."
        )
    }

    private func makeHost(
        reference: SidebarFocusBoundaryReference,
        frame: NSRect
    ) -> SidebarPointerEventHostView {
        let host = SidebarPointerEventHostView(frame: frame)
        host.onResolve = { reference.attach($0) }
        host.onDismantle = { reference.detach($0) }
        return host
    }
}
