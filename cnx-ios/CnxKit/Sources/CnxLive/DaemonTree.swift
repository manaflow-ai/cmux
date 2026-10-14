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
    /// Each tab's working directory on the Mac, unabbreviated, when the daemon reports one.
    public var directories: [String: String] = [:]
    /// The pane a new tab of each workspace goes to: its active screen's
    /// active pane, else its first pane.
    public var panes: [String: Int] = [:]
    public var revision: Int?

    /// The app tab id for a daemon surface.
    public static func tabID(surface: Int) -> String { "s\(surface)" }

    /// Parses a `list-workspaces` reply (`{"ok":true,"data":{...}}` or the bare data object).
    /// `previous` keeps activity times for workspaces it already knew.
    /// `activity` is when the phone last saw an event (agent state, title)
    /// for each surface: the daemon reports no activity times, so a
    /// workspace with no event since the phone connected has no known time
    /// (`hasActivityTime` false; `lastActivityAt` is then first sight).
    public init(reply: Data, macID: String, previous: [Workspace] = [], agents: AgentStates = AgentStates(),
                activity: [Int: Date] = [:], now: Date = Date()) throws {
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
        var directories: [String: String] = [:]
        var panes: [String: Int] = [:]
        let previousByID = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [Workspace] = []
        for case let ws as [String: Any] in data["workspaces"] as? [Any] ?? [] {
            let key = (ws["key"] as? String) ?? (ws["id"] as? Int).map { "w\($0)" } ?? UUID().uuidString
            var tabs: [WorkspaceTab] = []
            var activeTab: [String: Any]?
            var working = false
            var blocked = false
            var observed: Date?
            var focusOrder = 0
            for case let screen as [String: Any] in ws["screens"] as? [Any] ?? [] {
                let activePane = screen["active_pane"] as? Int
                if screen["active"] as? Bool == true, let activePane { panes[key] = activePane }
                for case let pane as [String: Any] in screen["panes"] as? [Any] ?? [] {
                    focusOrder = max(focusOrder, pane["focused_at"] as? Int ?? 0)
                    if panes[key] == nil, let id = pane["id"] as? Int { panes[key] = id }
                    let paneTabs = pane["tabs"] as? [[String: Any]] ?? []
                    for (index, tab) in paneTabs.enumerated() {
                        guard let surface = tab["surface"] as? Int, tab["dead"] as? Bool != true else { continue }
                        if screen["active"] as? Bool == true, pane["id"] as? Int == activePane, pane["active_tab"] as? Int == index {
                            activeTab = tab
                        }
                        let id = Self.tabID(surface: surface)
                        surfaces[id] = surface
                        if let cwd = tab["cwd"] as? String, cwd.hasPrefix("/") { directories[id] = cwd }
                        let state = agents[surface]
                        if state?.state == "working" { working = true }
                        if state?.state == "blocked" { blocked = true }
                        // Activity: the Mac's last agent report, else what the phone saw (titles).
                        for seen in [activity[surface], state?.updatedAt].compactMap(\.self) { observed = max(observed ?? seen, seen) }
                        guard let mapped = Self.tab(tab, id: id, agent: state, pending: agents.pending,
                                                    waitingFor: agents.waitingFor, bindings: &agentTabs) else { continue }
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
            let known = old.flatMap { $0.hasActivityTime ? $0.lastActivityAt : nil }
            let activityAt = [observed, known].compactMap(\.self).max()
            let activeTabID = (activeTab?["surface"] as? Int).map(Self.tabID(surface:)).flatMap { id in
                tabs.contains { $0.id == id } ? id : nil
            }
            result.append(Workspace(
                id: key,
                macID: macID,
                title: title,
                directory: Self.abbreviated(source?["cwd"] as? String) ?? old?.directory ?? "",
                branch: source?["git_branch"] as? String,
                tabs: tabs,
                lastActivityAt: activityAt ?? old?.lastActivityAt ?? now,
                needsAttention: blocked || pendingAgents,
                isWorking: working,
                hasUnread: unread,
                colorHex: color,
                icon: ws["icon"] as? String,
                hasActivityTime: activityAt != nil,
                focusOrder: focusOrder,
                activeTabID: activeTabID
            ))
        }
        workspaces = result
        self.agentTabs = agentTabs
        self.surfaces = surfaces
        self.directories = directories
        self.panes = panes
    }

    /// One daemon tab as an app tab, or nil for tabs the phone does not show (pages, conversations).
    /// `agent` is the surface's agent state; `pending` marks acpmux sessions
    /// with an open permission or question. Both set the tab's `agentStatus`.
    static func tab(_ tab: [String: Any], id: String, agent: AgentState?, pending: [String: Bool] = [:],
                    waitingFor: [String: WorkspaceTab.WaitingFor] = [:],
                    bindings: inout [String: AgentBinding]) -> WorkspaceTab? {
        var status: WorkspaceTab.AgentStatus? = switch agent?.state {
        case "blocked": .waiting
        case "working": .working
        default: nil
        }
        // Conversation tabs carry an `about:blank` placeholder title.
        let rawTitle = (tab["title"] as? String).flatMap { $0 == "about:blank" ? nil : $0 }
        let title = (tab["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? rawTitle ?? ""
        switch tab["kind"] as? String {
        case "pty", "remote-terminal":
            let subtitle = Self.abbreviated(tab["cwd"] as? String)
            return WorkspaceTab(id: id, kind: .terminal, title: title.isEmpty ? "Terminal" : title, subtitle: subtitle,
                                harness: agent?.agent, agentStatus: status)
        case "browser":
            let url = (tab["url"] as? String).flatMap(URL.init(string:))
            return WorkspaceTab(id: id, kind: .browser, title: title.isEmpty ? (url?.host() ?? "Browser") : title, url: url)
        case "conversation":
            guard let session = (tab["conversation"] as? [String: Any])?["agent_session"] as? [String: Any] else { return nil }
            let binding = AgentBinding(session: session["session"] as? String, harness: session["harness"] as? String, host: session["host"] as? String)
            bindings[id] = binding
            var asks: WorkspaceTab.WaitingFor?
            if let session = binding.session, pending[session] == true {
                status = .waiting
                asks = waitingFor[session]
            }
            let harness = binding.harness ?? "agent"
            return WorkspaceTab(id: id, kind: .agent, title: title.isEmpty ? Self.agentName(harness) : title,
                                subtitle: binding.session == nil ? "New chat" : nil, harness: harness, agentStatus: status,
                                waitingFor: status == .waiting ? asks : nil)
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
    /// acpmux session id → what its open ask is, when the phone has seen it
    /// (a question wins over a permission). Absent: "is waiting".
    public var waitingFor: [String: WorkspaceTab.WaitingFor] = [:]

    public init() {}

    public subscript(surface: Int) -> AgentState? { bySurface[surface] }
}

public struct AgentState: Hashable, Sendable {
    public var state: String
    public var agent: String?
    /// The Mac's last report for this agent (`updated_at_ms`), when it sends one.
    public var updatedAt: Date?

    public init(state: String, agent: String?, updatedAt: Date? = nil) {
        self.state = state
        self.agent = agent
        self.updatedAt = updatedAt
    }

    /// An agent row of `list-agents` or an `agent-changed` event.
    public init?(json: [String: Any]) {
        guard json["surface"] is Int else { return nil }
        self.init(state: json["state"] as? String ?? "unknown", agent: json["agent"] as? String,
                  updatedAt: Self.date(json["updated_at_ms"]))
    }

    /// Epoch milliseconds (`updated_at_ms`) as a date; nil when absent (older Macs).
    static func date(_ value: Any?) -> Date? {
        guard let ms = (value as? NSNumber)?.doubleValue, ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
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
    case agentChanged(surface: Int, state: String, agent: String?, updatedAt: Date? = nil)
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
            return .agentChanged(surface: surface, state: object["state"] as? String ?? "unknown", agent: object["agent"] as? String,
                                 updatedAt: AgentState.date(object["updated_at_ms"]))
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
