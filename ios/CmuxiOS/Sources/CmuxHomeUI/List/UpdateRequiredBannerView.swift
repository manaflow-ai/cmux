import CmuxiOSDesign
import UIKit

/// The card shown (in Home's banner header) while the team refuses this app version. It names
/// the team's minimum version and says what stops working until the user
/// updates (notifications and replies need the install token the owner
/// refuses), so the refusal never reads as a generic error.
@MainActor
final class UpdateRequiredBannerView: UIView {
    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        let card = UIView()
        card.backgroundColor = HomePalette.pinnedBackground
        card.layer.cornerRadius = 12
        card.layer.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false

        let icon = UIImageView(image: UIImage(systemName: "arrow.down.app"))
        icon.tintColor = HomePalette.accent
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .headline)
        icon.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = HomePalette.primaryText
        titleLabel.numberOfLines = 0
        titleLabel.text = HomeText.updateRequiredTitle

        bodyLabel.font = .preferredFont(forTextStyle: .subheadline)
        bodyLabel.adjustsFontForContentSizeCategory = true
        bodyLabel.textColor = HomePalette.secondaryText
        bodyLabel.numberOfLines = 0

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
        accessibilityTraits = .staticText
        configure(HomeUpdateRequired(minimumVersion: nil))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ requirement: HomeUpdateRequired) {
        bodyLabel.text = HomeText.updateRequiredBody(minimumVersion: requirement.minimumVersion)
        accessibilityLabel = HomeText.updateRequiredTitle + ". " + (bodyLabel.text ?? "")
    }
}
