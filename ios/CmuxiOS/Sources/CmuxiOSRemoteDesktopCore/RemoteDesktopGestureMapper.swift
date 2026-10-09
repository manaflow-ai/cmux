public import CmuxBrowserStream
public import CoreGraphics

/// Phone gestures to rd input (c3-rd.md 3). Buttons use rd's X numbering:
/// 1 primary, 2 middle, 3 secondary. Scroll is precise, in hundredths of a
/// point, positive down and right, natural direction (content follows the
/// fingers).
public struct RemoteDesktopGestureMapper: Sendable {
    public static let primary: UInt8 = 1
    public static let secondary: UInt8 = 3

    public init() {}

    public func click(button: UInt8 = primary, count: Int = 1) -> [RdInputEvent] {
        Array(repeating: [.button(button: button, down: true), .button(button: button, down: false)], count: max(1, count))
            .flatMap { $0 }
    }

    /// Direct mode tap: the cursor jumps to the finger, then clicks.
    public func tap(at pointer: RdInputEvent, button: UInt8 = primary) -> [RdInputEvent] {
        [pointer] + click(button: button)
    }

    public func press(_ button: UInt8 = primary) -> RdInputEvent { .button(button: button, down: true) }

    public func release(_ button: UInt8 = primary) -> RdInputEvent { .button(button: button, down: false) }

    /// A two-finger pan step in screen points (translation since the last step).
    public func scroll(byScreen delta: CGPoint, scale: Double) -> RdInputEvent? {
        // Content follows the fingers: dragging up scrolls down. Points on
        // the phone become target points through the lens scale.
        let factor = 100 / max(scale, 0.0001)
        let dx = Int32(clamping: Int((-delta.x * factor).rounded()))
        let dy = Int32(clamping: Int((-delta.y * factor).rounded()))
        guard dx != 0 || dy != 0 else { return nil }
        return .scroll(dx: dx, dy: dy, precise: true)
    }
}
