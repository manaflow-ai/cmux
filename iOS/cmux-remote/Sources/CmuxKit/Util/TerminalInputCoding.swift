import Foundation

/// Multi-line paste sanitiser. Strips iOS smart-quote substitutions,
/// normalises CRLF→LF, and surfaces a flag for unusually large or
/// multi-line payloads so callers can prompt the user before sending.
public enum SmartPasteSanitiser {
    public struct Result: Sendable {
        public let cleaned: String
        public let didStripSmartQuotes: Bool
        public let didNormaliseNewlines: Bool
        public let isMultiLine: Bool
    }

    public static func sanitise(_ raw: String) -> Result {
        var s = raw
        var stripped = false
        let replacements: [(String, String)] = [
            ("\u{201C}", "\""), ("\u{201D}", "\""),
            ("\u{2018}", "'"), ("\u{2019}", "'"),
            ("\u{2013}", "-"), ("\u{2014}", "--"),
            ("\u{2026}", "..."),
            ("\u{00A0}", " ")
        ]
        for (lhs, rhs) in replacements {
            if s.contains(lhs) {
                s = s.replacingOccurrences(of: lhs, with: rhs)
                stripped = true
            }
        }
        let beforeLineCount = s.split(separator: "\n").count
        let normalisedNewlines = s.contains("\r\n") || s.contains("\r")
        s = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lineCount = s.split(separator: "\n").count
        return Result(
            cleaned: s,
            didStripSmartQuotes: stripped,
            didNormaliseNewlines: normalisedNewlines,
            isMultiLine: lineCount > 1 || beforeLineCount > 1
        )
    }
}

/// Encodes a single character with optional Ctrl / Alt modifiers into the
/// wire-level bytes a remote PTY expects.
///   * Ctrl-A → 0x01, Ctrl-Z → 0x1A, Ctrl-[ → 0x1B, Ctrl-\ → 0x1C, etc.
///   * Alt → prepend ESC (0x1B) to the resulting byte(s).
public enum ModifierEncoder {
    public static func encode(
        character: Character,
        ctrl: Bool,
        alt: Bool
    ) -> String {
        guard let scalar = character.unicodeScalars.first else { return "" }
        var ch = scalar.value
        if ctrl {
            let upperString = String(scalar).uppercased()
            let upperValue = upperString.unicodeScalars.first?.value ?? scalar.value
            if upperValue >= 64 && upperValue <= 95 {
                ch = upperValue - 64
            } else if upperValue >= 96 && upperValue <= 122 {
                ch = upperValue - 96
            }
        }
        guard let encodedScalar = UnicodeScalar(ch) else { return "" }
        let body = String(encodedScalar)
        return alt ? "\u{001B}" + body : body
    }
}
