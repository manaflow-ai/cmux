import UIKit

/// A thin vertical bar in the machine's color (flat list rows).
@MainActor
final class MachineBar: UIView {
    init(color: UIColor) {
        super.init(frame: CGRect(x: 0, y: 0, width: 3, height: 28))
        backgroundColor = color
        layer.cornerRadius = 1.5
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: CGSize { CGSize(width: 3, height: 28) }
}
