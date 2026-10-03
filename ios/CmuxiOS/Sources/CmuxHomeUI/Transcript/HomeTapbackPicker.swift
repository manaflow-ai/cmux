import CmuxHomeCore
import CmuxiOSDesign
import UIKit

/// The tapback bar: one button per standard tapback over glass (an opaque
/// grouped fill with Reduce Transparency). Tapbacks I already gave are shown
/// selected. VoiceOver keeps focus inside it; the escape gesture closes it.
@MainActor
final class HomeTapbackPicker: UIView {
    let target: HomeTapbackTarget
    var onChoose: (Reaction.Tapback) -> Void = { _ in }
    var onDismiss: () -> Void = {}

    static let buttonSize: CGFloat = 44
    static let padding: CGFloat = 4

    private let background = UIVisualEffectView()
    private let stack = UIStackView()
    private(set) var buttons: [UIButton] = []

    init(target: HomeTapbackTarget) {
        self.target = target
        super.init(frame: .zero)
        background.clipsToBounds = true
        addSubview(background)
        stack.axis = .horizontal
        stack.spacing = 0
        addSubview(stack)
        for tapback in Reaction.Tapback.allCases {
            let button = Self.button(tapback, selected: target.chosen.contains(tapback))
            button.addAction(UIAction { [weak self] _ in self?.onChoose(tapback) }, for: .primaryActionTriggered)
            stack.addArrangedSubview(button)
            buttons.append(button)
        }
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.12
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: 4)
        accessibilityViewIsModal = true
        accessibilityLabel = HomeText.tapbackPickerA11y
        accessibilityContainerType = .semanticGroup
        applyBackground()
        NotificationCenter.default.addObserver(self, selector: #selector(transparencyChanged),
                                               name: UIAccessibility.reduceTransparencyStatusDidChangeNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static func button(_ tapback: Reaction.Tapback, selected: Bool) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.attributedTitle = AttributedString(tapback.glyph, attributes: AttributeContainer([
            .font: UIFont.systemFont(ofSize: 24),
        ]))
        configuration.contentInsets = .zero
        configuration.cornerStyle = .capsule
        // Ink and grays only: the chosen tapback sits on a neutral fill.
        configuration.background.backgroundColor = selected ? UIColor.tertiarySystemFill : .clear
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = tapback.accessibilityName
        button.accessibilityTraits = selected ? [.button, .selected] : .button
        button.showsLargeContentViewer = true
        button.largeContentTitle = tapback.accessibilityName
        button.addInteraction(UILargeContentViewerInteraction())
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: buttonSize),
            button.heightAnchor.constraint(equalToConstant: buttonSize),
        ])
        return button
    }

    override var intrinsicContentSize: CGSize {
        let count = CGFloat(Reaction.Tapback.allCases.count)
        return CGSize(width: count * Self.buttonSize + 2 * Self.padding, height: Self.buttonSize + 2 * Self.padding)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        background.frame = bounds
        background.layer.cornerRadius = bounds.height / 2
        stack.frame = bounds.insetBy(dx: Self.padding, dy: Self.padding)
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: bounds.height / 2).cgPath
    }

    override func accessibilityPerformEscape() -> Bool {
        onDismiss()
        return true
    }

    @objc private func transparencyChanged() {
        applyBackground()
    }

    private func applyBackground() {
        if UIAccessibility.isReduceTransparencyEnabled {
            background.effect = nil
            background.backgroundColor = HomePalette.groupedBackground
        } else if #available(iOS 26.0, *) {
            background.effect = UIGlassEffect()
            background.backgroundColor = nil
        } else {
            background.effect = UIBlurEffect(style: .systemChromeMaterial)
            background.backgroundColor = nil
        }
    }
}
