import CNCore
import Foundation

// Turns the flat, upserted transcript into the rows the chat draws. A pure
// pass, after the Mac agent pane's `conversation/turns.ts`:
//
//   user prompt
//   "Worked for 1m 16s" disclosure holding the work before the final answer
//   the final answer
//   "Edited N files" card for the turn's edits
//   turn footer
//
// A turn that is still running shows its work as it happens under a
// "Thinking" (no output yet) or ticking "Working for 42s" line. Runs of two
// or more consecutive tool calls in a settled turn fold under one summary
// line ("Read 3 files, ran a command"). A pending permission is not drawn
// inline: the chat pins it above the composer until it is answered.

/// One drawn row. Ids are stable across updates so SwiftUI keeps identity.
enum ChatRow: Identifiable, Hashable, Sendable {
    case user(UserTranscriptItem, LocalSendState)
    case assistant(AssistantTranscriptItem, isFinal: Bool)
    case thought(ThoughtTranscriptItem)
    case tool(ToolCallTranscriptItem, settled: Bool)
    case toolGroup(id: String, tools: [ToolCallTranscriptItem], open: Bool)
    case plan(PlanTranscriptItem)
    case permission(PermissionTranscriptItem)
    case notice(NoticeTranscriptItem)
    case worked(id: String, label: String, open: Bool)
    case thinking(id: String)
    case working(id: String)
    case editedFiles(id: String, files: [EditedFile])
    case turnFooter(TurnEndTranscriptItem, copyText: String)
    case unknown(UnknownTranscriptItem)

    var id: String {
        switch self {
        case .user(let x, _): x.id
        case .assistant(let x, _): x.id
        case .thought(let x): x.id
        case .tool(let x, _): x.id
        case .toolGroup(let id, _, _): id
        case .plan(let x): x.id
        case .permission(let x): x.id
        case .notice(let x): x.id
        case .worked(let id, _, _): id
        case .thinking(let id): id
        case .working(let id): id
        case .editedFiles(let id, _): id
        case .turnFooter(let x, _): x.id
        case .unknown(let x): "unknown-\(x.id)"
        }
    }

    /// Vertical gap above this row, in points.
    var topSpacing: CGFloat {
        switch self {
        case .user: 28
        case .assistant: 12
        case .tool, .toolGroup: 2
        case .worked, .thinking, .working: 14
        case .turnFooter: 4
        case .permission, .notice: 10
        default: 12
        }
    }
}

/// Send state of a prompt the phone wrote before the host echoed it.
enum LocalSendState: Hashable, Sendable {
    case sent, sending, failed
}

/// One file in an "Edited N files" card: the turn's edits to it, oldest first.
struct EditedFile: Hashable, Sendable, Identifiable {
    var path: String
    var diffs: [FileDiff]
    var id: String { path }

    var counts: DiffCounts {
        diffs.reduce(DiffCounts()) { acc, d in
            let c = LineDiff.counts(old: d.oldText ?? "", new: d.newText)
            return DiffCounts(added: acc.added + c.added, removed: acc.removed + c.removed)
        }
    }
}

struct DiffCounts: Hashable, Sendable {
    var added = 0
    var removed = 0
}

struct TranscriptShaper: Sendable {
    /// Disclosure ids the user opened (or, under `expandAll`, every one).
    var expanded: Set<String>
    /// The last turn is still running (session `running` or `waiting`).
    var live: Bool
    /// Local send state per user item id.
    var sendStates: [String: LocalSendState] = [:]
    /// Debug/validation: open every disclosure.
    var expandAll = false

    func isOpen(_ id: String) -> Bool { expandAll || expanded.contains(id) }

    func rows(for items: [TranscriptItem]) -> [ChatRow] {
        var out: [ChatRow] = []
        var index = 0
        // Rows before the first prompt (a start notice) draw as they are.
        while index < items.count {
            if case .user = items[index] { break }
            out.append(contentsOf: plain(items[index], settled: true))
            index += 1
        }
        var turns: [(UserTranscriptItem, [TranscriptItem])] = []
        while index < items.count {
            guard case .user(let user) = items[index] else { index += 1; continue }
            index += 1
            var body: [TranscriptItem] = []
            while index < items.count {
                if case .user = items[index] { break }
                body.append(items[index])
                index += 1
            }
            turns.append((user, body))
        }
        for (at, turn) in turns.enumerated() {
            let last = at == turns.count - 1
            out.append(.user(turn.0, sendStates[turn.0.id] ?? .sent))
            out.append(contentsOf: shapeTurn(user: turn.0, body: turn.1, live: live && last))
        }
        return out
    }

