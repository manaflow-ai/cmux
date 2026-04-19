import Foundation

/// Line ending character to use when inserting a line break in the text view.
public enum LineEnding: String, CaseIterable {
    /// Unix (LF) line endings.
    ///
    /// Uses the `\n` character.
    case lf
    /// Windows (CRLF) line endings.
    ///
    /// Uses the `\r\n` character.
    case crlf
    /// Mac (CR) line endings.
    ///
    /// Uses the `\r` character.
    case cr

    public var symbol: String {
        switch self {
        case .cr:
            return Symbol.carriageReturn
        case .lf:
            return Symbol.lineFeed
        case .crlf:
            return Symbol.carriageReturnLineFeed
        }
    }

    init?(symbol: String) {
        if symbol == Self.cr.symbol {
            self = .cr
        } else if symbol == Self.lf.symbol {
            self = .lf
        } else if symbol == Self.crlf.symbol {
            self = .crlf
        } else {
            return nil
        }
    }
}
