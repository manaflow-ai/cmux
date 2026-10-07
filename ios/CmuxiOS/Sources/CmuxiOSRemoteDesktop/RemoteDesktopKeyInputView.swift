import CmuxRemoteDesktop
import UIKit

/// The hidden first responder that brings up the software keyboard and
/// receives hardware keys (c3-rd.md 3): committed text, backspace, and
/// `UIPress` HID usages with their modifiers.
@MainActor
final class RemoteDesktopKeyInputView: UIView, UIKeyInput {
    var onText: ((String) -> Void)?
    var onBackspace: (() -> Void)?
    var onKey: ((HidUsage, Bool) -> Void)?
    var accessory: UIView?

    override var canBecomeFirstResponder: Bool { true }
    override var inputAccessoryView: UIView? { accessory }

    var hasText: Bool { true }
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .default
    var returnKeyType: UIReturnKeyType = .default

    func insertText(_ text: String) {
        onText?(text)
    }

    func deleteBackward() {
        onBackspace?()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !forward(presses, down: true) { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !forward(presses, down: false) { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !forward(presses, down: false) { super.pressesCancelled(presses, with: event) }
    }

    /// Hardware keys go out as HID usages; the text path then stays quiet.
    func forward(_ presses: Set<UIPress>, down: Bool) -> Bool {
        let keys = presses.compactMap(\.key)
        guard !keys.isEmpty, let onKey else { return false }
        for key in keys { onKey(HidUsage(keyboard: UInt32(key.keyCode.rawValue)), down) }
        return true
    }
}
