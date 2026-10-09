import Foundation

/// Input forwarded to the Mac page, in page CSS pixels, applied once and in
/// order (c2-browser-stream.md section 4).
public enum BrowserInput: Hashable, Sendable {
    case pointer(BrowserPointerEvent)
    case wheel(BrowserWheelEvent)
    case key(BrowserKeyEvent)
    /// IME marked text; `selection` is in UTF-16 offsets of `text`.
    case composition(text: String, selection: Range<Int>)
    /// Committed text (software keyboard or the end of a composition).
    case commit(String)
    case cancelComposition
}