    private func shapeTurn(user: UserTranscriptItem, body: [TranscriptItem], live: Bool) -> [ChatRow] {
        guard let end = body.firstIndex(where: { if case .turnEnd = $0 { true } else { false } }),
              case .turnEnd(let summary) = body[end] else {
            if live { return liveTurn(user: user, body: body) }
            return runs(body, settled: false)
        }
        let work = Array(body[..<end])
        let trailing = Array(body[(end + 1)...])
        let finalIndex = work.lastIndex { if case .assistant = $0 { true } else { false } }
        let answer: AssistantTranscriptItem? = finalIndex.flatMap { if case .assistant(let a) = work[$0] { a } else { nil } }
        let before = finalIndex.map { Array(work[..<$0]) } ?? work
        let after = finalIndex.map { Array(work[($0 + 1)...]) } ?? []

        var shaped: [ChatRow] = []
        if !before.isEmpty {
            let id = "worked-\(user.id)"
            let open = isOpen(id)
            shaped.append(.worked(id: id, label: workedLabel(summary), open: open))
            if open { shaped.append(contentsOf: runs(before, settled: true)) }
        }
        if let answer { shaped.append(.assistant(answer, isFinal: true)) }
        shaped.append(contentsOf: runs(after.filter { !isEdit($0) }, settled: true))
        let edits = (before + after).compactMap { item -> ToolCallTranscriptItem? in
            if case .tool(let t) = item, let d = t.diff, !d.isEmpty { t } else { nil }
        }
        if !edits.isEmpty {
            shaped.append(.editedFiles(id: "edited-\(user.id)", files: Self.editedFiles(edits)))
        }
        shaped.append(.turnFooter(summary, copyText: answer?.text ?? ""))
        shaped.append(contentsOf: trailing.flatMap { plain($0, settled: true) })
        return shaped
    }

    private func liveTurn(user: UserTranscriptItem, body: [TranscriptItem]) -> [ChatRow] {
        let hasOutput = body.contains { item in
            switch item {
            case .assistant, .thought, .tool, .plan: true
            default: false
            }
        }
        var shaped: [ChatRow] = [hasOutput ? .working(id: "working-\(user.id)") : .thinking(id: "thinking-\(user.id)")]
        // A live turn lists every call so its height and the reader's place
        // don't jump as each call starts and ends.
        shaped.append(contentsOf: body.flatMap { plain($0, settled: false) })
        return shaped
    }

    /// Items in order, with each run of two or more consecutive tool calls
    /// folded under one summary row.
    private func runs(_ items: [TranscriptItem], settled: Bool) -> [ChatRow] {
        var out: [ChatRow] = []
        var pending: [ToolCallTranscriptItem] = []
        func flush() {
            if pending.count >= 2 {
                let id = "group-\(pending[0].id)"
                let open = isOpen(id)
                out.append(.toolGroup(id: id, tools: pending, open: open))
                if open { out.append(contentsOf: pending.map { .tool($0, settled: settled) }) }
            } else {
                out.append(contentsOf: pending.map { .tool($0, settled: settled) })
            }
            pending.removeAll()
        }
        for item in items {
            if case .tool(let t) = item { pending.append(t); continue }
            flush()
            out.append(contentsOf: plain(item, settled: settled))
        }
        flush()
        return out
    }

    private func plain(_ item: TranscriptItem, settled: Bool) -> [ChatRow] {
        switch item {
        case .user(let x): [.user(x, sendStates[x.id] ?? .sent)]
        case .assistant(let x): [.assistant(x, isFinal: false)]
        case .thought(let x): [.thought(x)]
        case .tool(let x): [.tool(x, settled: settled)]
        case .plan(let x): [.plan(x)]
        case .permission(let x): x.resolved == nil ? [] : [.permission(x)]
        case .notice(let x): [.notice(x)]
        case .turnEnd(let x): [.turnFooter(x, copyText: "")]
        case .unknown(let x): [.unknown(x)]
        }
    }

    private func isEdit(_ item: TranscriptItem) -> Bool {
        if case .tool(let t) = item, let d = t.diff, !d.isEmpty { return true }
        return false
    }

    static func editedFiles(_ tools: [ToolCallTranscriptItem]) -> [EditedFile] {
        var order: [String] = []
        var byPath: [String: [FileDiff]] = [:]
        for tool in tools {
            for diff in tool.diff ?? [] {
                if byPath[diff.path] == nil { order.append(diff.path) }
                byPath[diff.path, default: []].append(diff)
            }
        }
        return order.map { EditedFile(path: $0, diffs: byPath[$0] ?? []) }
    }

