import CNMProtocol
import Foundation

/// The agent pane's row model, folded from the session's ACP event log
/// (the same `session/update` kinds the Mac agent pane renders).
enum TranscriptItem: Identifiable, Equatable {
    case user(id: String, text: String, at: Date)
    case userImages(id: String, images: [Data])
    case assistant(id: String, text: String)
    case thought(id: String, text: String, streaming: Bool)
    case tool(ToolCall)
    case plan(id: String, entries: [PlanEntry])
    case permission(PermissionRequest)
    case notice(id: String, text: String, isError: Bool)
    case turnEnd(id: String, duration: TimeInterval?, reason: String)

    var id: String {
        switch self {
        case .user(let id, _, _), .userImages(let id, _), .assistant(let id, _), .thought(let id, _, _), .plan(let id, _),
             .notice(let id, _, _), .turnEnd(let id, _, _):
            id
        case .tool(let call): call.id
        case .permission(let request): request.id
        }
    }
}

struct ToolCall: Equatable, Identifiable {
    enum Status: String { case pending, inProgress = "in_progress", completed, failed }

    let id: String
    var title: String
    var kind: String
    var status: Status
    var text: String
    var diffs: [FileDiff]
    var locations: [String]
    var command: String?

    var symbol: String {
        switch kind {
        case "read": "doc.text"
        case "edit": "pencil"
        case "delete": "trash"
        case "move": "arrow.right.doc.on.clipboard"
        case "search": "magnifyingglass"
        case "execute": "terminal"
        case "think": "brain"
        case "fetch": "globe"
        case "switch_mode": "arrow.triangle.branch"
        default: "wrench.and.screwdriver"
        }
    }
}

struct FileDiff: Equatable, Hashable {
    let path: String
    let oldText: String?
    let newText: String

    /// Unified-ish line diff, enough for a phone: common prefix and suffix
    /// trimmed, then removed and added lines.
    var lines: [(String, Character)] {
        let old = (oldText ?? "").components(separatedBy: "\n")
        let new = newText.components(separatedBy: "\n")
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
              old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        var result: [(String, Character)] = []
        let context = 2
        for line in old[max(0, prefix - context)..<prefix] { result.append((line, " ")) }
        for line in old[prefix..<(old.count - suffix)] { result.append((line, "-")) }
        for line in new[prefix..<(new.count - suffix)] { result.append((line, "+")) }
        for line in old[(old.count - suffix)..<min(old.count, old.count - suffix + context)] { result.append((line, " ")) }
        return result
    }

    var added: Int { lines.filter { $0.1 == "+" }.count }
    var removed: Int { lines.filter { $0.1 == "-" }.count }

    static func == (lhs: FileDiff, rhs: FileDiff) -> Bool {
        lhs.path == rhs.path && lhs.oldText == rhs.oldText && lhs.newText == rhs.newText
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(path)
        hasher.combine(newText)
    }
}

struct PlanEntry: Equatable, Hashable {
    let content: String
    let status: String
}

struct PermissionRequest: Equatable, Identifiable {
    struct Option: Equatable, Identifiable {
        let id: String
        let name: String
        let kind: String
    }

    let id: String
    let title: String
    let detail: String?
    /// Markdown the agent wants reviewed with the request (Claude's plan).
    var body: String? = nil
    let options: [Option]
    var resolved: String??
}

struct SlashCommand: Equatable, Identifiable {
    var id: String { name }
    let name: String
    let description: String
}

/// Folds an event log into transcript rows.
struct TranscriptBuilder {
    private(set) var items: [TranscriptItem] = []
    private(set) var commands: [SlashCommand] = []
    private var toolIndex: [String: Int] = [:]
    private var turnStart: Date?

    init(events: [AgentEvent]) {
        for event in events { apply(event) }
        // Thoughts stop streaming once something follows them.
        for index in items.indices {
            if case .thought(let id, let text, true) = items[index], index < items.count - 1 {
                items[index] = .thought(id: id, text: text, streaming: false)
            }
        }
    }

    private mutating func apply(_ event: AgentEvent) {
        let key = "e\(event.seq)"
        switch event.kind {
        case .userPrompt:
            let blocks = event.payload["prompt"]?.arrayValue ?? []
            let text = blocks.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
            let images = Self.images(in: blocks, key: "\(event.session)/\(event.seq)")
            // Photos sit above the message, as in ChatGPT and Claude.
            if !images.isEmpty { items.append(.userImages(id: key + "-images", images: images)) }
            items.append(.user(id: key, text: text, at: event.at))
            turnStart = event.at
        case .update:
            applyUpdate(event.payload, key: key)
        case .permissionRequest:
            let toolCall = event.payload["toolCall"]
            let options = (event.payload["options"]?.arrayValue ?? []).compactMap { option -> PermissionRequest.Option? in
                guard let id = option["optionId"]?.stringValue else { return nil }
                return PermissionRequest.Option(id: id, name: option["name"]?.stringValue ?? id, kind: option["kind"]?.stringValue ?? "")
            }
            let command = toolCall?["rawInput"]?["command"]?.stringValue
            items.append(.permission(PermissionRequest(
                id: event.payload["requestID"]?.stringValue ?? key,
                title: toolCall?["title"]?.stringValue ?? String(localized: "The agent wants to continue"),
                detail: command ?? toolCall?["rawInput"]?["file_path"]?.stringValue,
                body: toolCall?["rawInput"]?["plan"]?.stringValue,
                options: options,
                resolved: nil
            )))
        case .permissionResolved:
            guard let id = event.payload["requestID"]?.stringValue else { return }
            for index in items.indices {
                if case .permission(var request) = items[index], request.id == id {
                    request.resolved = .some(event.payload["optionId"]?.stringValue)
                    items[index] = .permission(request)
                }
            }
        case .turnEnded:
            let duration = turnStart.map { event.at.timeIntervalSince($0) }
            items.append(.turnEnd(id: key, duration: duration, reason: event.payload["stopReason"]?.stringValue ?? "end_turn"))
            turnStart = nil
        case .error:
            items.append(.notice(id: key, text: event.payload["message"]?.stringValue ?? "Error", isError: true))
        }
    }

