import Foundation

/// What a terminal session reports to the screen.
public enum TerminalSessionEvent: Sendable, Equatable {
    /// Bytes the program wrote (the PTY output, or the owner's mirrored stream).
    case output(Data)
    /// The program entered (true) or left (false) the alternate screen. The
    /// screen switches between native scrollback (false) and TUI mode (true).
    case alternateScreen(Bool)
    /// The window title the program set (OSC 0/2), or the program name.
    case title(String)
    /// The session ended.
    case exited(code: Int32)
}

/// One terminal on a Mac, as the phone sees it: bytes in, input out, resize and
/// the alternate screen flag. The mock replays scripted output; the link-backed
/// session (cnx-ffi `daemon` channel, terminal attach/input/resize) comes later.
@MainActor
public protocol TerminalSession: AnyObject {
    /// The program running in the foreground, for the composer placeholder ("Send to zsh").
    var programName: String { get }
    /// Whether the program is on the alternate screen now.
    var isAlternateScreen: Bool { get }
    /// Starts delivering events. Called once by the screen; events arrive on the main actor.
    func start(_ handler: @escaping @MainActor (TerminalSessionEvent) -> Void)
    /// Bytes for the PTY (keys encoded by Ghostty, composer text, paste).
    func send(_ bytes: Data)
    /// The screen's grid in cells: what a TUI should draw (rows between the
    /// toolbar and the composer with the keyboard down).
    func resize(columns: Int, rows: Int)
    /// Stops delivering events.
    func stop()
}

/// Follows DEC private modes 47, 1047 and 1049 in a byte stream, across chunk
/// boundaries. Sessions that only see bytes use it to derive `alternateScreen`.
public struct AlternateScreenDetector: Sendable {
    public private(set) var isActive = false
    private var pending: [UInt8] = []

    public init() {}

    /// Scans `bytes`; returns the new state when it changed in this chunk.
    public mutating func scan(_ bytes: Data) -> Bool? {
        let before = isActive
        var buffer = pending
        buffer.append(contentsOf: bytes)
        pending.removeAll(keepingCapacity: true)
        var index = 0
        while index < buffer.count {
            guard buffer[index] == 0x1B else { index += 1; continue }
            // ESC [ ? digits (; digits)* h|l
            var cursor = index + 1
            guard cursor < buffer.count else { pending = Array(buffer[index...]); break }
            guard buffer[cursor] == 0x5B else { index += 1; continue }
            cursor += 1
            guard cursor < buffer.count else { pending = Array(buffer[index...]); break }
            guard buffer[cursor] == 0x3F else { index += 1; continue }
            cursor += 1
            var params: [Int] = []
            var value = 0
            var hasDigit = false
            var complete = false
            while cursor < buffer.count, cursor - index < 32 {
                let byte = buffer[cursor]
                if byte >= 0x30, byte <= 0x39 {
                    value = value * 10 + Int(byte - 0x30)
                    hasDigit = true
                } else if byte == 0x3B {
                    params.append(value); value = 0; hasDigit = false
                } else {
                    if hasDigit { params.append(value) }
                    if byte == 0x68 || byte == 0x6C {
                        if params.contains(where: { $0 == 47 || $0 == 1047 || $0 == 1049 }) {
                            isActive = byte == 0x68
                        }
                    }
                    complete = true
                    break
                }
                cursor += 1
            }
            if !complete, cursor >= buffer.count, cursor - index < 32 {
                pending = Array(buffer[index...])
                break
            }
            index = cursor + 1
        }
        return isActive == before ? nil : isActive
    }
}
