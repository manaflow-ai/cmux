import UIKit

extension UIViewController {
    /// A one-button alert from the topmost presented controller.
    func presentNotice(title: String, message: String) {
        var top: UIViewController = self
        while let next = top.presentedViewController { top = next }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: WorkspacesText.ok, style: .default))
        top.present(alert, animated: true)
    }
}
