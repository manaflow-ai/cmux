import CnxModel
import Foundation

/// The cmux-tui `list-workspaces` tree (protocol v12) mapped to the app's
/// workspaces: Workspace → screens → panes → tabs, flattened per workspace.
public struct DaemonTree: Sendable {
    /// A tab's acpmux binding (`conversation.agent_session`).
    public struct AgentBinding: Hashable, Sendable {
        public var session: String?
        public var harness: String?
        public var host: String?
    }

    public var workspaces: [Workspace]
    /// Agent tabs by app tab id.
    public var agentTabs: [String: AgentBinding]
    /// The daemon surface id behind each app tab id (`s<surface>`).
    public var surfaces: [String: Int]
    public var revision: Int?

    /// The app tab id for a daemon surface.
    public static func tabID(surface: Int) -> String { "s\(surface)" }

    /// Parses a `list-workspaces` reply (`{"ok":true,"data":{...}}` or the bare data object).
    /// `previous` keeps activity times for workspaces it already knew.
    public init(reply: Data, macID: String, previous: [Workspace] = [], agents: AgentStates = AgentStates(), now: Date = Date()) throws {
        guard let object = try JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
            throw DaemonReplyError(message: "list-workspaces reply is not an object")
        }
        if object["ok"] as? Bool == false {
            throw DaemonReplyError(message: object["error"] as? String ?? "list-workspaces failed", code: object["error_code"] as? String)
        }
        let data = object["data"] as? [String: Any] ?? object
        revision = data["workspace_revision"] as? Int
        var agentTabs: [String: AgentBinding] = [:]
        var surfaces: [String: Int] = [:]
        let previousByID = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [Workspace] = []
        for case let ws as [String: Any] in data["workspaces"] as? [Any] ?? [] {
            let key = (ws["key"] as? String) ?? (ws["id"] as? Int).map { "w\($0)" } ?? UUID().uuidString
            var tabs: [WorkspaceTab] = []
            var activeTab: [String: Any]?
            var working = false
            var blocked = false
            for case let screen as [String: Any] in ws["screens"] as? [Any] ?? [] {
                let activePane = screen["active_pane"] as? Int
                for case let pane as [String: Any] in screen["panes"] as? [Any] ?? [] {
                    let paneTabs = pane["tabs"] as? [[String: Any]] ?? []
                    for (index, tab) in paneTabs.enumerated() {
                        guard let surface = tab["surface"] as? Int, tab["dead"] as? Bool != true else { continue }
                        if screen["active"] as? Bool == true, pane["id"] as? Int == activePane, pane["active_tab"] as? Int == index {
                            activeTab = tab
                        }
                        let id = Self.tabID(surface: surface)
                        surfaces[id] = surface
                        let state = agents[surface]
                        if state?.state == "working" { working = true }
                        if state?.state == "blocked" { blocked = true }
                        guard let mapped = Self.tab(tab, id: id, agent: state, bindings: &agentTabs) else { continue }
                        tabs.append(mapped)
                    }
                }
            }
            let source = activeTab ?? (ws["screens"] as? [[String: Any]])?.first.flatMap { ($0["panes"] as? [[String: Any]])?.first?["tabs"] as? [[String: Any]] }?.first
            let title = (ws["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (ws["name"] as? String) ?? "Workspace"
            let color = (ws["color"] as? String).flatMap { $0.hasPrefix("#") ? String($0.prefix(7)) : nil }
            let unread = (ws["unread_count"] as? Int ?? 0) > 0 || ws["marked_unread"] as? Bool == true
            let old = previousByID[key]
            let pendingAgents = tabs.contains { tab in agentTabs[tab.id]?.session.flatMap { agents.pending[$0] } ?? false }
            result.append(Workspace(
                id: key,
                macID: macID,
                title: title,
                directory: Self.abbreviated(source?["cwd"] as? String) ?? old?.directory ?? "",
                branch: source?["git_branch"] as? String,
                tabs: tabs,
                lastActivityAt: old?.lastActivityAt ?? now,
                needsAttention: blocked || pendingAgents,
                isWorking: working,
                hasUnread: unread,
                colorHex: color,
                icon: ws["icon"] as? String
            ))
        }
        workspaces = result
        self.agentTabs = agentTabs
        self.surfaces = surfaces
    }

    /// One daemon tab as an app tab, or nil for tabs the phone does not show (pages, conversations).
    static func tab(_ tab: [String: Any], id: String, agent: AgentState?, bindings: inout [String: AgentBinding]) -> WorkspaceTab? {
        // Conversation tabs carry an `about:blank` placeholder title.
        let rawTitle = (tab["title"] as? String).flatMap { $0 == "about:blank" ? nil : $0 }
        let title = (tab["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? rawTitle ?? ""
        switch tab["kind"] as? String {
        case "pty", "remote-terminal":
            let subtitle = Self.abbreviated(tab["cwd"] as? String)
            return WorkspaceTab(id: id, kind: .terminal, title: title.isEmpty ? "Terminal" : title, subtitle: subtitle,
                                harness: agent?.agent)
        case "browser":
            let url = (tab["url"] as? String).flatMap(URL.init(string:))
            return WorkspaceTab(id: id, kind: .browser, title: title.isEmpty ? (url?.host() ?? "Browser") : title, url: url)
        case "conversation":
            guard let session = (tab["conversation"] as? [String: Any])?["agent_session"] as? [String: Any] else { return nil }
            let binding = AgentBinding(session: session["session"] as? String, harness: session["harness"] as? String, host: session["host"] as? String)
            bindings[id] = binding
            let harness = binding.harness ?? "agent"
            return WorkspaceTab(id: id, kind: .agent, title: title.isEmpty ? Self.agentName(harness) : title,
                                subtitle: binding.session == nil ? "New chat" : nil, harness: harness)
        default:
            return nil
        }
    }

    static func agentName(_ harness: String) -> String {
        switch harness {
        case "claude": "Claude"
        case "codex": "Codex"
        default: harness.prefix(1).uppercased() + harness.dropFirst()
        }
    }

    /// `~/` for paths under a home directory (`/Users/<name>/`).
    static func abbreviated(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count >= 3, parts[1] == "Users" || parts[1] == "home" {
            let rest = parts.dropFirst(3).joined(separator: "/")
            return rest.isEmpty ? "~" : "~/\(rest)"
        }
        return path
    }
}

/// Agent status per daemon surface (`list-agents`, `agent-changed`) plus
/// acpmux sessions with open permissions.
public struct AgentStates: Sendable {
    public var bySurface: [Int: AgentState] = [:]
    /// acpmux session id → has a pending permission or question.
    public var pending: [String: Bool] = [:]

    public init() {}

    public subscript(surface: Int) -> AgentState? { bySurface[surface] }
}

public struct AgentState: Hashable, Sendable {
    public var state: String
    public var agent: String?

    public init(state: String, agent: String?) {
        self.state = state
        self.agent = agent
    }
}

public struct DaemonReplyError: Error, Equatable, Sendable {
    public var message: String
    public var code: String?

    public init(message: String, code: String? = nil) {
        self.message = message
        self.code = code
    }
}

/// What a daemon event line means for the phone's copy of the tree.
public enum DaemonEvent: Equatable, Sendable {
    /// Re-list the tree (any topology/metadata delta, `tree-changed`, focus).
    case treeChanged
    /// The subscription ended (`overflow`): subscribe again, then re-list.
    case resubscribe
    case agentChanged(surface: Int, state: String, agent: String?)
    case titleChanged(surface: Int, title: String)
    case other

    public static func parse(_ line: Data) -> DaemonEvent {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let event = object["event"] as? String else { return .other }
        switch event {
        case "overflow":
            return .resubscribe
        case "agent-changed":
            guard let surface = object["surface"] as? Int else { return .other }
            return .agentChanged(surface: surface, state: object["state"] as? String ?? "unknown", agent: object["agent"] as? String)
        case "title-changed":
            guard let surface = object["surface"] as? Int else { return .other }
            return .titleChanged(surface: surface, title: object["title"] as? String ?? "")
        case "tree-changed", "layout-changed", "surface-exited", "notification":
            return .treeChanged
        default:
            let prefixes = ["workspace-", "screen-", "pane-", "tab-"]
            return prefixes.contains(where: event.hasPrefix) ? .treeChanged : .other
        }
    }
}