    private mutating func applyUpdate(_ update: JSONValue, key: String) {
        switch update["sessionUpdate"]?.stringValue {
        case "agent_message_chunk":
            let text = update["content"]?["text"]?.stringValue ?? ""
            if case .assistant(let id, let existing) = items.last {
                items[items.count - 1] = .assistant(id: id, text: existing + text)
            } else {
                items.append(.assistant(id: key, text: text))
            }
        case "agent_thought_chunk":
            let text = update["content"]?["text"]?.stringValue ?? ""
            if case .thought(let id, let existing, _) = items.last {
                items[items.count - 1] = .thought(id: id, text: existing + text, streaming: true)
            } else {
                items.append(.thought(id: key, text: text, streaming: true))
            }
        case "user_message_chunk":
            let text = update["content"]?["text"]?.stringValue ?? ""
            items.append(.user(id: key, text: text, at: .now))
        case "tool_call":
            let id = update["toolCallId"]?.stringValue ?? key
            var call = ToolCall(
                id: id, title: update["title"]?.stringValue ?? "Tool", kind: update["kind"]?.stringValue ?? "other",
                status: ToolCall.Status(rawValue: update["status"]?.stringValue ?? "pending") ?? .pending,
                text: "", diffs: [], locations: [], command: update["rawInput"]?["command"]?.stringValue
            )
            Self.merge(update, into: &call)
            if let index = toolIndex[id] {
                items[index] = .tool(call)
            } else {
                toolIndex[id] = items.count
                items.append(.tool(call))
            }
        case "tool_call_update":
            guard let id = update["toolCallId"]?.stringValue, let index = toolIndex[id], case .tool(var call) = items[index] else { return }
            if let title = update["title"]?.stringValue { call.title = title }
            if let kind = update["kind"]?.stringValue { call.kind = kind }
            if let status = update["status"]?.stringValue.flatMap(ToolCall.Status.init(rawValue:)) { call.status = status }
            if let command = update["rawInput"]?["command"]?.stringValue { call.command = command }
            Self.merge(update, into: &call)
            items[index] = .tool(call)
        case "plan":
            let entries = (update["entries"]?.arrayValue ?? []).map {
                PlanEntry(content: $0["content"]?.stringValue ?? "", status: $0["status"]?.stringValue ?? "pending")
            }
            if let index = items.lastIndex(where: { if case .plan = $0 { true } else { false } }), index >= items.count - 3 {
                if case .plan(let id, _) = items[index] { items[index] = .plan(id: id, entries: entries) }
            } else {
                items.append(.plan(id: key, entries: entries))
            }
        case "available_commands_update":
            commands = (update["availableCommands"]?.arrayValue ?? []).compactMap {
                guard let name = $0["name"]?.stringValue else { return nil }
                return SlashCommand(name: name, description: $0["description"]?.stringValue ?? "")
            }
        default:
            break
        }
    }

    /// Decoded photos per prompt event; transcripts rebuild on every streamed
    /// chunk, and base64-decoding megabytes each time adds up.
    nonisolated(unsafe) private static let imageCache = NSCache<NSString, NSArray>()

    private static func images(in blocks: [JSONValue], key: String) -> [Data] {
        if let cached = imageCache.object(forKey: key as NSString) as? [Data] { return cached }
        let images = blocks.compactMap { block -> Data? in
            guard block["type"]?.stringValue == "image", let data = block["data"]?.stringValue else { return nil }
            return Data(base64Encoded: data)
        }
        imageCache.setObject(images as NSArray, forKey: key as NSString)
        return images
    }

    private static func merge(_ update: JSONValue, into call: inout ToolCall) {
        if let content = update["content"]?.arrayValue {
            var text = ""
            var diffs: [FileDiff] = []
            for item in content {
                switch item["type"]?.stringValue {
                case "content":
                    if let value = item["content"]?["text"]?.stringValue { text += value }
                case "diff":
                    if let path = item["path"]?.stringValue {
                        diffs.append(FileDiff(path: path, oldText: item["oldText"]?.stringValue, newText: item["newText"]?.stringValue ?? ""))
                    }
                default:
                    break
                }
            }
            if !text.isEmpty { call.text = text }
            if !diffs.isEmpty { call.diffs = diffs }
        }
        if let locations = update["locations"]?.arrayValue {
            call.locations = locations.compactMap { $0["path"]?.stringValue }
        }
    }
}
