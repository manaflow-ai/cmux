import CmuxHomeCore
import CmuxiOSDesign
import UIKit

/// The card shown (in Home's banner header, between update required and
/// offline) while the account's Hosted Chief brain is off, so the Chief is
/// never a silent dead one: it says the Chief does not answer and offers the
/// one action that fixes it. Same card as the other banners (pinned
/// background, 12 pt continuous corners, side inset), plus a Turn On button
/// that becomes Try Again after a failed turn on and shows progress while
/// the answer is out. When the server refuses because the account may not
/// run the Chief's model, the card says so and offers no button (a retry
/// would be refused the same way).
@MainActor
final class ChiefOffBannerView: UIView {
    var onTurnOn: (() -> Void)?

    private let icon = UIImageView(image: UIImage(systemName: "sparkles"))
    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()
    private let text = UIStackView()
    private let button = UIButton(configuration: .gray())

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
        icon.isAccessibilityElement = false

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = HomePalette.primaryText
        titleLabel.numberOfLines = 0
        titleLabel.text = HomeText.chiefOffTitle

        bodyLabel.font = .preferredFont(forTextStyle: .subheadline)
        bodyLabel.adjustsFontForContentSizeCategory = true
        bodyLabel.textColor = HomePalette.secondaryText
        bodyLabel.numberOfLines = 0

        var configuration = UIButton.Configuration.gray()
        configuration.buttonSize = .small
        configuration.cornerStyle = .capsule
        configuration.baseForegroundColor = HomePalette.accent
        button.configuration = configuration
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.addAction(UIAction { [weak self] _ in self?.onTurnOn?() }, for: .primaryActionTriggered)
        button.accessibilityIdentifier = "home.chiefOff.turnOn"

        let words = UIStackView(arrangedSubviews: [titleLabel, bodyLabel])
        words.axis = .vertical
        words.spacing = 2
        words.isAccessibilityElement = true
        words.accessibilityTraits = .staticText

        text.addArrangedSubview(words)
        text.addArrangedSubview(button)
        text.axis = .vertical
        text.alignment = .leading
        text.spacing = 10

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
        configure(.off)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(_ banner: HomeChiefBanner) {
        bodyLabel.text = switch banner {
        case .off, .turningOn: HomeText.chiefOffBody
        case .failed: HomeText.chiefOffFailedBody
        case .unavailable: HomeText.chiefOffUnavailableBody
        }
        button.isHidden = banner == .unavailable
        text.arrangedSubviews.first?.accessibilityLabel = HomeText.chiefOffTitle + ". " + (bodyLabel.text ?? "")
        var configuration = button.configuration ?? .gray()
        configuration.title = banner == .failed ? HomeText.retry : HomeText.chiefTurnOn
        configuration.showsActivityIndicator = banner == .turningOn
        button.configuration = configuration
        button.isEnabled = banner != .turningOn
    }
}
