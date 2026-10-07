import CmuxBrowserStream
import CmuxiOSRemoteDesktopCore
import CmuxRemoteDesktop
import CoreGraphics
import Testing

@Suite("Remote desktop viewport")
struct RemoteDesktopViewportTests {
    static let target = DesktopTargetInfo(kind: .display, width: 3024, height: 1964, scale: 2, name: "Built-in")
    // An iPhone in landscape: 852 x 393 points.
    static let screen = CGSize(width: 852, height: 393)

    @Test func zoomOneShowsTheWholeTarget() {
        let viewport = RemoteDesktopViewport(bounds: Self.screen, target: Self.target)
        #expect(abs(viewport.fitScale - 393.0 / 1964) < 1e-9)
        #expect(viewport.visibleRect == CGRect(x: 0, y: 0, width: 3024, height: 1964))
        let request = viewport.viewRequest(screenScale: 3)
        #expect(request.rect == DesktopRect(width: 3024, height: 1964))
        #expect(request.pixelHeight == 1179)
    }

    @Test func pointsMapBothWays() {
        var viewport = RemoteDesktopViewport(bounds: Self.screen, target: Self.target)
        viewport.pinch(by: 3, around: CGPoint(x: 426, y: 196))
        let target = viewport.targetPoint(forScreen: CGPoint(x: 100, y: 50))
        let back = viewport.screenPoint(forTarget: target)
        #expect(abs(back.x - 100) < 1e-6)
        #expect(abs(back.y - 50) < 1e-6)
    }

    @Test func pinchKeepsTheFocusStillAndClampsZoom() {
        var viewport = RemoteDesktopViewport(bounds: Self.screen, target: Self.target)
        let focus = CGPoint(x: 600, y: 100)
        let before = viewport.targetPoint(forScreen: focus)
        viewport.pinch(by: 2, around: focus)
        let after = viewport.targetPoint(forScreen: focus)
        #expect(abs(before.x - after.x) < 1)
        #expect(abs(before.y - after.y) < 1)
        viewport.pinch(by: 1000, around: focus)
        #expect(viewport.zoom == viewport.maxZoom)
        #expect(abs(viewport.scale - RemoteDesktopViewport.maxPointsPerPixel) < 1e-9)
        viewport.pinch(by: 0.0001, around: focus)
        #expect(viewport.zoom == 1)
    }

    @Test func aZoomedViewRequestsTheVisibleRectAtScreenPixels() {
        var viewport = RemoteDesktopViewport(bounds: Self.screen, target: Self.target)
        viewport.pinch(by: 4, around: CGPoint(x: 0, y: 0))
        let request = viewport.viewRequest(screenScale: 3)
        #expect(request.rect.x == 0)
        #expect(request.rect.y == 0)
        #expect(request.rect.width < 3024)
        #expect(abs(Double(request.pixelHeight) - 393 * 3) <= 3)
        // The frame encoded for that view fills the screen.
        let view = DesktopView(seq: 1, rect: request.rect, pixelWidth: request.pixelWidth, pixelHeight: request.pixelHeight)
        let rect = viewport.screenRect(for: view)
        #expect(abs(rect.minY) < 1)
        #expect(abs(rect.height - 393) < 2)
    }

    @Test func theLensFollowsTheCursorAtTheEdgeAndStaysInside() {
        var viewport = RemoteDesktopViewport(bounds: Self.screen, target: Self.target)
        viewport.pinch(by: 4, around: CGPoint(x: 0, y: 0))
        let before = viewport.visibleRect
        viewport.follow(CGPoint(x: before.maxX + 50, y: before.midY))
        #expect(viewport.visibleRect.minX > before.minX)
        viewport.follow(CGPoint(x: 99_999, y: 99_999))
        #expect(viewport.visibleRect.maxX <= 3024 + 1e-6)
        #expect(viewport.visibleRect.maxY <= 1964 + 1e-6)
        viewport.pan(by: CGPoint(x: 99_999, y: 99_999))
        #expect(viewport.visibleRect.minX >= -1e-6)
    }
}

@Suite("Trackpad, gestures and modifiers")
struct RemoteDesktopInputTests {
    @Test func slowMovesArePreciseAndFastOnesAccelerate() {
        #expect(TrackpadPointer.acceleration(speed: 100) == 1)
        #expect(TrackpadPointer.acceleration(speed: 5000) == 3)
        var pointer = TrackpadPointer(width: 3024, height: 1964)
        let event = pointer.move(by: CGPoint(x: 10, y: 0), speed: 50, scale: 0.5)
        #expect(event == .pointer(x: 1532, y: 982))
        _ = pointer.move(by: CGPoint(x: -99_999, y: -99_999), speed: 50, scale: 0.5)
        #expect(pointer.position == .zero)
        #expect(pointer.moveTo(CGPoint(x: 99_999, y: 5)) == .pointer(x: 3023, y: 5))
    }

    @Test func gesturesUseXButtonsAndNaturalScroll() {
        let mapper = RemoteDesktopGestureMapper()
        #expect(mapper.click() == [.button(button: 1, down: true), .button(button: 1, down: false)])
        #expect(mapper.click(button: RemoteDesktopGestureMapper.secondary).first == .button(button: 3, down: true))
        #expect(mapper.click(count: 2).count == 4)
        // Fingers move up 10 points at 0.5 points per pixel: scroll down 20 pixels.
        #expect(mapper.scroll(byScreen: CGPoint(x: 0, y: -10), scale: 0.5) == .scroll(dx: 0, dy: 2000, precise: true))
        #expect(mapper.scroll(byScreen: .zero, scale: 1) == nil)
        #expect(mapper.tap(at: .pointer(x: 1, y: 2)) == [.pointer(x: 1, y: 2), .button(button: 1, down: true),
                                                         .button(button: 1, down: false)])
    }

    @Test func aLatchedModifierWrapsTheNextKeyOnlyAndALockStays() {
        var latch = ModifierLatch()
        latch.toggle(.control)
        let chord = latch.type("c")
        let control = HidUsage.leftControl.rawValue
        let c = HidUsage.key(for: "c")!.rawValue
        #expect(chord == [.key(usage: control, down: true), .key(usage: c, down: true), .key(usage: c, down: false),
                          .key(usage: control, down: false)])
        #expect(latch.type("x") == [.text("x")])
        latch.toggle(.command)
        latch.toggle(.command)
        #expect(latch.locked == [.command])
        _ = latch.press(.tab)
        #expect(latch.active == [.command])
        latch.toggle(.command)
        #expect(latch.active.isEmpty)
        #expect(latch.type("\n") == [.key(usage: HidUsage.returnKey.rawValue, down: true),
                                     .key(usage: HidUsage.returnKey.rawValue, down: false)])
    }

    @Test func macCodesBecomeUserFacingFailures() {
        #expect(RemoteDesktopFailure(code: "rd.permission_denied") == .screenRecordingOff)
        #expect(RemoteDesktopFailure(code: "stopped_by_host") == .stoppedOnMac)
        #expect(RemoteDesktopFailure(.linkLost) == .unreachable)
        #expect(RemoteDesktopFailure(.refused(code: "rd.vnc_not_allowed", message: "")) == .vncNotAllowed)
        #expect(RemoteDesktopFailure(code: "weird") == .other(code: "weird"))
    }
}
