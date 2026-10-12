import Foundation

/// Reads an agent TUI's plain text (Claude Code, Codex, Gemini, OpenCode) to
/// find the last prompt the user typed, the agent's last reply, and the
/// numbered choices of an open question or permission menu.
enum FeedTextParser {
    struct Result: Equatable {
        var lastPrompt: String?
        var lastReply: String?
        var options: [FeedOption]
    }

    /// Prompt markers: Claude Code `>`/`❯`, Codex `›`.
    private static let promptMarkers: [Character] = [">", "❯", "›"]
    /// Reply markers: Claude Code `⏺`, Codex `•`, Gemini `✦`.
    private static let replyMarkers: [Character] = ["⏺", "•", "✦", "●"]

    static func parse(_ text: String) -> Result {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { stripBox(String($0)) }
        var lastPrompt: String?
        var lastReply: String?
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let first = trimmed.first, promptMarkers.contains(first), !isMenuLine(trimmed) {
                let body = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                var block = [body]
                var next = index + 1
                while next < lines.count, isContinuation(lines[next]) {
                    block.append(lines[next].trimmingCharacters(in: .whitespaces))
                    next += 1
                }
                // The TUI wraps the prompt at its width; rejoin as one text.
                let joined = block.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                if !joined.isEmpty, !isPlaceholder(joined) { lastPrompt = joined }
                index = next
                continue
            }
            if let first = trimmed.first, replyMarkers.contains(first) {
                var block = [trimmed.dropFirst().trimmingCharacters(in: .whitespaces)]
                var next = index + 1
                while next < lines.count, isContinuation(lines[next]) {
                    block.append(lines[next].trimmingCharacters(in: .whitespaces))
                    next += 1
                }
                let joined = block.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !joined.isEmpty, !isToolLine(joined) { lastReply = String(joined.prefix(2000)) }
                index = next
                continue
            }
            index += 1
        }
        let tail = lines.suffix(30).joined(separator: "\n")
        return Result(lastPrompt: lastPrompt, lastReply: lastReply, options: options(in: tail))
    }

    /// `1. Yes` / `❯ 2. No, and tell Claude…` lines near the end.
    static func options(in text: String) -> [FeedOption] {
        var found: [FeedOption] = []
        let pattern = #"^\s*[│|]?\s*[❯›>]?\s*(\d{1,2})[.)]\s+(.+?)\s*[│|]?\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            guard let keyRange = Range(match.range(at: 1), in: text), let labelRange = Range(match.range(at: 2), in: text) else { continue }
            let option = FeedOption(key: String(text[keyRange]), label: String(text[labelRange]))
            if option.key == "1" { found = [] }
            if !found.contains(where: { $0.key == option.key }) { found.append(option) }
        }
        // A menu is at least two consecutive choices starting at 1.
        return found.count >= 2 && found.first?.key == "1" ? found : []
    }

    private static func isMenuLine(_ line: String) -> Bool {
        line.range(of: #"^[❯›>]\s*\d{1,2}[.)]\s"#, options: .regularExpression) != nil
    }

    private static func isContinuation(_ line: String) -> Bool {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return line.hasPrefix("  ") && !(line.trimmingCharacters(in: .whitespaces).first.map { replyMarkers.contains($0) || promptMarkers.contains($0) } ?? false)
    }

    private static func isPlaceholder(_ text: String) -> Bool {
        text.hasPrefix("Try \"") || text.hasPrefix("Type") || text == "?" || text.count < 2
    }

    private static func isToolLine(_ text: String) -> Bool {
        text.range(of: #"^(Bash|Read|Edit|Write|Update|Search|Grep|Glob|Task|Fetch|Ran|Explored|Edited)\b"#, options: .regularExpression) != nil
    }

    /// Removes box-drawing borders from TUI frames.
    private static func stripBox(_ line: String) -> String {
        var line = line
        while let first = line.first, "│┃╭╰".contains(first) { line.removeFirst() }
        while let last = line.last, "│┃╮╯".contains(last) { line.removeLast() }
        return line
    }
}
