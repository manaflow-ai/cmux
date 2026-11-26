import Foundation

/// The compose field's text state: committed text, the insertion point and
/// IME marked text (UTF-16 ranges, as NSTextInputClient and UITextInput use).
struct ComposeEditor: Hashable {
    var text = ""
    var selection = NSRange(location: 0, length: 0)
    var marked: NSRange?

    private var length: Int { (text as NSString).length }

    private func clamp(_ r: NSRange) -> NSRange {
        let loc = min(max(0, r.location), length)
        return NSRange(location: loc, length: min(max(0, r.length), length - loc))
    }

    /// Insert (or commit) text, replacing `range`, else the marked text, else the selection.
    mutating func insert(_ s: String, replacing range: NSRange? = nil) {
        let r = clamp(range ?? marked ?? selection)
        text = (text as NSString).replacingCharacters(in: r, with: s)
        selection = NSRange(location: r.location + (s as NSString).length, length: 0)
        marked = nil
    }

    /// IME composition: `s` replaces the marked text (or `range`, or the selection)
    /// and stays marked; `selected` is relative to `s`.
    mutating func setMarked(_ s: String, selected: NSRange, replacing range: NSRange? = nil) {
        let r = clamp(range ?? marked ?? selection)
        text = (text as NSString).replacingCharacters(in: r, with: s)
        let n = (s as NSString).length
        marked = n > 0 ? NSRange(location: r.location, length: n) : nil
        selection = NSRange(location: r.location + min(selected.location, n), length: min(selected.length, n))
    }

    mutating func unmark() { marked = nil }

    mutating func deleteBackward() {
        if marked != nil { marked = nil }
        if selection.length > 0 { insert("", replacing: selection); return }
        guard selection.location > 0 else { return }
        let ns = text as NSString
        let r = ns.rangeOfComposedCharacterSequence(at: selection.location - 1)
        insert("", replacing: r)
    }

    mutating func moveCaret(by d: Int) {
        marked = nil
        let ns = text as NSString
        var loc = selection.location + (selection.length > 0 && d > 0 ? selection.length : 0)
        if d < 0, loc > 0 { loc = ns.rangeOfComposedCharacterSequence(at: loc - 1).location }
        else if d > 0, loc < length { loc = NSMaxRange(ns.rangeOfComposedCharacterSequence(at: loc)) }
        selection = NSRange(location: loc, length: 0)
    }

    /// Text set from outside (cleared after a send, restored after a refusal).
    mutating func reset(_ s: String) {
        guard s != text else { return }
        text = s
        selection = NSRange(location: length, length: 0)
        marked = nil
    }
}
