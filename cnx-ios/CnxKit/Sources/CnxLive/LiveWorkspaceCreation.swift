import CnxAgentChat
import CnxModel
import CnxTransport
import Foundation
import OSLog

private let creationLog = Logger(subsystem: "dev.cmux.cnx", category: "creation")

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

    /// Recent Directories are the folders of this Mac's workspaces (and the ones used here):
    /// the new workspace's terminal changes to it with `cd`, as the person would type, since
    /// the phone never sends a working directory (`cwd`) to the daemon.
    public func options(on macID: String) -> WorkspaceCreationOptions {
        WorkspaceCreationOptions(directories: true, agents: [], browser: true, cloneFromGit: false)
    }

    /// The line the new terminal runs for `directory` ("~/x" or "/x"): `cd` to it, then a
    /// clear screen, as a new workspace in that folder starts on the Mac. Nil for home.
    nonisolated static func changeDirectoryLine(_ directory: String) -> String? {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "~", trimmed != "~/" else { return nil }
        guard !trimmed.contains(where: { $0.isNewline || $0 == "\u{0}" }) else { return nil }
        func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        if trimmed.hasPrefix("~/") { return "cd ~/\(quoted(String(trimmed.dropFirst(2)))) && clear\n" }
        guard trimmed.hasPrefix("/") else { return nil }
        return "cd \(quoted(trimmed)) && clear\n"
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
            if let directory = request.directory, let line = Self.changeDirectoryLine(directory) {
                _ = try? await client.request("send", params: ["surface": surface, "text": line])
            }
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
    /// needs acpmux ready to start its session. One model-agnostic agent entry,
    /// as the Mac's New Agent Chat: the Mac's default agent, or one chosen from
    /// its catalog (`agentCatalog`).
    public func tabKinds(on macID: String) -> [NewTabKind] {
        guard canManage(on: macID) else { return [] }
        let agents: [NewTabKind] = acpmux?.isReady == true ? [.agentChat] : []
        return agents + [.terminal] + (Self.streamsBrowser(capabilities(macID)) ? [.browser] : [])
    }

    /// What the phone shows but can't open yet, with why: an older Mac that does not
    /// stream browser tabs, or agents whose acpmux link is not up yet.
    public func unavailableTabKinds(on macID: String) -> [(kind: NewTabKind, reason: String)] {
        guard canManage(on: macID) else { return [] }
        var out: [(kind: NewTabKind, reason: String)] = []
        if acpmux?.isReady != true {
            out.append((.agentChat, "Agents on this Mac aren't connected yet. Try again in a moment."))
        }
        if !Self.streamsBrowser(capabilities(macID)) {
            out.append((.browser, Self.browserUpdateReason))
        }
        return out
    }

    /// An older Mac (its hostd does not say `browser-stream-v1`).
    public static let browserUpdateReason = "Update cmux on your Mac to open browser tabs from your phone."

    /// The Mac's agents now: `_acpmux/harnesses`, and `_acpmux/models` when it answers.
    public func agentCatalog(on macID: String) async throws -> AgentCatalog {
        guard canManage(on: macID), let acpmux, acpmux.isReady else {
            throw WorkspaceCreationError("Agents on this Mac aren't connected yet. Try again in a moment.", isForPerson: true)
        }
        let harnesses: JSONValue
        do {
            harnesses = try await acpmux.request("_acpmux/harnesses", .object([:]), timeout: .seconds(15))
        } catch {
            throw WorkspaceCreationError(AcpmuxSessionSource.message(error))
        }
        let models = try? await acpmux.request("_acpmux/models", .object([:]), timeout: .seconds(10))
        return AgentCatalog(harnesses: harnesses, models: models)
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
            case .agent(let start):
                let (harness, session) = try await startAgentSession(start, in: workspace)
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
    /// terminal on the Mac: the harness the start names, else the Mac's default
    /// agent (or the first one a phone may start); then its model, when one was
    /// chosen, with `session/set_model` as the Mac's New Tab page does.
    private func startAgentSession(_ start: AgentChatStart, in workspace: Workspace) async throws -> (harness: String, session: String) {
        guard let acpmux, acpmux.isReady else { throw WorkspaceCreationError("Agents on this Mac aren't connected yet. Try again in a moment.", isForPerson: true) }
        let directories = sync.tree?.directories ?? [:]
        guard let cwd = workspace.tabs.lazy.compactMap({ directories[$0.id] }).first else {
            throw WorkspaceCreationError("This workspace has no folder on the Mac yet. Open a terminal tab first.", isForPerson: true)
        }
        guard !Self.isHomeOrAbove(cwd) else {
            throw WorkspaceCreationError("Agent chats start in a project folder. Open this workspace in one (New Workspace › Recent Directories) or cd into one in its terminal.",
                                         isForPerson: true)
        }
        let catalog = try await agentCatalog(on: workspace.macID)
        guard let (choice, model) = catalog.resolve(start) else {
            if let id = start.harness, let reason = catalog.harness(id)?.unavailableReason {
                throw WorkspaceCreationError(reason, isForPerson: true)
            }
            throw WorkspaceCreationError(catalog.unavailableReason ?? "No agent on this Mac can start a chat from your iPhone.", isForPerson: true)
        }
        let reply: JSONValue
        do {
            reply = try await acpmux.request("session/new", .object([
                "cwd": .string(cwd), "mcpServers": .array([]),
                "_meta": .object(["acpmux": .object(["harness": .string(choice.id), "policy": .string("ask")])]),
            ]))
        } catch {
            throw WorkspaceCreationError(AcpmuxSessionSource.message(error))
        }
        guard let session = reply["sessionId"]?.stringValue, !session.isEmpty else {
            throw WorkspaceCreationError("The Mac didn't start the chat")
        }
        if let model {
            // The chat stands on the harness's default model if the Mac refuses this one.
            do {
                _ = try await acpmux.request("session/set_model", .object(["sessionId": .string(session), "modelId": .string(model)]))
            } catch {
                creationLog.error("set_model \(model, privacy: .public) refused: \(AcpmuxSessionSource.message(error), privacy: .public)")
            }
        }
        return (choice.id, session)
    }

    /// `/`, `/Users`, or a home folder (`/Users/<name>`, `/var/root`): acpmux never starts a
    /// remote chat there (`web_roots` drops the home folder and everything above it).
    nonisolated static func isHomeOrAbove(_ path: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        if parts.isEmpty { return true }
        if parts == ["var", "root"] || parts == ["var"] { return true }
        return parts.first == "Users" && parts.count <= 2
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

    // MARK: Tab edits

    public func canEditTabs(on macID: String) -> Bool { canManage(on: macID) }

    /// `rename-surface {surface, name}` (the Mac's Rename Tab…), then a fresh list.
    public func renameTab(_ tab: WorkspaceTab, in workspace: Workspace, to title: String) async throws {
        let (client, surface) = try target(tab, in: workspace)
        try await run(client, "rename-surface", ["surface": surface, "name": title])
    }

    /// The Mac's Duplicate Tab: a terminal is a new terminal in the tab's pane (the Mac
    /// picks the folder, as for any new terminal from a phone); a browser tab is the same
    /// web page in a new browser tab there. An agent chat has no copy from a phone.
    public func duplicateTab(_ tab: WorkspaceTab, in workspace: Workspace) async throws -> WorkspaceTab {
        let (client, _) = try target(tab, in: workspace)
        guard let place = sync.tree?.tabPlaces[tab.id] else {
            throw WorkspaceCreationError("The Mac doesn't list this tab")
        }
        let reply: Data
        do {
            switch tab.kind {
            case .terminal:
                reply = try await client.request("new-tab", params: ["pane": place.pane])
            case .browser:
                let url = tab.url.flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0.absoluteString : nil }
                reply = try await client.request("new-browser-tab", params: ["url": url ?? "about:blank", "pane": place.pane])
            case .agent:
                throw WorkspaceCreationError("Duplicate an agent chat on the Mac, or use Continue in… here.", isForPerson: true)
            }
            guard let surface = (try WorkspaceSync.check(reply)["data"] as? [String: Any])?["surface"] as? Int else {
                throw WorkspaceCreationError("The Mac didn't say which tab it opened")
            }
            let id = DaemonTree.tabID(surface: surface)
            let tree = try await sync.listNow()
            guard let copy = tree.workspaces.flatMap(\.tabs).first(where: { $0.id == id }) else {
                throw WorkspaceCreationError("The new tab didn't appear on the Mac")
            }
            return copy
        } catch let error as DaemonReplyError {
            throw WorkspaceCreationError(error.message)
        }
    }

    /// `move-tab {surface, pane, index}`: to the target's pane and place.
    public func moveTab(_ tab: WorkspaceTab, to target: WorkspaceTab, in workspace: Workspace) async throws {
        let (client, surface) = try self.target(tab, in: workspace)
        guard let place = sync.tree?.tabPlaces[target.id] else {
            throw WorkspaceCreationError("The Mac doesn't list this tab")
        }
        try await run(client, "move-tab", ["surface": surface, "pane": place.pane, "index": place.index])
    }

    private func target(_ tab: WorkspaceTab, in workspace: Workspace) throws -> (DaemonClient, Int) {
        guard canManage(on: workspace.macID), let client = sync.daemon else {
            throw WorkspaceCreationError("Not connected")
        }
        guard let surface = sync.tree?.surfaces[tab.id] else {
            throw WorkspaceCreationError("The Mac doesn't list this tab")
        }
        return (client, surface)
    }

    private func run(_ client: DaemonClient, _ command: String, _ params: sending [String: Any]) async throws {
        do {
            try WorkspaceSync.check(await client.request(command, params: params))
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
