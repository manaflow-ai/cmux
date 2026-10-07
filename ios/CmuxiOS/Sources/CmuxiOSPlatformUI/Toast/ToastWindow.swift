public import CmuxiOSPlatform
public import UIKit

/// A pass-through window above the app's window (and its sheets) that hosts
/// the toast overlay. It never becomes key, so focus and the keyboard stay
/// with the app.
@MainActor
public final class ToastWindow: UIWindow {
    public init(scene: UIWindowScene, center: ToastCenter) {
        super.init(windowScene: scene)
        windowLevel = .normal + 10
        backgroundColor = .clear
        let controller = UIViewController()
        controller.view = ToastOverlayView(toasts: center)
        rootViewController = controller
        isHidden = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override public func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        // UIWindow answers with itself when no subview claims the point, so
        // both the window and its root view mean "nothing here": pass through.
        let hit = super.hitTest(point, with: event)
        return hit === self || hit === rootViewController?.view ? nil : hit
    }

    override public var canBecomeKey: Bool { false }
}
