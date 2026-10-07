import UIKit

/// Agent, model, effort and templates in one horizontal scroller (parity:
/// `TaskComposerEffortPickerUITests`, the effort pill shares the scroller with
/// provider and model). Buttons are reused by id so an open menu survives a
/// catalog update.
@MainActor
final class ComposerPillsView: UIScrollView {
    private let stack = UIStackView()
    private var buttons: [String: UIButton] = [:]

    init() {
        super.init(frame: .zero)
        showsHorizontalScrollIndicator = false
        alwaysBounceHorizontal = true
        stack.axis = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: frameLayoutGuide.heightAnchor),
        ])
        accessibilityIdentifier = "composer.pills"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ pills: [ComposerPill]) {
        let wanted = Set(pills.map(\.id))
        for (id, button) in buttons where !wanted.contains(id) {
            button.removeFromSuperview()
            buttons[id] = nil
        }
        for (index, pill) in pills.enumerated() {
            let button = buttons[pill.id] ?? makeButton(pill.id)
            var configuration = button.configuration ?? .gray()
            configuration.title = pill.title
            configuration.image = UIImage(systemName: pill.symbol,
                                          withConfiguration: UIImage.SymbolConfiguration(textStyle: .footnote))
            button.configuration = configuration
            button.menu = pill.menu
            button.showsMenuAsPrimaryAction = pill.menu != nil
            button.isEnabled = pill.isEnabled && pill.menu != nil
            button.accessibilityLabel = pill.label
            button.accessibilityValue = pill.title
            if stack.arrangedSubviews.firstIndex(of: button) != index {
                stack.insertArrangedSubview(button, at: min(index, stack.arrangedSubviews.count))
            }
        }
    }

    private func makeButton(_ id: String) -> UIButton {
        var configuration = UIButton.Configuration.gray()
        configuration.cornerStyle = .capsule
        configuration.imagePadding = 6
        configuration.titleLineBreakMode = .byTruncatingTail
        configuration.indicator = .popup
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var next = attributes
            next.font = UIFont.preferredFont(forTextStyle: .subheadline)
            return next
        }
        let button = UIButton(configuration: configuration)
        button.accessibilityIdentifier = "composer.pill." + id
        button.tintColor = .label
        buttons[id] = button
        stack.addArrangedSubview(button)
        return button
    }
}
