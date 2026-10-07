public import SwiftUI

/// SwiftUI wrapper of the camera QR scanner. `onLink` fires once with the
/// first cmux pairing link; `onUnavailable` when the device has no usable camera.
public struct QRScannerView: UIViewControllerRepresentable {
    private let onLink: (URL) -> Void
    private let onUnavailable: () -> Void

    /// Shown when the device has no usable camera.
    public static var unavailableMessage: String { PairingScannerText.unavailable }

    public init(onLink: @escaping (URL) -> Void, onUnavailable: @escaping () -> Void = {}) {
        self.onLink = onLink
        self.onUnavailable = onUnavailable
    }

    public func makeUIViewController(context: Context) -> some UIViewController {
        let controller = QRScannerViewController()
        controller.onLink = onLink
        controller.onUnavailable = onUnavailable
        return controller
    }

    public func updateUIViewController(_ controller: UIViewControllerType, context: Context) {
        guard let scanner = controller as? QRScannerViewController else { return }
        scanner.onLink = onLink
        scanner.onUnavailable = onUnavailable
    }
}
