import GhosttyNextKit
import UIKit

/// Selection and copy over Ghostty's selection (made by the long-press
/// gesture). Copy is bounded: a selection beyond the bound is not silently
/// truncated, it is refused (the host's `terminal.read_range` covers that
/// later, ghostty-next section 7).
extension GhosttyTerminalView: @preconcurrency UIEditMenuInteractionDelegate {
    /// The most a copy writes to the pasteboard.
    static let copyLimitBytes = 4 * 1024 * 1024

    var hasSelection: Bool {
        guard let surface else { return false }
        return ghostty_surface_has_selection(surface)
    }

    /// The selected text (tests and accessibility), nil without a selection.
    public var selectedText: String? {
        guard let surface else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let bytes = text.text, text.text_len > 0 else { return nil }
        return String(decoding: UnsafeRawBufferPointer(start: bytes, count: Int(text.text_len)), as: UTF8.self)
    }

    public override func copy(_ sender: Any?) {
        guard let surface else { return }
        _ = ghostty_surface_copy_selection_to_clipboard_bounded(surface, UInt(Self.copyLimitBytes))
    }

    public override func selectAll(_ sender: Any?) {
        guard let surface else { return }
        let action = "select_all"
        _ = action.withCString { ghostty_surface_binding_action(surface, $0, UInt(action.utf8.count)) }
        requestFrame()
    }

    func presentEditMenu(at point: CGPoint) {
        guard let menu = interactions.compactMap({ $0 as? UIEditMenuInteraction }).first else { return }
        menu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: point))
    }

    func dismissEditMenu() {
        interactions.compactMap { $0 as? UIEditMenuInteraction }.first?.dismissMenu()
    }

    public func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                                    suggestedActions: [UIMenuElement]) -> UIMenu? {
        var actions: [UIMenuElement] = []
        if hasSelection {
            actions.append(UIAction(title: TerminalText.menuCopy) { [weak self] _ in self?.copy(nil) })
        }
        actions.append(UIAction(title: TerminalText.menuSelectAll) { [weak self] _ in
            self?.selectAll(nil)
            if let self { self.presentEditMenu(at: configuration.sourcePoint) }
        })
        if UIPasteboard.general.hasStrings {
            actions.append(UIAction(title: TerminalText.keyPaste) { [weak self] _ in self?.paste(nil) })
        }
        return UIMenu(children: actions)
    }
}
