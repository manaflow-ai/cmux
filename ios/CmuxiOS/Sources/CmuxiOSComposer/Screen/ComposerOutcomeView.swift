import CmuxiOSComposerCore
import CmuxiOSFeatureKit
import UIKit

/// The last send's receipt: "Started in <workspace>" with the task's live
/// state and Open, or why it was not started.
@MainActor
final class ComposerOutcomeView: UIView {
    private let symbol = UIImageView()
    private let title = UILabel()
    private let detail = UILabel()
    private let openButton = UIButton(configuration: .bordered())
    var onOpen: (() -> Void)?
    private var announced: String?

    init() {
        super.init(frame: .zero)
        backgroundColor = .secondarySystemGroupedBackground
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        symbol.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .body)
        symbol.setContentHuggingPriority(.required, for: .horizontal)
        title.font = .preferredFont(forTextStyle: .subheadline)
        title.adjustsFontForContentSizeCategory = true
        title.numberOfLines = 0
        detail.font = .preferredFont(forTextStyle: .footnote)
        detail.adjustsFontForContentSizeCategory = true
        detail.textColor = .secondaryLabel
        detail.numberOfLines = 0
        openButton.configuration?.title = ComposerText.open
        openButton.tintColor = .label
        openButton.setContentHuggingPriority(.required, for: .horizontal)
        openButton.addAction(UIAction { [weak self] _ in self?.onOpen?() }, for: .primaryActionTriggered)
        openButton.accessibilityIdentifier = "composer.outcome.open"
        let labels = UIStackView(arrangedSubviews: [title, detail])
        labels.axis = .vertical
        labels.spacing = 2
        let row = UIStackView(arrangedSubviews: [symbol, labels, openButton])
        row.alignment = .center
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        ])
        isAccessibilityElement = false
        accessibilityIdentifier = "composer.outcome"
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ outcome: ComposerOutcome?, workspaceTitle: String?, task: TaskRecord?) {
        guard let outcome else {
            isHidden = true
            announced = nil
            return
        }
        isHidden = false
        switch outcome {
        case .started(_, let workspaceID, _, _):
            let state = task?.state ?? .queued
            symbol.image = UIImage(systemName: Self.symbol(for: state))
            symbol.tintColor = Self.tint(for: state)
            title.text = ComposerText.started(workspaceTitle ?? workspaceID)
            detail.text = ComposerText.state(state)
            detail.isHidden = false
            openButton.isHidden = false
        case .refused(let reason):
            show(symbol: "exclamationmark.triangle", tint: .systemOrange, text: ComposerText.refused(reason))
        case .notDelivered:
            show(symbol: "wifi.exclamationmark", tint: .systemOrange, text: ComposerText.notDelivered)
        case .unsupported:
            show(symbol: "nosign", tint: .secondaryLabel, text: ComposerText.unsupported)
        }
        let announcement = [title.text, detail.isHidden ? nil : detail.text].compactMap { $0 }.joined(separator: ", ")
        if announcement != announced {
            announced = announcement
            UIAccessibility.post(notification: .announcement, argument: announcement)
        }
    }

    private func show(symbol name: String, tint: UIColor, text: String) {
        symbol.image = UIImage(systemName: name)
        symbol.tintColor = tint
        title.text = text
        detail.isHidden = true
        openButton.isHidden = true
    }

    private static func symbol(for state: TaskState) -> String {
        switch state {
        case .queued: "clock"
        case .running: "circle.dotted.circle"
        case .needsInput: "questionmark.circle"
        case .done: "checkmark.circle"
        case .failed: "xmark.circle"
        }
    }

    private static func tint(for state: TaskState) -> UIColor {
        switch state {
        case .queued: .tertiaryLabel
        case .running: .systemGreen
        case .needsInput: .systemOrange
        case .done: .systemGreen
        case .failed: .systemRed
        }
    }
}
