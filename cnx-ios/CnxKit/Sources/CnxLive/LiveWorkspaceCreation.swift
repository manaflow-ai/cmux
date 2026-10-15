import CnxAgentChat
import CnxModel
import Foundation

/// Creates workspaces and tabs on the linked Mac's cmux-tui daemon. The
/// phone's `daemon` lane (cnx-hostd policy) allows `new-workspace {name}`,
/// `new-tab`, `new-browser-tab`, `close-surface` and an agent
/// `new-conversation-tab`, but never a working directory (`cwd`), so the
/// long-press menu offers no recent directories and no git clone.
@MainActor
public final class LiveWorkspaceCreationBackend: WorkspaceCreationBackend {
    private let sync: WorkspaceSync
    private let link: LinkController
    /// Starts the agent session behind a new agent tab (nil: no agent tabs).
    private weak var acpmux: AcpmuxHub?

    /// The capabilities each Mac's `version` service reported (nil: not known yet).
    public var capabilities: @MainActor (String) -> Set<String>? = { _ in nil }

    /// Whether a Mac streams browser tabs: it said `browser-stream-v1`. A Mac that
    /// has not answered yet keeps the option (an older Mac's refusal then reads plainly).
    nonisolated static func streamsBrowser(_ capabilities: Set<String>?) -> Bool {
        capabilities.map { $0.contains("browser-stream-v1") || !$0.contains("removal-v1") } ?? true
    }

    public init(sync: WorkspaceSync, link: LinkController, acpmux: AcpmuxHub? = nil) {
        self.sync = sync
        self.link = link
        self.acpmux = acpmux
    }

    public func canCreate(on macID: String) -> Bool {
        link.target?.macID == macID && link.phase.isConnected && sync.daemon != nil && sync.macID == macID
    }

    public func options(on macID: String) -> WorkspaceCreationOptions {
        WorkspaceCreationOptions(directories: false, agents: [], browser: true, cloneFromGit: false)
    }

    public func create(_ request: NewWorkspaceRequest, placeholder: Workspace) async throws -> Workspace {
        guard canCreate(on: request.macID), let client = sync.daemon else {
            throw WorkspaceCreationError("Not connected")
        }
        do {
            // One screen, one pane, one terminal at the daemon's default
            // directory; the new workspace becomes the active one.
            let reply = try WorkspaceSync.check(await client.request("new-workspace", params: ["name": placeholder.title]))
            guard let surface = (reply["data"] as? [String: Any])?["surface"] as? Int else {
                throw WorkspaceCreationError("The Mac didn't say which workspace it created")
            }
            var opening = DaemonTree.tabID(surface: surface)
            if request.start == .browser {
                // No pane: the active pane, which is the new workspace's. If
                // the Mac has no browser runtime the workspace still stands,
                // and opens on its terminal.
                if let browser = try? WorkspaceSync.check(await client.request("new-browser-tab", params: ["url": "about:blank"])),
                   let id = (browser["data"] as? [String: Any])?["surface"] as? Int {
                    opening = DaemonTree.tabID(surface: id)
                }
            }
            let tree = try await sync.listNow()
            guard let created = tree.workspaces.first(where: { $0.tabs.contains { $0.id == opening } })
                ?? tree.workspaces.first(where: { $0.tabs.contains { $0.id == DaemonTree.tabID(surface: surface) } }) else {
                throw WorkspaceCreationError("The new workspace didn't appear on the Mac")
            }
            return created
        } catch let error as DaemonReplyError {
            throw WorkspaceCreationError(error.message)
        }
    }

    /// The daemon lane allows `rename-workspace` and `close-workspace` on
    /// the linked Mac.
    public func canManage(on macID: String) -> Bool { canCreate(on: macID) }

    public func rename(_ workspace: Workspace, to title: String) async throws {
        try await send("rename-workspace", workspace, name: title)
    }

    public func close(_ workspace: Workspace) async throws {
        try await send("close-workspace", workspace, name: nil)
    }

    // MARK: Tabs

    /// Terminal and browser tabs need only the daemon lane; an agent tab also
    /// needs acpmux ready to start its session. Claude only: acpmux refuses a
    /// remote start of the families it lists as not asking (Codex, opencode),
    /// so the phone never offers one it cannot start.
    public func tabKinds(on macID: String) -> [NewTabKind] {
        guard canManage(on: macID) else { return [] }
        let agents: [NewTabKind] = acpmux?.isReady == true ? [.agent("claude")] : []
        return agents + [.terminal] + (Self.streamsBrowser(capabilities(macID)) ? [.browser] : [])
    }

