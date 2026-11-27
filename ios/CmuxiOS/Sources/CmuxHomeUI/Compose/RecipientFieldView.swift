import CmuxHomeCore
import CmuxiOSDesign
import UIKit

/// The To: field: "To:" then one chip per recipient, then the text field,
/// wrapping onto more lines. A comma, semicolon, Return or leaving the
/// field turns the typed text into chips; Delete on an empty field removes
/// the last chip. Members show their name, new people an "Invite" badge,
/// invalid entries are marked.
@MainActor
final class RecipientFieldView: UIView, UITextFieldDelegate {
    var onReturn: (@MainActor () -> Void)?

    let textField = BackspaceTextField()
    private let model: RecipientModel
    private let flow = TokenFlowView()
    private let toLabel = UILabel()

    init(model: RecipientModel) {
        self.model = model
        super.init(frame: .zero)
        backgroundColor = HomePalette.background

        toLabel.text = HomeText.toLabel
        toLabel.font = .preferredFont(forTextStyle: .body)
        toLabel.adjustsFontForContentSizeCategory = true
        toLabel.textColor = HomePalette.secondaryText
        toLabel.isAccessibilityElement = false

        textField.font = .preferredFont(forTextStyle: .body)
        textField.adjustsFontForContentSizeCategory = true
        textField.keyboardType = .emailAddress
        textField.textContentType = .emailAddress
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.spellCheckingType = .no
        textField.returnKeyType = .next
        textField.tintColor = HomePalette.accent
        textField.placeholder = HomeText.toPlaceholder
        textField.accessibilityLabel = HomeText.toA11y
        textField.delegate = self
        textField.onDeleteWhenEmpty = { [weak self] in self?.model.removeLast() }

        flow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(flow)
        let separator = UIView()
        separator.backgroundColor = HomePalette.separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)
        NSLayoutConstraint.activate([
            flow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HomeMetrics.sideInset),
            flow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HomeMetrics.sideInset),
            flow.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            flow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5),
        ])
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Rebuilds the chips from the model.
    func reload() {
        var views: [UIView] = [toLabel]
        for recipient in model.set.recipients {
            views.append(chip(for: recipient))
        }
        views.append(textField)
        flow.setArrangedViews(views, lastFillsLine: true)
    }

    /// Turns whatever is typed into chips.
    func commitTypedText() {
        let text = textField.text ?? ""
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        textField.text = ""
        model.add(text: text)
    }

    private func chip(for recipient: Recipient) -> UIButton {
        var configuration = UIButton.Configuration.gray()
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
        configuration.baseForegroundColor = HomePalette.primaryText
        var title = AttributedString(recipient.title)
        title.font = UIFont.preferredFont(forTextStyle: .subheadline)
        let label: String
        switch recipient.state {
        case .member:
            label = HomeText.recipientMemberA11y(recipient.title)
        case .invitable:
            var badge = AttributedString("  " + HomeText.inviteBadge)
            badge.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .systemFont(ofSize: 12, weight: .semibold))
            badge.foregroundColor = HomePalette.secondaryText
            title.append(badge)
            label = HomeText.recipientInvitableA11y(recipient.title)
        case .invalid:
            configuration.baseForegroundColor = HomePalette.failure
            configuration.image = UIImage(systemName: "exclamationmark.circle.fill")
            configuration.imagePadding = 4
            configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .caption1)
            label = HomeText.recipientInvalidA11y(recipient.raw)
        case .resolving:
            configuration.baseForegroundColor = HomePalette.secondaryText
            label = recipient.title
        case .unresolved:
            label = recipient.title
        }
        configuration.attributedTitle = title
        let button = UIButton(configuration: configuration)
        let id = recipient.id
        button.menu = UIMenu(children: [
            UIAction(title: HomeText.remove, image: UIImage(systemName: "xmark.circle"), attributes: .destructive) {
                [weak self] _ in self?.model.remove(id: id)
            },
        ])
        button.showsMenuAsPrimaryAction = true
        button.accessibilityLabel = label
        button.accessibilityCustomActions = [UIAccessibilityCustomAction(name: HomeText.remove) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.remove(id: id) }
            return true
        }]
        return button
    }

    // MARK: UITextFieldDelegate

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange,
                   replacementString string: String) -> Bool {
        guard string.contains(",") || string.contains(";") || string.contains("\n") else { return true }
        let current = (textField.text ?? "") as NSString
        textField.text = current.replacingCharacters(in: range, with: string)
        commitTypedText()
        return false
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        commitTypedText()
        onReturn?()
        return false
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        commitTypedText()
    }
}

/// A text field that reports Delete on an empty field (removes the last chip).
@MainActor
final class BackspaceTextField: UITextField {
    var onDeleteWhenEmpty: (@MainActor () -> Void)?

    override func deleteBackward() {
        if (text ?? "").isEmpty { onDeleteWhenEmpty?() }
        super.deleteBackward()
    }
}

/// Lays out views left to right and wraps them onto new lines. The last
/// view can take the rest of its line (the text field).
@MainActor
final class TokenFlowView: UIView {
    private var views: [UIView] = []
    private var lastFillsLine = false
    private let spacing: CGFloat = 6
    private let minimumLastWidth: CGFloat = 120
    private var measuredHeight: CGFloat = 0

    func setArrangedViews(_ next: [UIView], lastFillsLine: Bool) {
        for view in views where !next.contains(view) { view.removeFromSuperview() }
        for view in next where view.superview !== self { addSubview(view) }
        views = next
        self.lastFillsLine = lastFillsLine
        setNeedsLayout()
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: measuredHeight)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let height = arrange(width: bounds.width, apply: true)
        if abs(height - measuredHeight) > 0.5 {
            measuredHeight = height
            invalidateIntrinsicContentSize()
        }
    }

    /// Places the views for `width`; returns the total height.
    private func arrange(width: CGFloat, apply: Bool) -> CGFloat {
        guard width > 0 else { return 0 }
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for (index, view) in views.enumerated() {
            let isLast = index == views.count - 1
            var size = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            size.width = min(width, isLast && lastFillsLine ? max(minimumLastWidth, size.width) : size.width)
            size.height = max(size.height, 32)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            if isLast, lastFillsLine { size.width = width - x }
            if apply { view.frame = CGRect(x: x, y: y, width: size.width, height: size.height) }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return y + lineHeight
    }
}
