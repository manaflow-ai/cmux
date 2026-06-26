import AppKit
import CmuxTerminal
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct TerminalWindowPortalTransientRecoveryTests {
    private func realizeWindowLayout(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func drainMainQueue() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    @Test func externalGeometryTinyFrameSchedulesSelfRecoveryAfterAnchorSettles() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer {
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            window.orderOut(nil)
        }

        realizeWindowLayout(window)
        let contentView = try #require(window.contentView)
        let stableFrame = NSRect(x: 40, y: 60, width: 260, height: 180)
        let anchor = NSView(frame: stableFrame)
        contentView.addSubview(anchor)

        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hosted = surface.hostedView
        TerminalWindowPortalRegistry.bind(
            hostedView: hosted,
            to: anchor,
            visibleInUI: true,
            expectedSurfaceId: surface.id,
            expectedGeneration: surface.portalBindingGeneration()
        )
        TerminalWindowPortalRegistry.synchronizeForAnchor(anchor)
        drainMainQueue()

        #expect(!hosted.isHidden)
        #expect(hosted.frame.height > 100)

        anchor.frame = NSRect(x: stableFrame.minX, y: stableFrame.minY, width: stableFrame.width, height: 0)
        contentView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        TerminalWindowPortalRegistry.scheduleExternalGeometrySynchronize(for: window)
        DispatchQueue.main.async {
            anchor.frame = stableFrame
            contentView.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        drainMainQueue()

        #expect(
            !hosted.isHidden,
            "A one-turn tiny external geometry transient should self-recover without a later user event"
        )
        #expect(hosted.frame.height > 100)
    }
}
