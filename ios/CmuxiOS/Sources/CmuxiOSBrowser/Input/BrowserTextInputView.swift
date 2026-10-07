import CmuxiOSBrowserCore
import CmuxiOSFeatureKit
import UIKit

/// The hidden first responder that turns the software keyboard and IME into
/// page input (c2-browser-stream.md section 4). Its document is only the
/// current composition: committed text leaves at once as `commit`, marked
/// text goes out as `composition`, and editing keys go out as DOM key
/// events. Hardware keys that type nothing (arrows, Escape, shortcuts) are
/// sent as key events from `pressesBegan`; typing keys go through
/// `insertText` so IME keeps working.
@MainActor
final class BrowserTextInputView: UIView, UITextInput {
    var onInput: ((BrowserInput) -> Void)?

    private var marked = ""
    private var selection = 0..<0
    private let keyMap = BrowserKeyCodeMap()

    override var canBecomeFirstResponder: Bool { true }

    // MARK: UITextInputTraits

    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .default
    var returnKeyType: UIReturnKeyType = .default

    // MARK: UIKeyInput

    var hasText: Bool { true }

    func insertText(_ text: String) {
        if !marked.isEmpty {
            marked = ""
            selection = 0..<0
        }
        switch text {
        case "\n": sendKey(code: "Enter", key: "Enter")
        case "\t": sendKey(code: "Tab", key: "Tab")
        default: onInput?(.commit(text))
        }
    }

    func deleteBackward() {
        if !marked.isEmpty {
            setMarkedText(String(marked.dropLast()), selectedRange: NSRange(location: max(0, marked.utf16.count - 1), length: 0))
            return
        }
        sendKey(code: "Backspace", key: "Backspace")
    }

    // MARK: Marked text

    var markedTextRange: UITextRange? { marked.isEmpty ? nil : BrowserTextRange(0, marked.utf16.count) }
    var markedTextStyle: [NSAttributedString.Key: Any]?

    func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        let text = markedText ?? ""
        marked = text
        let length = text.utf16.count
        let lower = min(max(0, selectedRange.location), length)
        selection = lower..<min(length, lower + max(0, selectedRange.length))
        onInput?(text.isEmpty ? .cancelComposition : .composition(text: text, selection: selection))
    }

    func unmarkText() {
        guard !marked.isEmpty else { return }
        let text = marked
        marked = ""
        selection = 0..<0
        onInput?(.commit(text))
    }

    // MARK: Document (the composition only)

    var selectedTextRange: UITextRange? {
        get { BrowserTextRange(selection.lowerBound, selection.upperBound) }
        set {
            guard let range = newValue as? BrowserTextRange else { return }
            selection = range.lower..<range.upper
        }
    }

    var beginningOfDocument: UITextPosition { BrowserTextPosition(0) }
    var endOfDocument: UITextPosition { BrowserTextPosition(marked.utf16.count) }
    weak var inputDelegate: (any UITextInputDelegate)?
    lazy var tokenizer: any UITextInputTokenizer = UITextInputStringTokenizer(textInput: self)

    func text(in range: UITextRange) -> String? {
        guard let range = range as? BrowserTextRange else { return nil }
        let units = Array(marked.utf16)
        let lower = min(range.lower, units.count)
        let upper = min(range.upper, units.count)
        return String(utf16CodeUnits: Array(units[lower..<upper]), count: upper - lower)
    }

    func replace(_ range: UITextRange, withText text: String) {
        insertText(text)
    }

    func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        guard let from = fromPosition as? BrowserTextPosition, let to = toPosition as? BrowserTextPosition else { return nil }
        return BrowserTextRange(from.offset, to.offset)
    }

    func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard let position = position as? BrowserTextPosition else { return nil }
        let next = position.offset + offset
        return (0...marked.utf16.count).contains(next) ? BrowserTextPosition(next) : nil
    }

    func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        switch direction {
        case .left, .up: self.position(from: position, offset: -offset)
        default: self.position(from: position, offset: offset)
        }
    }

    func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        let a = (position as? BrowserTextPosition)?.offset ?? 0
        let b = (other as? BrowserTextPosition)?.offset ?? 0
        return a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
    }

    func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        ((toPosition as? BrowserTextPosition)?.offset ?? 0) - ((from as? BrowserTextPosition)?.offset ?? 0)
    }

    func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        switch direction {
        case .left, .up: range.start
        default: range.end
        }
    }

    func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        guard let position = position as? BrowserTextPosition else { return nil }
        switch direction {
        case .left, .up: return BrowserTextRange(0, position.offset)
        default: return BrowserTextRange(position.offset, marked.utf16.count)
        }
    }

    func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection { .natural }
    func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}
    func firstRect(for range: UITextRange) -> CGRect { caretFrame }
    func caretRect(for position: UITextPosition) -> CGRect { caretFrame }
    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { [] }
    func closestPosition(to point: CGPoint) -> UITextPosition? { endOfDocument }
    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? { range.end }
    func characterRange(at point: CGPoint) -> UITextRange? { nil }

    /// Where the IME candidate window anchors (the page caret when known).
    var caretFrame = CGRect(x: 0, y: 0, width: 1, height: 20)

    // MARK: Hardware keys

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled: Set<UIPress> = []
        for press in presses {
            guard let key = press.key, let event = keyEvent(key, down: true) else {
                unhandled.insert(press)
                continue
            }
            onInput?(.key(event))
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled: Set<UIPress> = []
        for press in presses {
            guard let key = press.key, let event = keyEvent(key, down: false) else {
                unhandled.insert(press)
                continue
            }
            onInput?(.key(event))
        }
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    /// A DOM key event for keys that type nothing or carry Command/Control;
    /// nil lets the key reach `insertText` (typing and IME).
    private func keyEvent(_ key: UIKey, down: Bool) -> BrowserKeyEvent? {
        let usage = key.keyCode.rawValue
        guard let code = keyMap.code(forHIDUsage: usage) else { return nil }
        let modifiers = Self.modifiers(key.modifierFlags)
        let shortcut = !modifiers.intersection([.command, .control]).isEmpty
        if let name = keyMap.key(forHIDUsage: usage), marked.isEmpty {
            return BrowserKeyEvent(down: down, code: code, key: name, modifiers: modifiers)
        }
        guard shortcut else { return nil }
        let character = key.charactersIgnoringModifiers
        return BrowserKeyEvent(down: down, code: code, key: character, modifiers: modifiers)
    }

    private func sendKey(code: String, key: String) {
        onInput?(.key(BrowserKeyEvent(down: true, code: code, key: key)))
        onInput?(.key(BrowserKeyEvent(down: false, code: code, key: key)))
    }

    private static func modifiers(_ flags: UIKeyModifierFlags) -> BrowserModifiers {
        var out: BrowserModifiers = []
        if flags.contains(.shift) { out.insert(.shift) }
        if flags.contains(.control) { out.insert(.control) }
        if flags.contains(.alternate) { out.insert(.option) }
        if flags.contains(.command) { out.insert(.command) }
        return out
    }
}