    /// Opens the tab on the Mac in the workspace's active pane, then waits
    /// until the Mac lists it, so the phone shows only what the Mac has:
    /// - terminal: `new-tab` (the Mac's default shell; no program, folder or env from the phone);
    /// - browser: `new-browser-tab about:blank`;
    /// - agent: acpmux `session/new` in the workspace's folder (asking
    ///   policy, no MCP servers; acpmux's remote guard checks the folder),
    ///   then `new-conversation-tab` showing that session (cnx-hostd records
    ///   it as this Mac's own chat).
    public func createTab(_ kind: NewTabKind, in workspace: Workspace) async throws -> WorkspaceTab {
        guard canManage(on: workspace.macID), let client = sync.daemon else {
            throw WorkspaceCreationError("Not connected")
        }
        guard let pane = sync.tree?.panes[workspace.id] else {
            throw WorkspaceCreationError("The Mac hasn't listed this workspace's panes yet")
        }
        do {
            let reply: Data
            switch kind {
            case .terminal:
                reply = try await client.request("new-tab", params: ["pane": pane])
            case .browser:
                reply = try await client.request("new-browser-tab", params: ["url": "about:blank", "pane": pane])
            case .agent(let harness):
                let session = try await startAgentSession(harness: harness, in: workspace)
                reply = try await client.request("new-conversation-tab", params: [
                    "pane": pane,
                    "agent_session": ["harness": harness, "session": session],
                ])
            }
            guard let surface = (try WorkspaceSync.check(reply)["data"] as? [String: Any])?["surface"] as? Int else {
                throw WorkspaceCreationError("The Mac didn't say which tab it opened")
            }
            let id = DaemonTree.tabID(surface: surface)
            let tree = try await sync.listNow()
            guard let tab = tree.workspaces.first(where: { $0.id == workspace.id })?.tabs.first(where: { $0.id == id })
                ?? tree.workspaces.flatMap(\.tabs).first(where: { $0.id == id }) else {
                throw WorkspaceCreationError("The new tab didn't appear on the Mac")
            }
            return tab
        } catch let error as DaemonReplyError {
            throw WorkspaceCreationError(error.message)
        }
    }

    /// The new chat's acpmux session, in the folder of the workspace's
    /// terminal on the Mac.
    private func startAgentSession(harness: String, in workspace: Workspace) async throws -> String {
        guard let acpmux, acpmux.isReady else { throw WorkspaceCreationError("Agents on this Mac aren't connected yet") }
        let directories = sync.tree?.directories ?? [:]
        guard let cwd = workspace.tabs.lazy.compactMap({ directories[$0.id] }).first else {
            throw WorkspaceCreationError("This workspace has no folder on the Mac yet. Open a terminal tab first.")
        }
        let reply: JSONValue
        do {
            reply = try await acpmux.request("session/new", .object([
                "cwd": .string(cwd), "mcpServers": .array([]),
                "_meta": .object(["acpmux": .object(["harness": .string(harness), "policy": .string("ask")])]),
            ]))
        } catch {
            throw WorkspaceCreationError(AcpmuxSessionSource.message(error))
        }
        guard let session = reply["sessionId"]?.stringValue, !session.isEmpty else {
            throw WorkspaceCreationError("The Mac didn't start the chat")
        }
        return session
    }

    /// `close-surface` on the Mac, then a fresh list.
    public func closeTab(_ tab: WorkspaceTab, in workspace: Workspace) async throws {
        guard canManage(on: workspace.macID), let client = sync.daemon else {
            throw WorkspaceCreationError("Not connected")
        }
        guard let surface = sync.tree?.surfaces[tab.id] else {
            throw WorkspaceCreationError("The Mac doesn't list this tab")
        }
        do {
            try WorkspaceSync.check(await client.request("close-surface", params: ["surface": surface]))
            _ = try? await sync.listNow()
        } catch let error as DaemonReplyError {
            throw WorkspaceCreationError(error.message)
        }
    }

    /// Workspaces are addressed by key; a tree without keys gave "w<id>".
    private func send(_ cmd: String, _ workspace: Workspace, name: String?) async throws {
        guard canManage(on: workspace.macID), let client = sync.daemon else {
            throw WorkspaceCreationError("Not connected")
        }
        var params: [String: Any] = [:]
        if let name { params["name"] = name }
        if workspace.id.hasPrefix("w"), let id = Int(workspace.id.dropFirst()) {
            params["workspace"] = id
        } else {
            params["key"] = workspace.id
        }
        do {
            try WorkspaceSync.check(await client.request(cmd, params: params))
            _ = try? await sync.listNow()
        } catch let error as DaemonReplyError {
            throw WorkspaceCreationError(error.message)
        }
    }
}
