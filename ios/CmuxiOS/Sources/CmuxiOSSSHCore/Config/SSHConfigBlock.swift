import Foundation

/// One `Host` block of an SSH config: its patterns and its keyword lines in
/// order (keywords lowercased).
struct SSHConfigBlock {
    var patterns: [String]
    var lines: [(String, String)] = []

    init(patterns: [String]) {
        self.patterns = patterns
    }

    /// OpenSSH `Host` matching: some positive pattern matches and no
    /// negated (`!`) pattern does. Case-insensitive.
    func matches(_ host: String) -> Bool {
        var positive = false
        for pattern in patterns {
            if pattern.hasPrefix("!") {
                if Self.glob(String(pattern.dropFirst()), host) { return false }
            } else if Self.glob(pattern, host) {
                positive = true
            }
        }
        return positive
    }

    /// `*` matches any run, `?` one character.
    static func glob(_ pattern: String, _ text: String) -> Bool {
        let p = Array(pattern.lowercased())
        let t = Array(text.lowercased())
        var pi = 0, ti = 0
        var star = -1, mark = 0
        while ti < t.count {
            if pi < p.count, p[pi] == "?" || p[pi] == t[ti] {
                pi += 1
                ti += 1
            } else if pi < p.count, p[pi] == "*" {
                star = pi
                mark = ti
                pi += 1
            } else if star >= 0 {
                pi = star + 1
                mark += 1
                ti = mark
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}
