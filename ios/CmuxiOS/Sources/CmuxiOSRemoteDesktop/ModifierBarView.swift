import CmuxiOSRemoteDesktopCore
import CmuxRemoteDesktop
import UIKit

/// The row above the keyboard: escape, tab, the four modifiers (tap to
/// latch for the next key, tap again to lock), arrows and Paste to Mac.
@MainActor
final class ModifierBarView: UIInputView {
    var onKey: ((HidUsage) -> Void)?
    var onModifier: ((ModifierLatch.Modifier) -> Void)?
    var onPaste: (() -> Void)?
    private var modifierButtons: [ModifierLatch.Modifier: UIButton] = [:]

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 48), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 48),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        stack.addArrangedSubview(button(title: "esc", label: RemoteDesktopText.keyEscape) { [weak self] in self?.onKey?(.escape) })
        stack.addArrangedSubview(button(title: "⇥", label: RemoteDesktopText.keyTab) { [weak self] in self?.onKey?(.tab) })
        for (modifier, glyph, label) in [(ModifierLatch.Modifier.control, "⌃", RemoteDesktopText.keyControl),
                                         (.option, "⌥", RemoteDesktopText.keyOption), (.command, "⌘", RemoteDesktopText.keyCommand),
                                         (.shift, "⇧", RemoteDesktopText.keyShift)] {
            let item = button(title: glyph, label: label) { [weak self] in self?.onModifier?(modifier) }
            modifierButtons[modifier] = item
            stack.addArrangedSubview(item)
        }
        for (usage, symbol, label) in [(HidUsage.left, "arrow.left", RemoteDesktopText.keyLeft),
                                       (.up, "arrow.up", RemoteDesktopText.keyUp), (.down, "arrow.down", RemoteDesktopText.keyDown),
                                       (.right, "arrow.right", RemoteDesktopText.keyRight)] {
            stack.addArrangedSubview(button(symbol: symbol, label: label) { [weak self] in self?.onKey?(usage) })
        }
        stack.addArrangedSubview(button(symbol: "doc.on.clipboard", label: RemoteDesktopText.pasteToMac) { [weak self] in
            self?.onPaste?()
        })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows latched modifiers tinted and locked ones filled.
    func show(_ latch: ModifierLatch) {
        for (modifier, item) in modifierButtons {
            var configuration = latch.locked.contains(modifier) ? UIButton.Configuration.filled() : UIButton.Configuration.gray()
            configuration.title = item.configuration?.title
            configuration.baseForegroundColor = latch.active.contains(modifier) && !latch.locked.contains(modifier) ? .label : nil
            configuration.baseBackgroundColor = latch.latched.contains(modifier) ? .systemGray3 : nil
            item.configuration = configuration
            item.isSelected = latch.active.contains(modifier)
        }
    }

    private func button(title: String? = nil, symbol: String? = nil, label: String, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.gray()
        configuration.title = title
        if let symbol { configuration.image = UIImage(systemName: symbol) }
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
        let item = UIButton(configuration: configuration, primaryAction: UIAction { _ in action() })
        item.accessibilityLabel = label
        item.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        return item
    }
}
