import Foundation

/// The key bar's Ctrl and Alt (ghostty-next section 5): a tap arms the
/// modifier for the next key from either keyboard, a second tap within
/// `doubleTapInterval` locks it until it is tapped again, and a tap on an
/// armed modifier after that interval turns it off. Client view state of one
/// terminal view; the owner never sees it.
public struct TerminalStickyModifiers: Equatable, Sendable {
    public enum Modifier: Sendable, CaseIterable { case control, alternate }
    public enum State: Equatable, Sendable { case off, armed(at: TimeInterval), locked }

    /// The longest gap between two taps that locks a modifier.
    public static let doubleTapInterval: TimeInterval = 0.4

    public private(set) var control: State = .off
    public private(set) var alternate: State = .off

    public init() {}

    public func state(_ modifier: Modifier) -> State {
        modifier == .control ? control : alternate
    }

    /// True while the modifier applies to the next key.
    public func isActive(_ modifier: Modifier) -> Bool {
        state(modifier) != .off
    }

    /// A tap on the modifier's key at `time` (seconds, any monotonic clock).
    public mutating func tap(_ modifier: Modifier, at time: TimeInterval) {
        let next: State = switch state(modifier) {
        case .off: .armed(at: time)
        case .armed(let armedAt): time - armedAt <= Self.doubleTapInterval ? .locked : .off
        case .locked: .off
        }
        set(modifier, next)
    }

    /// The modifiers for the key being sent now; armed ones turn off, locked ones stay.
    public mutating func consume() -> (control: Bool, alternate: Bool) {
        let used = (control: isActive(.control), alternate: isActive(.alternate))
        for modifier in Modifier.allCases {
            if case .armed = state(modifier) { set(modifier, .off) }
        }
        return used
    }

    /// Turns every modifier off (the keyboard hid, the terminal lost focus).
    public mutating func reset() {
        control = .off
        alternate = .off
    }

    private mutating func set(_ modifier: Modifier, _ state: State) {
        if modifier == .control { control = state } else { alternate = state }
    }
}
