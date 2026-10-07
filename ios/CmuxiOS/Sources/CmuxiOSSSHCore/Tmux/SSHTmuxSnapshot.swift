import Foundation

/// The host's visible grid and input modes, replayed after every attach or
/// layout change. History and multi-pane layout need a richer renderer seam.
struct SSHTmuxSnapshot: Sendable {
    static let fields = [
        "pane_id", "pane_width", "pane_height", "cursor_x", "cursor_y", "alternate_on",
        "scroll_region_upper", "scroll_region_lower", "cursor_flag", "keypad_cursor_flag",
        "keypad_flag", "insert_flag", "wrap_flag", "origin_flag", "bracket_paste_flag",
        "mouse_standard_flag", "mouse_button_flag", "mouse_any_flag", "mouse_sgr_flag", "mouse_utf8_flag",
    ]
    static let format = fields.map { "#{\($0)}" }.joined(separator: " ")

    static func replay(lines: [Data], metadata: [Data], pane: String, cols: Int, rows: Int) throws -> Data {
        guard metadata.count == 1 else { throw SSHSessionFailure.shellRejected }
        let fields = String(decoding: metadata[0], as: UTF8.self).split(separator: " ", omittingEmptySubsequences: false)
        guard fields.count == Self.fields.count, fields[0] == pane else { throw SSHSessionFailure.shellRejected }
        let values = fields.dropFirst().compactMap { Int($0) }
        guard values.count == Self.fields.count - 1, values[0] == cols, values[1] == rows,
              (0..<cols).contains(values[2]), (0..<rows).contains(values[3]),
              (0..<rows).contains(values[5]), (values[5]..<rows).contains(values[6]),
              ([values[4]] + Array(values[7...])).allSatisfy({ $0 == 0 || $0 == 1 }),
              lines.count <= rows else { throw SSHSessionFailure.shellRejected }
        var result = Data("\u{1b}c".utf8)
        if values[4] == 1 { result.append(Data("\u{1b}[?1049h".utf8)) }
        result.append(Data("\u{1b}[H".utf8))
        for (index, line) in lines.enumerated() {
            if index > 0 { result.append(Data("\r\n".utf8)) }
            result.append(try SSHTmuxControlDecoder.unescape(line, capture: true))
        }
        // Restore margins before origin mode and the cursor. Cursor positions
        // reported by tmux are absolute even while origin mode is enabled.
        var suffix = "\u{1b}[\(values[5] + 1);\(values[6] + 1)r"
        for (mode, index) in [(25, 7), (1, 8), (7, 11), (6, 12), (2004, 13),
                              (1000, 14), (1002, 15), (1003, 16), (1006, 17), (1005, 18)] {
            suffix += "\u{1b}[?\(mode)" + (values[index] == 1 ? "h" : "l")
        }
        suffix += values[9] == 1 ? "\u{1b}=" : "\u{1b}>"
        suffix += "\u{1b}[4" + (values[10] == 1 ? "h" : "l")
        let cursorRow = values[3] - (values[12] == 1 ? values[5] : 0)
        guard cursorRow >= 0 else { throw SSHSessionFailure.shellRejected }
        suffix += "\u{1b}[\(cursorRow + 1);\(min(values[2], cols - 1) + 1)H"
        result.append(Data(suffix.utf8))
        return result
    }
}
