import CnxModel
import CnxTransport
import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: "dev.cmux.cnx", category: "daemon")

/// Keeps the connected Mac's workspaces in step with its cmux-tui daemon
/// over the link's `daemon` channel: declare capabilities, subscribe, list,
/// then re-list on every tree event (coalesced: one list in flight, one more
/// queued at most).
@MainActor
@Observable
public final class WorkspaceSync {
    public private(set) var tree: DaemonTree?
    public private(set) var identity: String?
    public private(set) var lastError: String?

    @ObservationIgnored public var onTree: (@MainActor (DaemonTree) -> Void)?
    @ObservationIgnored private var client: DaemonClient?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var agents = AgentStates()
    /// When an event last arrived per surface (agent state or title): the
    /// only activity time the daemon gives.
    @ObservationIgnored private var activity: [Int: Date] = [:]
    @ObservationIgnored public private(set) var macID = ""
    @ObservationIgnored private let deviceID: String
    @ObservationIgnored private let deviceName: String

    public init(deviceID: String, deviceName: String) {
        self.deviceID = deviceID
        self.deviceName = deviceName
    }

    /// The live client (nil while unbound), for Chief and other daemon users.
    public var daemon: DaemonClient? { client }

    /// Binds a fresh `daemon` channel for `macID` (nil unbinds).
    public func bind(_ channel: (any LinkChannel)?, macID: String) async {
        eventTask?.cancel()
        client = nil
        activity = [:]
        guard let channel else { return }
        self.macID = macID
        let client = DaemonClient(channel: channel)
        self.client = client
        await client.start()
        let events = client.events
        eventTask = Task { [weak self] in
            for await line in events {
                self?.handle(DaemonEvent.parse(line))
            }
        }
        // The whole setup in one write (one round trip, not five): declare
        // the client, identify, subscribe, list agents, list workspaces. The
        // daemon answers a connection's lines in order.
        let replies = await client.requests([
            ("set-client-info", [
                "name": deviceName, "kind": "ios", "device_kind": "iphone", "device_name": deviceName, "device_id": deviceID,
                "capabilities": ["conversation-tabs-v1", "agent-session-tabs-v1"],
            ]),
            ("identify", [:]),
            ("subscribe", ["tree_events": "deltas"]),
            ("list-agents", [:]),
            ("list-workspaces", [:]),
        ])
        ConnectTimeline.shared.mark("first_daemon_response")
        do {
            _ = try Self.check(replies[0].get())
            let identify = try Self.check(replies[1].get())
            if let data = identify["data"] as? [String: Any] {
                identity = "\(data["app"] as? String ?? "cmux-tui") \(data["version"] as? String ?? "") protocol \(data["protocol"] as? Int ?? 0)"
            }
            _ = try Self.check(replies[2].get())
            if let reply = try? Self.check(replies[3].get()) { applyAgents(reply) }
            let next = try DaemonTree(reply: replies[4].get(), macID: macID, previous: tree?.workspaces ?? [], agents: agents)
            tree = next
            lastError = nil
            onTree?(next)
        } catch {
            lastError = LinkController.reason(error)
            log.error("daemon bind failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Marks acpmux sessions with open permissions (workspace "Needs you"), and
    /// what each open ask is when the phone has seen it (`waitingFor`).
    public func setPending(_ pending: [String: Bool], waitingFor: [String: WorkspaceTab.WaitingFor] = [:]) {
        guard agents.pending != pending || agents.waitingFor != waitingFor else { return }
        agents.pending = pending
        agents.waitingFor = waitingFor
        Task { await refresh() }
    }

    func handle(_ event: DaemonEvent) {
        switch event {
        case .titleChanged(let surface, _):
            activity[surface] = Date()
            Task { await refresh() }
        case .treeChanged:
            Task { await refresh() }
        case .resubscribe:
            Task {
                guard let client else { return }
                _ = try? await client.request("subscribe", params: ["tree_events": "deltas"])
                await refresh()
            }
        case .agentChanged(let surface, let state, let agent, let updatedAt):
            // A Mac that reports `updated_at_ms` gives the time; an older one gets the phone's.
            if updatedAt == nil, agents.bySurface[surface]?.state != state { activity[surface] = Date() }
            agents.bySurface[surface] = AgentState(state: state, agent: agent, updatedAt: updatedAt)
            Task { await refresh() }
        case .other:
            break
        }
    }

    private func applyAgents(_ reply: [String: Any]) {
        guard let list = (reply["data"] as? [String: Any])?["agents"] as? [[String: Any]] else { return }
        for agent in list {
            guard let surface = agent["surface"] as? Int else { continue }
            agents.bySurface[surface] = AgentState(json: agent)
        }
    }

    public func refresh() async {
        guard let client else { return }
        if refreshing {
            dirty = true
            return
        }
        refreshing = true
        defer { refreshing = false }
        repeat {
            dirty = false
            do {
                let reply = try await client.request("list-workspaces")
                let next = try DaemonTree(reply: reply, macID: macID, previous: tree?.workspaces ?? [], agents: agents, activity: activity)
                tree = next
                lastError = nil
                onTree?(next)
            } catch {
                lastError = LinkController.reason(error)
                log.error("list-workspaces failed: \(String(describing: error), privacy: .public)")
                return
            }
        } while dirty
    }

    /// Lists now (outside the coalesced refresh) and publishes the tree, so
    /// a caller that just changed the topology sees its own change.
    @discardableResult
    public func listNow() async throws -> DaemonTree {
        guard let client else { throw DaemonReplyError(message: "Not connected") }
        let reply = try await client.request("list-workspaces")
        let next = try DaemonTree(reply: reply, macID: macID, previous: tree?.workspaces ?? [], agents: agents, activity: activity)
        tree = next
        lastError = nil
        onTree?(next)
        return next
    }

    /// Throws a daemon error line; returns the parsed reply object.
    @discardableResult
    static func check(_ reply: Data) throws -> [String: Any] {
        let object = (try? JSONSerialization.jsonObject(with: reply) as? [String: Any]) ?? [:]
        if object["ok"] as? Bool == false {
            throw DaemonReplyError(message: object["error"] as? String ?? "request failed", code: object["error_code"] as? String)
        }
        return object
    }
}
