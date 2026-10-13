import Foundation

/// What the transcript draws for a turn, after grouping (SPEC 6.4, acpmux `toolGroups.ts`):
/// consecutive tool calls with no prose between them become one summary row;
/// edits with diffs stand alone as diff snippets.
public enum TurnRow: Identifiable, Hashable, Sendable {
    case message(id: String, markdown: String)
    case thought(id: String, text: String)
    case tool(ACPToolCall)
    case toolGroup(id: String, calls: [ACPToolCall])
    case edit(ACPToolCall)
    case plan(id: String, entries: [ACPPlanEntry])
    case permission(PermissionRecord)
    case question(String)
    case subagents(id: String, ids: [String])

    public var id: String {
        switch self {
        case .subagents(let id, _): "s-\(id)"
        case .message(let id, _): "m-\(id)"
        case .thought(let id, _): "t-\(id)"
        case .tool(let call): "c-\(call.id)"
        case .toolGroup(let id, _): "g-\(id)"
        case .edit(let call): "e-\(call.id)"
        case .plan(let id, _): "p-\(id)"
        case .permission(let record): "r-\(record.request.id)"
        case .question(let id): "q-\(id)"
        }
    }
}

extension AgentTurn {
    public var rows: [TurnRow] {
        var rows: [TurnRow] = []
        var pending: [ACPToolCall] = []
        func flush() {
            switch pending.count {
            case 0: break
            case 1: rows.append(.tool(pending[0]))
            default: rows.append(.toolGroup(id: pending[0].id, calls: pending))
            }
            pending = []
        }
        // Permission requests render as their own card; hide the pending tool row they cover.
        let permissionTools = Set(items.compactMap { item -> String? in
            if case .permission(let record) = item { return record.request.toolCall.id }
            return nil
        })
        for item in items {
            switch item {
            case .tool(let call):
                if hiddenToolCalls.contains(call.id) {
                    continue
                } else if !call.diffs.isEmpty {
                    flush()
                    rows.append(.edit(call))
                } else if permissionTools.contains(call.id), call.status == .pending {
                    continue
                } else {
                    pending.append(call)
                }
            case .thought(let id, let text):
                // Thoughts sit inside the work run without breaking a group.
                flush()
                rows.append(.thought(id: id, text: text))
            case .message(let id, let markdown):
                flush()
                rows.append(.message(id: id, markdown: markdown))
            case .plan(let id, let entries):
                flush()
                rows.append(.plan(id: id, entries: entries))
            case .permission(let record):
                flush()
                rows.append(.permission(record))
            case .question(let question):
                flush()
                rows.append(.question(question.id))
            case .subagents(let id, let ids):
                flush()
                rows.append(.subagents(id: id, ids: ids))
            }
        }
        flush()
        return rows
    }
}

/// Wording for tool rows and groups (acpmux en strings).
public struct ToolWording: Sendable {
    public init() {}

    public func verb(_ call: ACPToolCall) -> (verb: String, object: String?) {
        let running = call.isRunning
        switch call.kind {
        case .read:
            return (running ? "Reading" : "Read", call.locations.first.map { ($0.path as NSString).lastPathComponent } ?? strip(call.title, "Read "))
        case .edit, .fileChange:
            return (running ? "Editing" : "Edited", call.locations.first.map { ($0.path as NSString).lastPathComponent } ?? strip(call.title, "Edit "))
        case .delete:
            return (running ? "Deleting" : "Deleted", call.locations.first.map { ($0.path as NSString).lastPathComponent })
        case .move:
            return (running ? "Moving" : "Moved", call.locations.first.map { ($0.path as NSString).lastPathComponent })
        case .search:
            return (running ? "Searching for" : "Searched for", call.rawInput?["pattern"]?.stringValue ?? strip(call.title, "Search "))
        case .execute:
            let verb = call.status == .pending ? "Run" : (running ? "Running" : (call.isFailed ? "Failed" : "Ran"))
            return (verb, call.command ?? call.title)
        case .fetch:
            return (running ? "Fetching" : "Fetched", call.title)
        case .think:
            return ("Thought", nil)
        case .switchMode:
            return ("Switched mode", nil)
        case .other:
            return (call.title.isEmpty ? "Used a tool" : call.title, nil)
        }
    }

    private func strip(_ title: String, _ prefix: String) -> String {
        title.hasPrefix(prefix) ? String(title.dropFirst(prefix.count)) : title
    }

    public func symbol(_ call: ACPToolCall) -> String {
        if call.isFailed { return "exclamationmark.triangle.fill" }
        switch call.kind {
        case .read: return "doc.text"
        case .edit, .fileChange: return "pencil"
        case .delete: return "trash"
        case .move: return "arrow.right.doc.on.clipboard"
        case .search: return "magnifyingglass"
        case .execute: return "terminal"
        case .fetch: return "globe"
        case .think: return "brain"
        case .switchMode: return "arrow.triangle.swap"
        case .other: return "puzzlepiece.extension"
        }
    }

    /// "Read 3 files, searched the code, ran 2 commands".
    public func summary(_ calls: [ACPToolCall]) -> String {
        var parts: [(String, Int)] = []
        func add(_ key: String) {
            if let index = parts.firstIndex(where: { $0.0 == key }) { parts[index].1 += 1 } else { parts.append((key, 1)) }
        }
        var readPaths = Set<String>()
        for call in calls {
            switch call.kind {
            case .read:
                if let path = call.locations.first?.path, !readPaths.insert(path).inserted { continue }
                add("read")
            case .edit, .fileChange, .delete, .move: add("edit")
            case .search: add("search")
            case .execute: add("run")
            case .fetch: add("web")
            default: add("tool")
            }
        }
        let running = calls.contains(where: \.isRunning)
        let phrases = parts.map { key, n -> String in
            switch key {
            case "read": return n == 1 ? "read a file" : "read \(n) files"
            case "edit": return n == 1 ? "edited a file" : "edited \(n) files"
            case "search": return n == 1 ? "searched the code" : "ran \(n) searches"
            case "run": return running && n == 1 ? "running a command" : (n == 1 ? "ran a command" : "ran \(n) commands")
            case "web": return "searched the web"
            default: return n == 1 ? "used a tool" : "used \(n) tools"
            }
        }
        let text = phrases.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    public func duration(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return "\(Int(seconds * 1000))ms" }
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        return "\(Int(seconds) / 60)m \(Int(seconds) % 60)s"
    }
}
