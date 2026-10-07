import AppKit
import Testing
@testable import cmux_DEV

@Suite
@MainActor
struct SidebarFocusBoundaryLifecycleTests {
    @Test
    func visibilityMutationNotifiesBeforePublishedStateChanges() {
        let state = SidebarState(isVisible: true)
        var requestedValues: [Bool] = []
        var valuesDuringNotification: [Bool] = []
        state.installVisibilityWillChangeHandler(ownerId: UUID()) { requestedValue in
            requestedValues.append(requestedValue)
            valuesDuringNotification.append(state.isVisible)
        }

        state.setVisible(false)
        state.setVisible(false)

        #expect(requestedValues == [false])
        #expect(valuesDuringNotification == [true])
        #expect(!state.isVisible)
    }

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

@Suite
@MainActor
struct SidebarStateAnimatedToggleTests {
    /// An animated hide keeps `isVisible` true until its sweep lands. The
    /// request is hidden at once, and a second toggle mid-sweep asks to show
    /// again instead of repeating the hide.
    @Test
    func toggleDuringAHideSweepReversesIt() {
        let state = SidebarState(isVisible: true)
        var requests: [Bool] = []
        state.animatedVisibilityOrchestrator = { targetVisible in
            requests.append(targetVisible)
            if !targetVisible { state.isHidePending = true }
            return true
        }

        state.toggle()
        #expect(state.isVisible)
        #expect(!state.requestedVisibility)

        state.toggle()
        #expect(requests == [false, true])

        state.setVisible(true)
        #expect(state.requestedVisibility)
    }
}
