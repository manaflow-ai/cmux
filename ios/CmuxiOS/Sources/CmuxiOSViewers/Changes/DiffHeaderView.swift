import CmuxMobileWire
import UIKit

/// The file a diff shows: path, status, counts, rename source, or a notice
/// (truncated patch) when used as the footer.
@MainActor
final class DiffHeaderView: UICollectionReusableView {
    static let reuse = "DiffHeaderView"
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(file: GitChangedFile) {
        let text = NSMutableAttributedString(string: file.path + "\n", attributes: [
            .font: UIFont.preferredFont(forTextStyle: .subheadline), .foregroundColor: UIColor.label,
        ])
        var details = [ViewersText.status(file.status), ViewersText.additionsDeletions(file.additions, file.deletions)]
        if let previous = file.previousPath { details.append(ViewersText.renamedFrom(previous)) }
        text.append(NSAttributedString(string: details.joined(separator: " · "), attributes: [
            .font: UIFont.preferredFont(forTextStyle: .footnote), .foregroundColor: UIColor.secondaryLabel,
        ]))
        label.attributedText = text
        accessibilityTraits = .header
    }

    func configure(notice: String) {
        label.attributedText = NSAttributedString(string: notice, attributes: [
            .font: UIFont.preferredFont(forTextStyle: .footnote), .foregroundColor: UIColor.secondaryLabel,
        ])
        accessibilityTraits = .staticText
    }
}
