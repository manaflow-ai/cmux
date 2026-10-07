import CmuxiOSFeedModel
import UIKit

/// The filter control, the connection banner and the last outcome line.
@MainActor
final class FeedHeaderView: UIView {
    let filterControl: UISegmentedControl
    private let banner = UILabel()
    private let status = UILabel()
    private let stack = UIStackView()

    init(filters: [FeedFilter]) {
        filterControl = UISegmentedControl(items: filters.map(FeedText.filter))
        super.init(frame: .zero)
        filterControl.accessibilityIdentifier = "feed.filter"
        for label in [banner, status] {
            label.font = UIFont.preferredFont(forTextStyle: .footnote)
            label.adjustsFontForContentSizeCategory = true
            label.textColor = .secondaryLabel
            label.numberOfLines = 0
            label.isHidden = true
        }
        banner.accessibilityIdentifier = "feed.banner"
        status.accessibilityIdentifier = "feed.status"
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        [filterControl, banner, status].forEach(stack.addArrangedSubview)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setBanner(_ text: String?) {
        banner.text = text
        banner.isHidden = text == nil
    }

    func setStatus(_ text: String?) {
        status.text = text
        status.isHidden = text == nil
    }
}
