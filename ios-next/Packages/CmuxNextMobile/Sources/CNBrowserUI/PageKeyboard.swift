import CNCore
import CoreGraphics
import Foundation

/// When the page's software keyboard rises and falls, following Safari:
/// the user's own tap on an editable element raises it, focus leaving the
/// element lowers it, Return in a single-line field lowers it, and a drag
/// on the page pulls it down with the finger (PageKeyboardDismissHost).
struct PageKeyboardPolicy: Equatable {
    enum Decision: Equatable { case raise, lower, keep }

    /// A focus report counts as the answer to a tap made this recently.
    static let tapWindow: TimeInterval = 1.5
    /// Finger travel (points) under which a touch is a tap.
    static let tapSlop: CGFloat = 10

    /// Editable focus of the active tab (nil: none, or not reported).
    private(set) var focus: BrowserFocusEvent?
    /// The last tap on the page, until the next touch starts.
    private var lastTap: (tabId: String, at: Date)?

    /// A touch sequence started on the page: a tap made before it no longer
    /// explains a focus report (a drag ends with no tap).
    mutating func touchBegan() { lastTap = nil }

    mutating func tapped(tabId: String, at now: Date) { lastTap = (tabId, now) }

    /// The active tab or stream changed: forget its focus.
    mutating func reset() {
        focus = nil
        lastTap = nil
    }

    /// Decides what a `browser.focus` report does to the keyboard.
    mutating func handle(_ event: BrowserFocusEvent, activeTabId: String?, streamId: UInt32?, now: Date) -> Decision {
        guard event.tabId == activeTabId, event.streamId == streamId else { return .keep }
        guard event.editable else {
            focus = nil
            return .lower
        }
        focus = event
        // Focus the page gave itself (autofocus, a script) does not raise
        // the keyboard; only the phone user's own tap does, as in Safari.
        guard event.userInitiated != false, let tap = lastTap, tap.tabId == event.tabId,
              now.timeIntervalSince(tap.at) <= Self.tapWindow else { return .keep }
        return .raise
    }

    static func == (a: Self, b: Self) -> Bool {
        a.focus == b.focus && a.lastTap?.tabId == b.lastTap?.tabId && a.lastTap?.at == b.lastTap?.at
    }
}

/// Keyboard traits of the focused page field (nil: none reported).
struct PageFieldTraits: Equatable {
    var focus: BrowserFocusEvent?

    /// Return lowers the keyboard in a single-line field (it submits there)
    /// and when no field was reported; a multi-line field gets a new line.
    var returnLowersKeyboard: Bool { focus?.multiline != true }

    enum ReturnKey: Equatable { case `default`, go, search, send, next, done }

    /// The Return key's label for the focused field (`enterkeyhint`, then
    /// the input type).
    var returnKey: ReturnKey {
        guard let focus else { return .default }
        switch focus.enterKeyHint?.lowercased() {
        case "go": return .go
        case "search": return .search
        case "send": return .send
        case "next": return .next
        case "done": return .done
        case "enter": return .default
        default: break
        }
        if focus.multiline == true { return .default }
        switch focus.inputType?.lowercased() {
        case "search": return .search
        case "url": return .go
        default: return .default
        }
    }

    enum KeyboardKind: Equatable { case text, email, url, phone, number, decimal }

    /// The keyboard layout for the focused field (`inputmode`, then the type).
    var keyboardKind: KeyboardKind {
        guard let focus else { return .text }
        switch focus.inputMode?.lowercased() {
        case "email": return .email
        case "url": return .url
        case "tel": return .phone
        case "numeric": return .number
        case "decimal": return .decimal
        case "text", "search": return .text
        default: break
        }
        switch focus.inputType?.lowercased() {
        case "email": return .email
        case "url": return .url
        case "tel": return .phone
        case "number": return .decimal
        default: return .text
        }
    }
}