    func workedLabel(_ summary: TurnEndTranscriptItem) -> String {
        let time = AgentFormat.duration(ms: summary.durationMs)
        switch summary.stopReason {
        case "cancelled": return summary.durationMs > 0 ? "Stopped after \(time)" : "Stopped"
        case "error": return summary.durationMs > 0 ? "Failed after \(time)" : "Failed"
        default: return "Worked for \(time)"
        }
    }
}

/// The pending permission the chat pins above the composer, with the call it
/// guards.
struct PendingPermission: Hashable, Sendable {
    var item: PermissionTranscriptItem
    var tool: ToolCallTranscriptItem?

    static func find(in items: [TranscriptItem]) -> PendingPermission? {
        for item in items.reversed() {
            guard case .permission(let p) = item, p.resolved == nil else { continue }
            let tool = items.lazy.compactMap { i -> ToolCallTranscriptItem? in
                if case .tool(let t) = i, t.id == p.toolCallId { t } else { nil }
            }.first
            return PendingPermission(item: p, tool: tool)
        }
        return nil
    }
}

enum AgentFormat {
    /// "1m 16s", "42s", "1h 3m"; zero units dropped, under one second is "0s".
    static func duration(ms: Int) -> String {
        let total = ms / 1000
        if total <= 0 { return "0s" }
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return [h > 0 ? "\(h)h" : nil, m > 0 ? "\(m)m" : nil, s > 0 ? "\(s)s" : nil].compactMap { $0 }.joined(separator: " ")
    }

    /// Compact list time: "now", "5m", "3h", "Yesterday", weekday, or date.
    static func relative(_ millis: EpochMillis, now: Date = Date(), calendar: Calendar = .current) -> String {
        let date = Date(epochMillis: millis)
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if calendar.isDateInToday(date) { return "\(Int(seconds / 3600))h" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if seconds < 6 * 86_400 { return date.formatted(.dateTime.weekday(.wide)) }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// The shell command a call ran, when its input names one.
    static func command(_ tool: ToolCallTranscriptItem) -> String? {
        if let c = tool.input?["command"]?.stringValue, !c.isEmpty { return c }
        if let parts = tool.input?["command"]?.arrayValue {
            let joined = parts.compactMap(\.stringValue).joined(separator: " ")
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    /// The text of a call's output, for display.
    static func output(_ tool: ToolCallTranscriptItem) -> String? {
        guard let output = tool.output, !output.isNull else { return nil }
        let text = output.stringValue ?? output.jsonString(pretty: true)
        let trimmed = text.trimmingCharacters(in: .newlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func fileName(_ path: String) -> String {
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return trimmed.split(separator: "/").last.map(String.init) ?? path
    }

    static func folder(_ path: String) -> String {
        let name = fileName(path)
        guard path.count > name.count else { return "" }
        return String(path.dropLast(name.count + (path.hasSuffix("/") ? 1 : 0)))
    }
}

/// Summary categories for a run of tool calls, in the order the summary names them.
enum ToolRunCategory: CaseIterable, Sendable {
    case used, edited, read, searched, web, ran

    init(_ kind: ToolKind) {
        switch kind {
        case .edit, .delete: self = .edited
        case .read: self = .read
        case .search: self = .searched
        case .fetch: self = .web
        case .execute: self = .ran
        case .think, .other: self = .used
        }
    }

    static func summary(_ tools: [ToolCallTranscriptItem]) -> String {
        var counts: [ToolRunCategory: Int] = [:]
        for t in tools { counts[ToolRunCategory(t.toolKind), default: 0] += 1 }
        // Searches count as reads when the run also reads files.
        if let reads = counts[.read], let searches = counts[.searched] {
            counts[.read] = reads + searches
            counts[.searched] = nil
        }
        let phrases = allCases.compactMap { category -> String? in
            guard let n = counts[category] else { return nil }
            switch category {
            case .used: return n == 1 ? "used a tool" : "used \(n) tools"
            case .edited: return n == 1 ? "edited a file" : "edited \(n) files"
            case .read: return n == 1 ? "read a file" : "read \(n) files"
            case .searched: return n == 1 ? "searched the code" : "searched the code \(n) times"
            case .web: return n == 1 ? "searched the web" : "fetched \(n) pages"
            case .ran: return n == 1 ? "ran a command" : "ran \(n) commands"
            }
        }
        let text = phrases.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}
