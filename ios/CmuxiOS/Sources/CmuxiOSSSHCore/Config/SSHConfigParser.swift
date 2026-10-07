import Foundation

/// Reads the subset of OpenSSH client config a phone host needs: `Host`,
/// `HostName`, `Port`, `User` and `ProxyJump`.
///
/// Follows OpenSSH where it matters for a paste: keywords are
/// case-insensitive, `keyword value` and `keyword=value` both work, values
/// may be double-quoted, `#` starts a comment, and for each host the first
/// value obtained for a keyword wins, walking every block whose patterns
/// match it in file order (so `Host *` at the end fills defaults and at the
/// top overrides). Patterns with `*`, `?` or `!` name no host of their own.
/// `Match`, `Include` and every other keyword are ignored.
public struct SSHConfigParser: Sendable {
    public init() {}

    public func parse(_ text: String) -> [SSHConfigEntry] {
        // Lines before the first Host apply to every host.
        var blocks: [SSHConfigBlock] = [SSHConfigBlock(patterns: ["*"])]
        var inMatch = false
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            guard let (keyword, values) = Self.tokenize(String(rawLine)) else { continue }
            switch keyword {
            case "host":
                inMatch = false
                blocks.append(SSHConfigBlock(patterns: values))
            case "match":
                inMatch = true
            default:
                guard !inMatch, let value = values.first else { continue }
                blocks[blocks.count - 1].lines.append((keyword, value))
            }
        }

        var entries: [SSHConfigEntry] = []
        var seen = Set<String>()
        for block in blocks {
            for alias in block.patterns where Self.isConcrete(alias) && seen.insert(alias.lowercased()).inserted {
                entries.append(resolve(alias, in: blocks))
            }
        }
        return entries
    }

    private func resolve(_ alias: String, in blocks: [SSHConfigBlock]) -> SSHConfigEntry {
        var values: [String: String] = [:]
        for block in blocks where block.matches(alias) {
            for (keyword, value) in block.lines where values[keyword] == nil {
                values[keyword] = value
            }
        }
        let jump = values["proxyjump"].flatMap { value -> String? in
            // Only the first hop of a chain; `none` disables the jump.
            let first = value.split(separator: ",").first.map(String.init) ?? value
            return first.lowercased() == "none" ? nil : first
        }
        return SSHConfigEntry(
            alias: alias,
            hostName: values["hostname"].map { $0.replacingOccurrences(of: "%h", with: alias) } ?? alias,
            port: values["port"].flatMap(UInt16.init).flatMap { $0 == 0 ? nil : $0 },
            user: values["user"],
            proxyJump: jump
        )
    }

    /// A pattern that names one host (no wildcard or negation).
    static func isConcrete(_ pattern: String) -> Bool {
        !pattern.isEmpty && !pattern.contains(where: { "*?!".contains($0) })
    }

    /// Splits a line into a lowercased keyword and its values, or nil for a
    /// blank or comment line.
    static func tokenize(_ line: String) -> (String, [String])? {
        var words: [String] = []
        var word = ""
        var quoted = false
        var hasWord = false
        var sawEquals = false
        func endWord() {
            if hasWord { words.append(word) }
            word = ""
            hasWord = false
        }
        for character in line {
            if character == "\"" {
                quoted.toggle()
                hasWord = true
            } else if quoted {
                word.append(character)
            } else if character == "#" {
                break
            } else if character == "=" && !sawEquals && ((words.isEmpty && hasWord) || (words.count == 1 && !hasWord)) {
                // The first `=` may separate the keyword from its value.
                sawEquals = true
                endWord()
            } else if character.isWhitespace {
                endWord()
            } else {
                word.append(character)
                hasWord = true
            }
        }
        endWord()
        guard let keyword = words.first else { return nil }
        return (keyword.lowercased(), Array(words.dropFirst()))
    }
}
