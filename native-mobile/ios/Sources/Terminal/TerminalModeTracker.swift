import Foundation

/// Follows the DEC private modes that decide how the phone presents a
/// terminal: the alternate screen (1049/1047/47) means a full-screen TUI that
/// assumes its whole grid is visible; mouse tracking (1000/1002/1003) means
/// the app wants touches. The daemon has no field for either, so the phone
/// reads them from the byte stream it already mirrors (vt-state replay
/// included, which restores modes). Handles sequences split across chunks.
struct TerminalModeTracker: Sendable, Equatable {
    private(set) var alternateScreen = false
    private(set) var mouseTracking = false
    private(set) var bracketedPaste = false
    private var mouseModes: Set<Int> = []

    /// Bytes of an unfinished `ESC [ ? ...` sequence from the last chunk.
    private var carry: [UInt8] = []

    var isTUI: Bool { alternateScreen }

    /// Scans a chunk. Returns true when `isTUI` or `mouseTracking` changed.
    @discardableResult
    mutating func scan(_ data: Data) -> Bool {
        let before = (alternateScreen, mouseTracking)
        var bytes = carry
        bytes.append(contentsOf: data)
        carry.removeAll(keepingCapacity: true)
        var index = 0
        let count = bytes.count
        while index < count {
            guard bytes[index] == 0x1B else { index += 1; continue }
            // ESC c: full reset.
            if index + 1 < count, bytes[index + 1] == 0x63 {
                alternateScreen = false
                mouseModes.removeAll()
                mouseTracking = false
                bracketedPaste = false
                index += 2
                continue
            }
            guard index + 2 < count else { carry = Array(bytes[index...]); break }
            guard bytes[index + 1] == 0x5B, bytes[index + 2] == 0x3F else { index += 1; continue }
            // ESC [ ? params (h|l)
            var cursor = index + 3
            var params: [Int] = []
            var current = 0
            var hasDigit = false
            var final: UInt8?
            while cursor < count {
                let byte = bytes[cursor]
                if byte >= 0x30, byte <= 0x39 {
                    current = current &* 10 &+ Int(byte - 0x30)
                    hasDigit = true
                } else if byte == 0x3B {
                    params.append(hasDigit ? current : 0)
                    current = 0
                    hasDigit = false
                } else {
                    final = byte
                    break
                }
                cursor += 1
                if cursor - index > 64 { break }
            }
            guard let final else {
                if cursor >= count { carry = Array(bytes[index...]) }
                index = cursor
                continue
            }
            if hasDigit { params.append(current) }
            if final == 0x68 || final == 0x6C {
                apply(params, set: final == 0x68)
            }
            index = cursor + 1
        }
        if carry.count > 64 { carry.removeAll() }
        return before != (alternateScreen, mouseTracking)
    }

    private mutating func apply(_ params: [Int], set: Bool) {
        for mode in params {
            switch mode {
            case 47, 1047, 1049:
                alternateScreen = set
            case 1000, 1002, 1003:
                if set { mouseModes.insert(mode) } else { mouseModes.remove(mode) }
                mouseTracking = !mouseModes.isEmpty
            case 2004:
                bracketedPaste = set
            default:
                break
            }
        }
    }
}
