import UIKit

/// A row of completion chips under the prompt (templates for `/`, files for
/// `@`). Hidden when empty.
@MainActor
final class ComposerSuggestionBar: UIScrollView {
    struct Item: Hashable {
        var id: String
        var title: String
        var subtitle: String?
    }

    private let stack = UIStackView()
    var onPick: ((String) -> Void)?

    init() {
        super.init(frame: .zero)
        showsHorizontalScrollIndicator = false
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
        isHidden = true
        accessibilityIdentifier = "composer.suggestions"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ items: [Item]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        isHidden = items.isEmpty
        for item in items {
            var configuration = UIButton.Configuration.gray()
            configuration.cornerStyle = .capsule
            configuration.title = item.title
            configuration.subtitle = item.subtitle
            configuration.titleLineBreakMode = .byTruncatingTail
            let id = item.id
            let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in self?.onPick?(id) })
            button.accessibilityIdentifier = "composer.suggestion." + id
            stack.addArrangedSubview(button)
        }
    }
}
