#if os(iOS)
public import UIKit

/// Takes the shell's tab bar and its bottom accessory (the `TabView`'s
/// `UITabBarController`) out of the accessibility tree while a keyboard
/// covers them, and puts them back after. Layout and visibility are
/// untouched. One per screen that raises a keyboard over the tab bar.
@MainActor
public final class CNTabBarCover {
    private weak var covered: UITabBarController?

    public init() {}

    /// `true` while `view`'s keyboard covers the enclosing tab bar.
    public func setCovered(_ isCovered: Bool, from view: UIView) {
        let controller = isCovered ? Self.tabBarController(of: view) : covered
        guard let controller else { return }
        Self.apply(isCovered, to: controller)
        covered = isCovered ? controller : nil
    }

    /// Puts back whatever this cover hid (the screen left).
    public func release() {
        guard let controller = covered else { return }
        Self.apply(false, to: controller)
        covered = nil
    }

    /// The tab bar, and the accessory's content with the two views that hold
    /// it (SwiftUI may rebuild the content's own subviews while it is
    /// covered, for example when the connection's latency label updates).
    private static func apply(_ hidden: Bool, to controller: UITabBarController) {
        controller.tabBar.accessibilityElementsHidden = hidden
        var view: UIView? = controller.bottomAccessory?.contentView
        for _ in 0..<3 {
            guard let v = view, v !== controller.view else { break }
            v.accessibilityElementsHidden = hidden
            view = v.superview
        }
    }

    private static func tabBarController(of view: UIView) -> UITabBarController? {
        var responder: UIResponder? = view
        while let r = responder {
            if let controller = r as? UITabBarController { return controller }
            responder = r.next
        }
        return nil
    }
}
#endif
