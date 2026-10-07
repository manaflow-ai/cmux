import UIKit

extension UIViewController {
    /// The controller currently presented on top of this one (or itself).
    var topmostPresented: UIViewController {
        var top = self
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }
}
