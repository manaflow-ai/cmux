import Foundation
import Synchronization

/// What the host posts to the Worker (`POST /v1/hosts/:id/events`) for a
/// push alert. Field names are the Worker's (snake_case).
public struct AttentionEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case question, permission, done, error, notice

        /// Kinds that answer the same moment share a class for dedupe (an
        /// agent turning `blocked` and its "needs your input" notification).
        var dedupeClass: String {
            switch self {
            case .question, .permission: "attention"
            default: rawValue
            }
        }
    }

    public var id: String
    public var kind: Kind
    public var title: String
    public var body: String
    public var surface: Int?
    public var workspace: String?
    public var agent: String?
    public var options: [AttentionOption]
    public var quote: String?
    /// Unix milliseconds.
    public var createdAt: Double

    public init(id: String, kind: Kind, title: String, body: String, surface: Int?, workspace: String? = nil,
                agent: String? = nil, options: [AttentionOption] = [], quote: String? = nil, createdAt: Double) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.surface = surface
        self.workspace = workspace
        self.agent = agent
        self.options = options
        self.quote = quote
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, title, body, surface, workspace, agent, options, quote
        case createdAt = "created_at"
    }
}

public struct AttentionOption: Codable, Equatable, Sendable {
    public var key: String
    public var label: String
    public init(key: String, label: String) {
        self.key = key
        self.label = label
    }
}

/// A Live Activity update (`kind: "activity"`).
public struct ActivityUpdate: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case working, needsInput = "needs_input", done }
    public var kind = "activity"
    public var state: State
    public var surface: Int
    public var agent: String?
    public var workspace: String?
    /// Unix milliseconds when the agent started working.
    public var startedAt: Double
    public var detail: String?

    public init(state: State, surface: Int, agent: String?, workspace: String?, startedAt: Double, detail: String? = nil) {
        self.state = state
        self.surface = surface
        self.agent = agent
        self.workspace = workspace
        self.startedAt = startedAt
        self.detail = detail
    }

    enum CodingKeys: String, CodingKey {
        case kind, state, surface, agent, workspace, detail
        case startedAt = "started_at"
    }
}

/// Drops repeats before they become pushes:
/// - the same event id twice (daemon replays after a reconnect);
/// - a second event of the same class for the same surface within `window`
///   (an agent turning `blocked` and its notification);
/// - the same title and body for the same surface within `repeatWindow`.
public struct AttentionDeduper: Sendable {
    public var window: TimeInterval
    public var repeatWindow: TimeInterval
    private var seenIDs: [String] = []
    private var seenSet: Set<String> = []
    private var lastBySurfaceClass: [String: TimeInterval] = [:]
    private var lastByFingerprint: [String: TimeInterval] = [:]

    public init(window: TimeInterval = 10, repeatWindow: TimeInterval = 120) {
        self.window = window
        self.repeatWindow = repeatWindow
    }

    /// True when `event` should be posted; records it either way it passes.
    public mutating func admit(_ event: AttentionEvent, now: TimeInterval) -> Bool {
        if seenSet.contains(event.id) { return false }
        let surface = event.surface.map(String.init) ?? "-"
        let classKey = "\(surface)|\(event.kind.dedupeClass)"
        if let last = lastBySurfaceClass[classKey], now - last < window { remember(event.id); return false }
        let fingerprint = "\(surface)|\(event.title)|\(event.body)"
        if let last = lastByFingerprint[fingerprint], now - last < repeatWindow { remember(event.id); return false }
        remember(event.id)
        lastBySurfaceClass[classKey] = now
        lastByFingerprint[fingerprint] = now
        prune(now: now)
        return true
    }

    /// Marks an id as handled without posting (e.g. a phone was watching).
    public mutating func markSeen(_ id: String) { remember(id) }

    private mutating func remember(_ id: String) {
        guard seenSet.insert(id).inserted else { return }
        seenIDs.append(id)
        if seenIDs.count > 512 { seenSet.remove(seenIDs.removeFirst()) }
    }

    private mutating func prune(now: TimeInterval) {
        if lastBySurfaceClass.count > 256 { lastBySurfaceClass = lastBySurfaceClass.filter { now - $0.value < window } }
        if lastByFingerprint.count > 256 { lastByFingerprint = lastByFingerprint.filter { now - $0.value < repeatWindow } }
    }
}

/// Phones that said they are showing cmux (`presence.set {visible}` on `svc`).
public final class PresenceBoard: Sendable {
    private let visible = Mutex<Set<String>>([])

    public init() {}

    public func set(peer: String, visible isVisible: Bool) {
        visible.withLock { if isVisible { $0.insert(peer) } else { $0.remove(peer) } }
    }

    public func clear(peer: String) { _ = visible.withLock { $0.remove(peer) } }

    public var anyVisible: Bool { visible.withLock { !$0.isEmpty } }
}

