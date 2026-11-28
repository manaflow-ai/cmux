import UIKit

/// The software keyboard, dictation and input methods (ghostty-next section 5):
/// a documentless `UITextInput`. The view owns no text. Its virtual document is
/// the input method's marked text, or one zero-width character before the
/// caret, so the keyboard always sees something to delete and keeps repeating
/// Backspace while it is held (the old app's delete-repeat anchor). Marked text
/// is drawn by Ghostty as preedit and never sent; committed text goes to the
/// router.
extension GhosttyTerminalView: UITextInput {
    private static let anchor = "\u{200B}"

    private var document: String { input.markedText ?? Self.anchor }
    private var documentLength: Int { (document as NSString).length }

    // MARK: UIKeyInput

    public var hasText: Bool { true }

    public func insertText(_ text: String) {
        withTextChange { perform(input.insertText(text)) }
    }

    public func deleteBackward() {
        if let marked = input.markedText {
            // The input method normally edits its own marked text; a bare
            // Backspace on it drops the last character.
            withTextChange { perform(input.setMarkedText(String(marked.dropLast()))) }
            return
        }
        // Re-announce the anchor so the keyboard sees a fresh character to delete.
        withTextChange { perform(input.deleteBackward()) }
    }

    // MARK: Marked text

    public var markedTextRange: UITextRange? {
        guard let marked = input.markedText else { return nil }
        return TerminalTextRange(start: 0, end: (marked as NSString).length)
    }

    public var markedTextStyle: [NSAttributedString.Key: Any]? {
        get { nil }
        set { _ = newValue }
    }

    public func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        withTextChange { perform(input.setMarkedText(markedText)) }
    }

    public func unmarkText() {
        withTextChange { perform(input.unmarkText()) }
    }

    private func withTextChange(_ change: () -> Void) {
        inputDelegate?.textWillChange(self)
        change()
        inputDelegate?.textDidChange(self)
    }

    // MARK: Document

    public var selectedTextRange: UITextRange? {
        get { TerminalTextRange(start: documentLength, end: documentLength) }
        set { _ = newValue }
    }

    public var beginningOfDocument: UITextPosition { TerminalTextPosition(0) }
    public var endOfDocument: UITextPosition { TerminalTextPosition(documentLength) }

    public func text(in range: UITextRange) -> String? {
        guard let range = range as? TerminalTextRange else { return nil }
        let doc = document as NSString
        let start = min(max(range.startOffset, 0), doc.length)
        let end = min(max(range.endOffset, start), doc.length)
        return doc.substring(with: NSRange(location: start, length: end - start))
    }

    /// Some commits (text replacement, suggestions) replace a range instead of
    /// inserting; the text still reaches the terminal.
    public func replace(_ range: UITextRange, withText text: String) {
        if input.markedText != nil { withTextChange { perform(input.setMarkedText(nil)) } }
        guard !text.isEmpty else { return }
        insertText(text)
    }

    public func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        guard let from = fromPosition as? TerminalTextPosition, let to = toPosition as? TerminalTextPosition else { return nil }
        return TerminalTextRange(start: from.offset, end: to.offset)
    }

    public func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard let position = position as? TerminalTextPosition else { return nil }
        return TerminalTextPosition(min(max(position.offset + offset, 0), documentLength))
    }

    public func position(from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int) -> UITextPosition? {
        self.position(from: position, offset: direction == .right || direction == .down ? offset : -offset)
    }

    public func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        guard let lhs = position as? TerminalTextPosition, let rhs = other as? TerminalTextPosition else { return .orderedSame }
        return lhs.offset < rhs.offset ? .orderedAscending : lhs.offset > rhs.offset ? .orderedDescending : .orderedSame
    }

    public func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        guard let from = from as? TerminalTextPosition, let to = toPosition as? TerminalTextPosition else { return 0 }
        return to.offset - from.offset
    }

    public var tokenizer: UITextInputTokenizer { UITextInputStringTokenizer(textInput: self) }

    public func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? { nil }
    public func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? { nil }
    public func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection {
        .leftToRight
    }
    public func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}

    /// The candidate window and the dictation UI sit at the terminal cursor.
    public func firstRect(for range: UITextRange) -> CGRect { cursorRect }
    public func caretRect(for position: UITextPosition) -> CGRect { cursorRect }
    public func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { [] }
    public func closestPosition(to point: CGPoint) -> UITextPosition? { endOfDocument }
    public func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? { range.end }
    public func characterRange(at point: CGPoint) -> UITextRange? { nil }

    // Dictation: a placeholder tells UIKit the view takes dictation; the
    // recognized text arrives through insertText.
    public func insertDictationResultPlaceholder() -> Any { "" }
    public func removeDictationResultPlaceholder(_ placeholder: Any, willInsertResult: Bool) {}

    // MARK: Traits: a terminal, not prose

    public var autocorrectionType: UITextAutocorrectionType { get { .no } set { _ = newValue } }
    public var autocapitalizationType: UITextAutocapitalizationType { get { .none } set { _ = newValue } }
    public var spellCheckingType: UITextSpellCheckingType { get { .no } set { _ = newValue } }
    public var smartQuotesType: UITextSmartQuotesType { get { .no } set { _ = newValue } }
    public var smartDashesType: UITextSmartDashesType { get { .no } set { _ = newValue } }
    public var smartInsertDeleteType: UITextSmartInsertDeleteType { get { .no } set { _ = newValue } }
    public var inlinePredictionType: UITextInlinePredictionType { get { .no } set { _ = newValue } }
    public var keyboardType: UIKeyboardType { get { keyboardKind } set { _ = newValue } }
    public var keyboardAppearance: UIKeyboardAppearance { get { .dark } set { _ = newValue } }
    public var returnKeyType: UIReturnKeyType { get { .default } set { _ = newValue } }
}

/// A position in the terminal's virtual document (UTF-16 offset).
final class TerminalTextPosition: UITextPosition {
    let offset: Int
    init(_ offset: Int) { self.offset = offset }
}

/// A range in the terminal's virtual document (UTF-16 offsets).
final class TerminalTextRange: UITextRange {
    let startOffset: Int
    let endOffset: Int

    init(start: Int, end: Int) {
        startOffset = start
        endOffset = end
    }

    override var start: UITextPosition { TerminalTextPosition(startOffset) }
    override var end: UITextPosition { TerminalTextPosition(endOffset) }
    override var isEmpty: Bool { endOffset <= startOffset }
}
