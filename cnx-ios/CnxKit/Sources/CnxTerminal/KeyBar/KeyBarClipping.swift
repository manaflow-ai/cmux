import CoreGraphics

/// Which keys of the key bar's scrolling middle row are really on screen.
///
/// The middle row scrolls under the pinned esc / ctrl / alt group and the
/// joystick. A key scrolled under them is clipped from view, but its
/// accessibility frame stays where it was: activating "Left Arrow" by its
/// frame landed on ctrl. An activation lands on the frame's center, so a key
/// whose center is outside the row's visible bounds is hidden from
/// accessibility and offered as an action on the row instead. A key cut at
/// an edge but with its center showing stays (tapping its center hits it).
public struct KeyBarClipping: Sendable {
    public init() {}

    /// Whether `key`'s activation point (its center) is inside `visible`,
    /// the scroll view's visible bounds in the same coordinate space.
    public func isActivatable(_ key: CGRect, in visible: CGRect?) -> Bool {
        guard let visible else { return true }
        guard visible.width > 0, key.width > 0 else { return false }
        return key.midX > visible.minX && key.midX < visible.maxX
    }

    /// Whether all of `key` is inside `visible`. At rest the row shows only
    /// whole keys: a key the edge cuts is not drawn (no sliver, R2-4).
    public func isWhole(_ key: CGRect, in visible: CGRect?) -> Bool {
        guard let visible else { return true }
        return key.minX >= visible.minX - 0.5 && key.maxX <= visible.maxX + 0.5
    }
}

/// The key bar scroller's edge fades (SPEC B2): 12 pt gradient masks, the
/// leading one only once the row is scrolled (at rest the first key starts
/// at a hard edge), the trailing one while more keys wait to the right.
public struct KeyBarScrollEdges: Equatable, Sendable {
    public static let fade: CGFloat = 12
    /// The trailing fade, 12 pt as specified (R2-4). It shows only while the
    /// row moves: at rest the row draws whole keys only, so the last one is
    /// at full brightness.
    public static let trailingFade: CGFloat = 12

    public var offset: CGFloat
    public var contentWidth: CGFloat
    public var visibleWidth: CGFloat

    public init(offset: CGFloat = 0, contentWidth: CGFloat = 0, visibleWidth: CGFloat = 0) {
        self.offset = offset
        self.contentWidth = contentWidth
        self.visibleWidth = visibleWidth
    }

    public var fadesLeading: Bool { offset > 0.5 }
    public var fadesTrailing: Bool { offset + visibleWidth < contentWidth - 0.5 }
}

/// One rule for when the key bar shows (SPEC M4), in mock and live alike:
/// whenever the terminal or its composer has focus, with the soft keyboard
/// or a hardware keyboard (esc, ctrl, ^C and the arrows matter most on a
/// hardware keyboard without them); never at rest.
public struct KeyBarVisibility: Equatable, Sendable {
    /// The soft keyboard as its notifications last described it.
    public enum SoftKeyboard: Equatable, Sendable {
        /// Not on screen (or a hardware keyboard replaced it).
        case none
        /// On screen, docked at the bottom.
        case shown
        /// Going away (it will-hide; the interactive dismissal ended).
        case hiding
    }

    public enum Mode: Equatable, Sendable {
        /// Folded away: the composer sits alone above the toolbar.
        case hidden
        /// 44 pt, clipped to the keyboard's height so it rides the keyboard's
        /// own animation and interactive dismissal.
        case followsKeyboard
        /// 44 pt above the composer's resting line: focus with no soft keyboard.
        case pinned
    }

    public var inputFocused = false
    public var softKeyboard: SoftKeyboard = .none

    public init(inputFocused: Bool = false, softKeyboard: SoftKeyboard = .none) {
        self.inputFocused = inputFocused
        self.softKeyboard = softKeyboard
    }

    public var mode: Mode {
        guard inputFocused else { return .hidden }
        return softKeyboard == .none ? .pinned : .followsKeyboard
    }

    /// A will-show or will-change-frame notification's end frame height (pt
    /// on screen): a frame under 100 pt is a hardware keyboard's bar or none.
    public mutating func keyboardWillShow(visibleHeight: CGFloat) {
        softKeyboard = visibleHeight >= 100 ? .shown : .none
    }

    public mutating func keyboardWillHide() {
        if softKeyboard == .shown { softKeyboard = .hiding }
    }

    /// The keyboard finished hiding; focus that outlives it is typing on a
    /// hardware keyboard.
    public mutating func keyboardDidHide() {
        softKeyboard = .none
    }
}

/// The key bar scroller's geometry (round 5, R3-5): its keys share one width
/// and the scroller is a whole number of them with 6 pt gaps, so a snapped
/// row always shows whole keys, evenly spaced, with nothing left over.
public struct KeyBarLayout: Sendable {
    public static let keyWidth: CGFloat = 44
    public static let spacing: CGFloat = 6

    public init() {}

    /// Keys that fit in `available` points.
    public func visibleKeys(available: CGFloat) -> Int {
        max(1, Int(floor((available + Self.spacing) / (Self.keyWidth + Self.spacing))))
    }

    /// The scroller's width for `available` points: a whole number of keys.
    public func scrollerWidth(available: CGFloat) -> CGFloat {
        guard available > 0 else { return 0 }
        let keys = CGFloat(visibleKeys(available: available))
        return min(available, keys * Self.keyWidth + (keys - 1) * Self.spacing)
    }
}
