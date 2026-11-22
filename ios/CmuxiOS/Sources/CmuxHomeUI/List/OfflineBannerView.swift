import CmuxiOSDesign
import UIKit

/// The card shown (in Home's banner header) while the Home owners are
/// unreachable. It says what still works (reading) and what does not
/// (sending, inviting, new Chiefs), because those controls are disabled.
@MainActor
final class OfflineBannerView: UIView {
    private let icon = UIImageView(image: UIImage(systemName: "wifi.slash"))
    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        let card = UIView()
        card.backgroundColor = HomePalette.pinnedBackground
        card.layer.cornerRadius = 12
        card.layer.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false

        icon.tintColor = HomePalette.secondaryText
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .headline)
        icon.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = HomePalette.primaryText
        titleLabel.numberOfLines = 0
        titleLabel.text = HomeText.offlineTitle

        bodyLabel.font = .preferredFont(forTextStyle: .subheadline)
        bodyLabel.adjustsFontForContentSizeCategory = true
        bodyLabel.textColor = HomePalette.secondaryText
        bodyLabel.numberOfLines = 0
        bodyLabel.text = HomeText.offlineBody

        let text = UIStackView(arrangedSubviews: [titleLabel, bodyLabel])
        text.axis = .vertical
        text.spacing = 2
        let row = UIStackView(arrangedSubviews: [icon, text])
        row.spacing = 12
        row.alignment = .firstBaseline
        row.translatesAutoresizingMaskIntoConstraints = false

        addSubview(card)
        card.addSubview(row)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HomeMetrics.sideInset),
            card.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HomeMetrics.sideInset),
            card.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            card.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14),
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
        ])

        isAccessibilityElement = true
        accessibilityLabel = HomeText.offlineTitle + ". " + HomeText.offlineBody
        accessibilityTraits = .staticText
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
