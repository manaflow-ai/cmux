public import CmuxBrowserStream
public import CmuxRemoteDesktop

/// The modifier bar's control, option, command and shift (c3-rd.md 3): a
/// tapped modifier applies to the next key and then lifts; a locked one
/// stays down until tapped again.
public struct ModifierLatch: Hashable, Sendable {
    public enum Modifier: CaseIterable, Hashable, Sendable {
        case control, option, command, shift

        public var usage: HidUsage {
            switch self {
            case .control: .leftControl
            case .option: .leftOption
            case .command: .leftCommand
            case .shift: .leftShift
            }
        }
    }

    public private(set) var latched: Set<Modifier> = []
    public private(set) var locked: Set<Modifier> = []

    public init() {}

    /// Tap: off -> latched (next key) -> locked -> off.
    public mutating func toggle(_ modifier: Modifier) {
        if locked.contains(modifier) {
            locked.remove(modifier)
        } else if latched.contains(modifier) {
            latched.remove(modifier)
            locked.insert(modifier)
        } else {
            latched.insert(modifier)
        }
    }

    public var active: Set<Modifier> { latched.union(locked) }

    /// A key press with the active modifiers held around it; latched ones lift after.
    public mutating func press(_ usage: HidUsage) -> [RdInputEvent] {
        let held = Modifier.allCases.filter(active.contains)
        var out = held.map { RdInputEvent.key(usage: $0.usage.rawValue, down: true) }
        out.append(.key(usage: usage.rawValue, down: true))
        out.append(.key(usage: usage.rawValue, down: false))
        out += held.reversed().map { RdInputEvent.key(usage: $0.usage.rawValue, down: false) }
        latched.removeAll()
        return out
    }

    /// Typed text. With a modifier active, each letter becomes a chord
    /// (control-c), else the text goes as committed text.
    public mutating func type(_ text: String) -> [RdInputEvent] {
        if text == "\n" { return press(.returnKey) }
        if text == "\t" { return press(.tab) }
        guard !active.isEmpty else { return [.text(text)] }
        var out: [RdInputEvent] = []
        for character in text {
            if let usage = HidUsage.key(for: character) {
                out += press(usage)
            } else {
                out.append(.text(String(character)))
            }
        }
        latched.removeAll()
        return out
    }
}
