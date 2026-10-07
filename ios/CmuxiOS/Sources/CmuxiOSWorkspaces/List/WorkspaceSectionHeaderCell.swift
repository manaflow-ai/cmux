import UIKit

/// A section header that a group section can collapse with a tap and that
/// offers the group's actions in a menu (HIG: Disclosure controls).
final class WorkspaceSectionHeaderCell: UICollectionViewListCell {
    /// Set for group sections; nil for machine and plain headers.
    var onToggle: (() -> Void)?
    private lazy var tap = UITapGestureRecognizer(target: self, action: #selector(tapped))

    override init(frame: CGRect) {
        super.init(frame: frame)
        addGestureRecognizer(tap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func prepareForReuse() {
        super.prepareForReuse()
        onToggle = nil
        accessories = []
        accessibilityCustomActions = nil
        accessibilityValue = nil
    }

    @objc private func tapped() { onToggle?() }

    override func accessibilityActivate() -> Bool {
        guard let onToggle else { return false }
        onToggle()
        return true
    }
}
