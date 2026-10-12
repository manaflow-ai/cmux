import Foundation

/// `list-workspaces` (cmux-tui protocol v12). Only the fields the phone
/// shows are decoded; everything is optional because the daemon adds
/// fields behind capabilities.
struct DaemonTree: Codable, Sendable, Hashable {
    var workspaceRevision: Int?
    var workspaces: [DaemonWorkspace]

    enum CodingKeys: String, CodingKey {
        case workspaces
        case workspaceRevision = "workspace_revision"
    }
}

struct DaemonWorkspace: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    var name: String
    var title: String?
    var color: String?
    var pinned: Bool?
    var active: Bool?
    var unreadCount: Int?
    var markedUnread: Bool?
    var screens: [DaemonScreen]

    enum CodingKeys: String, CodingKey {
        case id, name, title, color, pinned, active, screens
        case unreadCount = "unread_count"
        case markedUnread = "marked_unread"
    }

    var displayName: String { (title?.isEmpty == false ? title : nil) ?? name }

    /// Every live terminal tab in screen and pane order.
    var tabs: [DaemonTab] {
        screens.flatMap { $0.panes.flatMap { $0.tabs ?? [] } }.filter { !($0.dead ?? false) }
    }
}

struct DaemonScreen: Codable, Sendable, Hashable {
    var id: Int
    var name: String?
    var active: Bool?
    var panes: [DaemonPane]
}

struct DaemonPane: Codable, Sendable, Hashable {
    var id: Int
    var name: String?
    var activeTab: Int?
    var tabs: [DaemonTab]?
    var dead: Bool?

    enum CodingKeys: String, CodingKey {
        case id, name, tabs, dead
        case activeTab = "active_tab"
    }
}

struct DaemonTab: Codable, Sendable, Hashable, Identifiable {
    struct Size: Codable, Sendable, Hashable { var cols: Int; var rows: Int }

    var surface: Int
    var kind: String?
    var name: String?
    var title: String?
    var size: Size?
    var dead: Bool?
    var pinned: Bool?
    var cwd: String?
    var gitBranch: String?

    enum CodingKeys: String, CodingKey {
        case surface, kind, name, title, size, dead, pinned, cwd
        case gitBranch = "git_branch"
    }

    var id: Int { surface }
    var isTerminal: Bool { kind == nil || kind == "pty" || kind == "remote-terminal" }
    var displayTitle: String {
        // Shells title themselves `user@host:dir`; the folder says more.
        if let title, !title.isEmpty, !Self.isPromptTitle(title) { return title }
        if let short = shortCwd { return short == "~" ? "~" : String(short.split(separator: "/").last ?? Substring(short)) }
        if let title, !title.isEmpty { return title }
        if let name, !name.isEmpty { return name }
        return "Terminal \(surface)"
    }

    static func isPromptTitle(_ title: String) -> Bool {
        title.range(of: #"^[\w.-]+@[\w.-]+"#, options: .regularExpression) != nil
    }

    /// `~/code/cmux` for a cwd under the home directory.
    var shortCwd: String? {
        guard let cwd else { return nil }
        if let range = cwd.range(of: #"^/Users/[^/]+"#, options: .regularExpression) {
            return "~" + cwd[range.upperBound...]
        }
        return cwd
    }
}

/// `list-agents` row and `agent-changed` event.
struct DaemonAgent: Decodable, Sendable, Hashable {
    var surface: Int
    var state: String
    var source: String?
    var session: String?
    var agent: String?
    var updatedAtMs: Double?

    enum CodingKeys: String, CodingKey {
        case surface, state, source, session, agent
        case updatedAtMs = "updated_at_ms"
    }

    var status: AgentStatus { AgentStatus(rawValue: state) ?? .unknown }
}

enum AgentStatus: String, Sendable, Hashable {
    case working, blocked, idle, done, unknown
}

/// `list-notifications` row and `notification` event.
struct DaemonNotification: Decodable, Sendable, Hashable, Identifiable {
    var id: String
    var title: String
    var subtitle: String?
    var body: String
    var level: String?
    var surface: Int?
    var createdAtMs: Double?
    var acknowledged: Bool?

    enum CodingKeys: String, CodingKey {
        case id, title, subtitle, body, level, surface, acknowledged, notification
        case createdAtMs = "created_at_ms"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let text = try? container.decode(String.self, forKey: .id) {
            id = text
        } else if let number = try? container.decode(Int.self, forKey: .id) {
            id = String(number)
        } else if let number = try? container.decode(Int.self, forKey: .notification) {
            id = String(number)
        } else {
            id = UUID().uuidString
        }
        title = (try? container.decode(String.self, forKey: .title)) ?? ""
        subtitle = try? container.decode(String.self, forKey: .subtitle)
        body = (try? container.decode(String.self, forKey: .body)) ?? ""
        level = try? container.decode(String.self, forKey: .level)
        surface = try? container.decode(Int.self, forKey: .surface)
        createdAtMs = try? container.decode(Double.self, forKey: .createdAtMs)
        acknowledged = try? container.decode(Bool.self, forKey: .acknowledged)
    }

    init(id: String, title: String, subtitle: String? = nil, body: String, level: String? = nil, surface: Int?, createdAtMs: Double?, acknowledged: Bool? = false) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.level = level
        self.surface = surface
        self.createdAtMs = createdAtMs
        self.acknowledged = acknowledged
    }
}

/// Terminal colors from `vt-state` / `output`.
struct DaemonColors: Decodable, Sendable, Hashable {
    var fg: String?
    var bg: String?
    var cursor: String?
    var cursorStyle: String?

    enum CodingKeys: String, CodingKey {
        case fg, bg, cursor
        case cursorStyle = "cursor_style"
    }
}