/// Maps daemon notifications to feed kinds (same rules as the phone's feed).
public enum AttentionClassifier {
    public static func kind(title: String, subtitle: String?, body: String, level: String?) -> AttentionEvent.Kind {
        if level == "error" { return .error }
        let text = [title, subtitle ?? "", body].joined(separator: " ").lowercased()
        if text.contains("permission") || text.contains("approve") || text.contains("allow") { return .permission }
        if text.contains("?") || text.contains("waiting for your input") || text.contains("needs your") { return .question }
        if text.contains("done") || text.contains("finished") || text.contains("complete") { return .done }
        return .notice
    }

    public static func agentName(in title: String) -> String? {
        let lower = title.lowercased()
        for name in ["claude", "codex", "gemini", "grok", "cursor", "opencode", "amp"] where lower.contains(name) { return name }
        return nil
    }

    public static func displayName(_ agent: String?) -> String {
        guard let agent, !agent.isEmpty else { return "Agent" }
        switch agent.lowercased() {
        case "claude": return "Claude"
        case "codex": return "Codex"
        case "gemini": return "Gemini"
        case "opencode": return "OpenCode"
        default: return agent.prefix(1).uppercased() + agent.dropFirst()
        }
    }
}

/// Reads an agent TUI's plain text for the last prompt, the last reply and
/// an open numbered menu (a trimmed port of the phone's `FeedTextParser`).
public enum TerminalTextParser {
    public struct Result: Equatable, Sendable {
        public var lastPrompt: String?
        public var lastReply: String?
        public var options: [AttentionOption]
    }

    private static let promptMarkers: Set<Character> = [">", "❯", "›"]
    private static let replyMarkers: Set<Character> = ["⏺", "•", "✦", "●"]
    private static let boxCharacters = CharacterSet(charactersIn: "│┃|╭╮╰╯─━")

    public static func parse(_ text: String) -> Result {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { strip(String($0)) }
        var prompt: String?
        var reply: String?
        var index = 0
        while index < lines.count {
            let line = lines[index]
            guard let first = line.first else { index += 1; continue }
            if promptMarkers.contains(first), option(in: line) == nil {
                let body = line.dropFirst().trimmingCharacters(in: .whitespaces)
                if !body.isEmpty, !body.hasPrefix("Try \"") { prompt = String(body.prefix(400)) }
            } else if replyMarkers.contains(first) {
                var block = [line.dropFirst().trimmingCharacters(in: .whitespaces)]
                var next = index + 1
                while next < lines.count, rawIndent(text: lines, at: next) { block.append(lines[next]); next += 1 }
                let joined = block.joined(separator: " ").trimmingCharacters(in: .whitespaces)
                if !joined.isEmpty, !isToolLine(joined) { reply = String(joined.prefix(600)) }
                index = next
                continue
            }
            index += 1
        }
        return Result(lastPrompt: prompt, lastReply: reply, options: options(in: Array(lines.suffix(30))))
    }

    /// The last run of `1. … 2. …` lines (a cursor `❯` may lead a line).
    public static func options(in lines: [String]) -> [AttentionOption] {
        var best: [AttentionOption] = []
        var current: [AttentionOption] = []
        for line in lines {
            if let o = option(in: line), Int(o.key) == current.count + 1 {
                current.append(o)
            } else if let o = option(in: line), o.key == "1" {
                current = [o]
            } else if !line.isEmpty, !current.isEmpty, option(in: line) == nil, current.count >= 2 {
                best = current
                current = []
            }
        }
        if current.count >= 2 { best = current }
        return Array(best.prefix(6))
    }

    static func option(in line: String) -> AttentionOption? {
        var s = Substring(line)
        if let first = s.first, promptMarkers.contains(first) { s = s.dropFirst().drop { $0 == " " } }
        let digits = s.prefix { $0.isNumber }
        guard (1...2).contains(digits.count) else { return nil }
        var rest = s.dropFirst(digits.count)
        guard let punct = rest.first, punct == "." || punct == ")" else { return nil }
        rest = rest.dropFirst()
        guard rest.first == " " else { return nil }
        let label = rest.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return nil }
        return AttentionOption(key: String(digits), label: String(label.prefix(80)))
    }

    private static func strip(_ line: String) -> String {
        line.trimmingCharacters(in: boxCharacters.union(.whitespaces))
    }

    /// A continuation of a reply block is a non-empty line that is not a new marker.
    private static func rawIndent(text lines: [String], at index: Int) -> Bool {
        let line = lines[index]
        guard let first = line.first else { return false }
        return !promptMarkers.contains(first) && !replyMarkers.contains(first) && option(in: line) == nil
    }

    private static func isToolLine(_ s: String) -> Bool {
        let tools = ["Read(", "Edit(", "Write(", "Bash(", "Update(", "Search(", "Grep(", "Glob(", "List(", "Ran ", "Explored", "Edited "]
        return tools.contains { s.hasPrefix($0) }
    }
}
