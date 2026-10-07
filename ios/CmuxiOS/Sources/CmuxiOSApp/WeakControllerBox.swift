import UIKit

/// Lets a SwiftUI sheet dismiss its own hosting controller.
@MainActor
final class WeakControllerBox {
    weak var controller: UIViewController?
}
