import CmuxTerminalRenderCore
import UIKit

/// The composer bar (e4-compose.md 3): pinned to the keyboard's top, so it
/// rides above the key bar while the terminal has the keyboard and above
/// the keyboard while the bar has it. The grid never changes for it; the
/// cursor pan keeps the cursor row above it.
extension TerminalViewController {
    /// Whether the session takes composed input now: live, with content,
    /// not ended. A refused send keeps the draft (nothing queues offline).
    public var acceptsComposedInput: Bool {
        let status = session.status
        let ended: Bool = switch status.notice {
        case .kicked, .closed: true
        case .byteReplay, nil: false
        }
        return status.hasContent && !ended && status.chrome.banner == nil && terminalView.surface != nil
    }

    /// Sends a composed prompt through the surface's ordered input path.
    /// Returns false (nothing sent) while the session cannot take input.
    @discardableResult
    public func sendComposed(text: String, submits: Bool) -> Bool {
        guard acceptsComposedInput else { return false }
        terminalView.perform(TerminalComposedInput(text: text, submits: submits).actions)
        return true
    }

    /// Shows or hides the bar (the setting, or the More menu).
    public func setComposerVisible(_ visible: Bool) {
        showsComposer = visible
        guard isViewLoaded else { return }
        if visible, composerProvider != nil {
            installComposer()
        } else {
            removeComposer()
        }
        refreshMenu()
        view.setNeedsLayout()
    }

    /// The More menu's toggle: writes the setting when the owner wired one,
    /// and applies at once either way.
    func toggleComposer() {
        let next = !showsComposer
        onComposerToggle?(next)
        setComposerVisible(next)
        if next { composerController?.view.becomeFirstResponderInSubviews() }
    }

    var composerMenuElement: UIMenuElement? {
        guard composerProvider != nil else { return nil }
        let title = showsComposer ? TerminalCommandText.hideComposer : TerminalCommandText.showComposer
        return UIAction(title: title, image: UIImage(systemName: "square.and.pencil")) { [weak self] _ in
            self?.toggleComposer()
        }
    }

    /// The top of what covers the terminal's bottom: the bar when shown,
    /// else the keyboard (and its key bar).
    var bottomObstructionTop: CGFloat? {
        guard let bar = composerController?.view, bar.superview === view else { return nil }
        return bar.frame.minY
    }

    func notifyComposerAvailability() {
        onComposedInputAvailabilityChange?(acceptsComposedInput)
    }

    private func installComposer() {
        guard composerController == nil, let composerProvider else { return }
        let controller = composerProvider.makeComposer(for: self)
        addChild(controller)
        let bar = controller.view!
        bar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            bar.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor),
        ])
        controller.didMove(toParent: self)
        composerController = controller
        notifyComposerAvailability()
    }

    private func removeComposer() {
        guard let controller = composerController else { return }
        controller.willMove(toParent: nil)
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        composerController = nil
    }
}

private extension UIView {
    /// Focuses the first text input inside (the bar's text view).
    func becomeFirstResponderInSubviews() {
        if canBecomeFirstResponder, self is UITextInput {
            becomeFirstResponder()
            return
        }
        for subview in subviews { subview.becomeFirstResponderInSubviews() }
    }
}
