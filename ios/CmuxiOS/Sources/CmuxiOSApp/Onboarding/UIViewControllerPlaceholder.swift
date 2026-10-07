import UIKit

/// An empty controller for a host whose owner is gone (never shown in practice).
@MainActor
enum UIViewControllerPlaceholder {
    static func make() -> UIViewController { UIViewController() }
}
