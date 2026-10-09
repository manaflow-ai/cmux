#if os(iOS)
import CNCore
import CNTransport
import Foundation
import UIKit

/// One input event for the remote tab.
enum BrowserInputEvent: Sendable {
    case touch(BrowserTouchParams)
    case pointer(BrowserPointerParams)
    case key(BrowserKeyParams)
    case text(BrowserTextParams)
    case scroll(BrowserScrollParams)
}

/// Sends input to the host strictly in order. Each RPC is awaited before
/// the next is sent, so a slow link cannot reorder a touch end before its
/// moves. While a call is in flight, consecutive touch moves with the same
/// touch ids collapse into the newest one, which keeps scrolling current
/// instead of replaying a backlog.
///
/// When the host answers `browser.touch` with `unsupported`, touches fall
/// back to `browser.pointer` (a single-pointer mouse drag and click) for the
/// rest of the session.
@MainActor
final class BrowserInputPump {
    private var queue: [BrowserInputEvent] = []
    private var draining = false
    private(set) var touchUnsupported = false
    private let clientProvider: @MainActor () -> HostClient?

    init(client: @escaping @MainActor () -> HostClient?) {
        self.clientProvider = client
    }

    func send(_ event: BrowserInputEvent) {
        if case .touch(let t) = event, t.type == .move, case .touch(let last)? = queue.last, last.type == .move,
           last.tabId == t.tabId, last.points.map(\.id) == t.points.map(\.id) {
            queue[queue.count - 1] = event
        } else {
            queue.append(event)
        }
        guard !draining else { return }
        draining = true
        Task { await drain() }
    }

    /// Drops queued input (tab switch or reconnect).
    func reset() {
        queue.removeAll()
    }

    private func drain() async {
        while !queue.isEmpty {
            let event = queue.removeFirst()
            guard let client = clientProvider() else { queue.removeAll(); break }
            for converted in convert(event) {
                do {
                    try await deliver(converted, client: client)
                } catch let error as RPCError where error.code == .unsupported {
                    if case .touch = converted, !touchUnsupported {
                        touchUnsupported = true
                        for fallback in convert(converted) { try? await deliver(fallback, client: client) }
                    }
                } catch {
                    // Input is best effort: a dropped event must not stall the queue.
                }
            }
        }
        draining = false
    }

    private func convert(_ event: BrowserInputEvent) -> [BrowserInputEvent] {
        guard touchUnsupported, case .touch(let t) = event else { return [event] }
        guard let p = t.points.first else {
            return t.type == .end || t.type == .cancel ? [.pointer(BrowserPointerParams(tabId: t.tabId, type: .up, x: lastPointer.x, y: lastPointer.y))] : []
        }
        lastPointer = (p.x, p.y)
        switch t.type {
        case .start: return [.pointer(BrowserPointerParams(tabId: t.tabId, type: .down, x: p.x, y: p.y))]
        case .move: return [.pointer(BrowserPointerParams(tabId: t.tabId, type: .move, x: p.x, y: p.y, button: .left, clickCount: 0))]
        case .end, .cancel: return [.pointer(BrowserPointerParams(tabId: t.tabId, type: .up, x: p.x, y: p.y))]
        }
    }

    private var lastPointer: (x: Double, y: Double) = (0, 0)

    private func deliver(_ event: BrowserInputEvent, client: HostClient) async throws {
        switch event {
        case .touch(let p): try await client.touch(p)
        case .pointer(let p): try await client.pointer(p)
        case .key(let p): try await client.key(p)
        case .text(let p): try await client.insertText(p.tabId, text: p.text)
        case .scroll(let p): try await client.scroll(p)
        }
    }
}

/// DOM `key` / `code` values for a hardware key press, plus CDP modifier bits.
struct DOMKey: Sendable, Hashable {
    var key: String
    var code: String
    var text: String?
    var modifiers: Int

    static let alt = 1, ctrl = 2, meta = 4, shift = 8

    static func modifiers(_ flags: UIKeyModifierFlags) -> Int {
        var m = 0
        if flags.contains(.alternate) { m |= alt }
        if flags.contains(.control) { m |= ctrl }
        if flags.contains(.command) { m |= meta }
        if flags.contains(.shift) { m |= shift }
        return m
    }

    /// Named keys that never produce text.
    static let named: [UIKeyboardHIDUsage: (String, String)] = [
        .keyboardReturnOrEnter: ("Enter", "Enter"), .keypadEnter: ("Enter", "NumpadEnter"),
        .keyboardDeleteOrBackspace: ("Backspace", "Backspace"), .keyboardDeleteForward: ("Delete", "Delete"),
        .keyboardTab: ("Tab", "Tab"), .keyboardEscape: ("Escape", "Escape"),
        .keyboardLeftArrow: ("ArrowLeft", "ArrowLeft"), .keyboardRightArrow: ("ArrowRight", "ArrowRight"),
        .keyboardUpArrow: ("ArrowUp", "ArrowUp"), .keyboardDownArrow: ("ArrowDown", "ArrowDown"),
        .keyboardHome: ("Home", "Home"), .keyboardEnd: ("End", "End"),
        .keyboardPageUp: ("PageUp", "PageUp"), .keyboardPageDown: ("PageDown", "PageDown"),
    ]

    /// Maps a `UIKey`. Returns nil for bare modifier presses.
    init?(_ uiKey: UIKey) {
        let mods = Self.modifiers(uiKey.modifierFlags)
        if let (k, c) = Self.named[uiKey.keyCode] {
            self.init(key: k, code: c, text: k == "Enter" ? "\r" : nil, modifiers: mods)
            return
        }
        let chars = uiKey.characters
        guard !chars.isEmpty, chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        let code = Self.code(for: uiKey.charactersIgnoringModifiers)
        // Shortcuts (cmd/ctrl) carry no text so the page treats them as commands.
        let isShortcut = mods & (Self.meta | Self.ctrl) != 0
        self.init(key: isShortcut ? uiKey.charactersIgnoringModifiers : chars, code: code, text: isShortcut ? nil : chars, modifiers: mods)
    }

    init(key: String, code: String, text: String?, modifiers: Int) {
        self.key = key; self.code = code; self.text = text; self.modifiers = modifiers
    }

    static func code(for base: String) -> String {
        guard let c = base.lowercased().first else { return "" }
        if c.isLetter, c.isASCII { return "Key" + String(c).uppercased() }
        if c.isNumber, c.isASCII { return "Digit" + String(c) }
        switch c {
        case " ": return "Space"
        case "-": return "Minus"
        case "=": return "Equal"
        case "[": return "BracketLeft"
        case "]": return "BracketRight"
        case "\\": return "Backslash"
        case ";": return "Semicolon"
        case "'": return "Quote"
        case ",": return "Comma"
        case ".": return "Period"
        case "/": return "Slash"
        case "`": return "Backquote"
        default: return ""
        }
    }
}
#endif
