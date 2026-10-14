import CoreGraphics

/// The one owner of the terminal's scroll position (verify/terminal-scroll-model.md).
///
/// Three states:
/// - `following`: pinned to the bottom; new output keeps it there.
/// - `reading(anchor)`: the person scrolled away; the position is a content
///   row's identity (its absolute row in Ghostty's scrollback plus a pixel
///   remainder), so output, a redraw below, or a document that grows or moves
///   its top never moves the rows being read.
/// - `interacting`: a finger is down or the page decelerates; nothing but
///   UIKit moves it.
///
/// Transitions happen only on the person's input (drag start, release or the
/// end of a deceleration, typing, Jump to bottom) or a real reset (a
/// reattach or a resize replaying the mirror). The controller asks
/// `target(...)` once per display frame, after layout, and sets the offset
/// only when it differs; no other code sets it.
public struct TerminalScrollModel: Equatable, Sendable {
    public struct Anchor: Equatable, Sendable {
        /// The absolute row at the top edge of the scroll view's bounds.
        public var row: Int
        /// The offset's remainder below that row's top (points).
        public var delta: CGFloat
    }

    public enum State: Equatable, Sendable {
        case following
        case reading(Anchor)
        case interacting(startedFollowing: Bool)
    }

    /// Within this many rows of the bottom, a release or a deceleration's
    /// end follows again.
    public static let followSlackRows: CGFloat = 2

    public private(set) var state: State = .following
    /// The gesture reached the bottom edge (a fling into the bottom while
    /// output streams ends a few rows short of the newest end).
    private var touchedBottom = false
    /// Rows of slack after the gesture touched the bottom.
    public static let touchedBottomSlackRows: CGFloat = 8

    public init() {}

    public var isFollowing: Bool { state == .following }
    public var isInteracting: Bool { if case .interacting = state { true } else { false } }

    // MARK: Input

    /// A finger came down on the page (a drag begins).
    public mutating func began() {
        touchedBottom = false
        state = .interacting(startedFollowing: isFollowing || (isInteracting && startedFollowing))
    }

    private var startedFollowing: Bool {
        if case .interacting(let following) = state { following } else { false }
    }

    /// The page moved under a finger or a deceleration.
    public mutating func scrolled(offsetY: CGFloat, bottomOffsetY: CGFloat) {
        guard isInteracting, offsetY >= bottomOffsetY - 0.5 else { return }
        touchedBottom = true
    }

    /// The finger lifted with no deceleration, or a deceleration ended: rest
    /// here. Within `followSlackRows` of the bottom, follow.
    public mutating func settled(offsetY: CGFloat, bottomOffsetY: CGFloat, layout: TerminalDocumentLayout?, rowHeight: CGFloat) {
        guard let layout, rowHeight > 0 else { state = .following; return }
        let slack = (touchedBottom ? Self.touchedBottomSlackRows : Self.followSlackRows) * rowHeight
        touchedBottom = false
        if offsetY >= bottomOffsetY - slack {
            state = .following
        } else {
            state = .reading(Self.anchor(offsetY: offsetY, layout: layout, rowHeight: rowHeight))
        }
    }

    /// Typing, a paste, the key bar: back to the prompt, like Terminal.
    public mutating func input() { state = .following }

    /// Jump to bottom.
    public mutating func jumpToBottom() { state = .following }

    /// The mirror was reset and replayed (reattach, resize) or the scrollback
    /// was cleared: the rows being read are gone.
    public mutating func reset() { state = .following }

    /// The keyboard follows the finger in a drag that began at the prompt
    /// (M6): the prompt rides the composer for the rest of the gesture.
    public mutating func keyboardDragPinned() { state = .interacting(startedFollowing: true) }

    // MARK: Output

    /// The offset to show now, or nil to leave it alone (a finger or a
    /// deceleration owns it).
    public func target(layout: TerminalDocumentLayout?, rowHeight: CGFloat, topInset: CGFloat,
                       bottomOffsetY: CGFloat) -> CGFloat? {
        switch state {
        case .following:
            return bottomOffsetY
        case .interacting:
            return nil
        case .reading(let anchor):
            guard let layout, rowHeight > 0 else { return nil }
            let y = layout.contentY(ofRow: anchor.row, cellHeight: rowHeight) + anchor.delta
            return min(max(-topInset, y), bottomOffsetY)
        }
    }

    static func anchor(offsetY: CGFloat, layout: TerminalDocumentLayout, rowHeight: CGFloat) -> Anchor {
        let row = layout.row(atContentY: offsetY, cellHeight: rowHeight)
        return Anchor(row: row, delta: offsetY - layout.contentY(ofRow: row, cellHeight: rowHeight))
    }
}
