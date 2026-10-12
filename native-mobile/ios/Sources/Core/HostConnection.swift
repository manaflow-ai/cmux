import CmuxNativeLink
import Foundation
import Observation
import UIKit

/// The live connection to one paired Mac: the link, a control daemon
/// connection (tree, agents, notifications), the `svc` channel, and a
/// daemon connection per open terminal.
@MainActor
@Observable
final class HostConnection {
    enum Phase: Equatable {
        case connecting
        case connected
        case reconnecting
        case offline(String)
    }

    let host: APIClient.Host
    private(set) var phase: Phase = .connecting
    private(set) var path: String = ""
    private(set) var tree: DaemonTree?
    private(set) var agents: [Int: DaemonAgent] = [:]
    private(set) var notifications: [DaemonNotification] = []
    private(set) var lastError: String?

    private let link: any HostLink
    private var control: DaemonClient?
    private(set) var services: ServiceClient?
    private var tasks: [Task<Void, Never>] = []
    private var refreshTask: Task<Void, Never>?
    /// One terminal session per surface, shared by every screen that shows it.
    private var terminalSessions: [Int: TerminalSession] = [:]

    func terminalSession(for surface: Int) -> TerminalSession {
        if let existing = terminalSessions[surface] { return existing }
        let session = TerminalSession(surfaceID: surface, connection: self)
        terminalSessions[surface] = session
        return session
    }

    /// Fires on daemon notifications (the feed listens).
    var onNotification: ((DaemonNotification) -> Void)?
    /// Fires after every (re)connect, once the tree is loaded.
    var onConnected: (() -> Void)?
    /// Fires on agent state changes (the feed listens).
    var onAgentChange: ((DaemonAgent, DaemonAgent?) -> Void)?

    init(host: APIClient.Host, link: any HostLink) {
        self.host = host
        self.link = link
        // Last known workspaces, shown while the link connects.
        if let data = UserDefaults.standard.data(forKey: cacheKey) {
            tree = try? JSONDecoder().decode(DaemonTree.self, from: data)
        }
    }

    private var cacheKey: String { "tree.\(host.id)" }

    var workspaces: [DaemonWorkspace] { tree?.workspaces ?? [] }

    func tab(surface: Int) -> DaemonTab? {
        for workspace in workspaces { if let tab = workspace.tabs.first(where: { $0.surface == surface }) { return tab } }
        return nil
    }

    func workspace(containing surface: Int) -> DaemonWorkspace? {
        workspaces.first { $0.tabs.contains { $0.surface == surface } }
    }

    func start() {
        guard tasks.isEmpty else { return }
        tasks.append(Task { [weak self] in
            guard let states = self?.link.state else { return }
            for await state in states {
                await self?.apply(state)
            }
        })
    }

    func stop() {
        heartbeat?.cancel()
        for task in tasks { task.cancel() }
        tasks.removeAll()
        Task { await control?.close() }
        link.close()
    }

    private func apply(_ state: LinkState) async {
        switch state {
        case .connecting:
            if phase != .connected { phase = .connecting }
        case .connected(let linkPath):
            path = linkPath.description
            // A path change (direct <-> relay) or an ICE restart keeps the
            // channels; only a new peer connection needs them reopened.
            if let control, await !control.closed, let services, await !services.isClosed {
                phase = .connected
                return
            }
            await openControl()
        case .reconnecting:
            phase = .reconnecting
        case .failed(let message):
            phase = .offline(message)
        case .closed:
            phase = .offline("Disconnected")
        }
    }

    private func openControl() async {
        do {
            let channel = try await link.openChannel(label: "daemon:\(UUID().uuidString)")
            let client = DaemonClient(channel: channel)
            await client.start()
            await control?.close()
            _ = try await client.identify()
            try? await client.setClientInfo(deviceID: Self.deviceID, name: UIDevice.current.name)
            try await client.subscribe()
            control = client
            startHeartbeat(client)
            // Terminals attached over the previous link reattach on this one.
            for session in terminalSessions.values { session.reattach() }
            let events = client.events
            tasks.append(Task { [weak self] in
                for await event in events { self?.handle(event) }
            })
            if let services {
                // Rebind rather than replace: open sheets hold this client.
                if await services.isClosed { await services.rebind(try await link.openChannel(label: "svc")) }
            } else {
                let svc = ServiceClient(channel: try await link.openChannel(label: "svc"))
                await svc.start()
                services = svc
            }
            await refresh()
            phase = .connected
            onConnected?()
        } catch {
            lastError = error.localizedDescription
            phase = .offline(error.localizedDescription)
        }
    }

    private var heartbeat: Task<Void, Never>?

    /// A `ping` every 15 s: the host drops peers silent for 45 s (a killed
    /// app's connection doesn't always report its own end), and it keeps NAT
    /// bindings warm on relayed paths.
    private func startHeartbeat(_ client: DaemonClient) {
        heartbeat?.cancel()
        heartbeat = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { return }
                _ = try? await client.request("ping")
            }
        }
    }

    func refresh() async {
        guard let control else { return }
        do {
            let fresh = try await control.listWorkspaces()
            tree = fresh
            UserDefaults.standard.set(try? JSONEncoder().encode(fresh), forKey: cacheKey)
            let agentList = (try? await control.listAgents()) ?? []
            agents = Dictionary(agentList.map { ($0.surface, $0) }, uniquingKeysWith: { $1 })
            notifications = try await control.listNotifications()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Coalesces tree refetches (the daemon sends `tree-changed` bursts).
    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    private func handle(_ event: DaemonClient.Event) {
        switch event.name {
        case "tree-changed", "workspace-added", "workspace-closed", "workspace-renamed", "workspace-changed",
             "tab-added", "tab-closed", "tab-renamed", "tab-changed", "pane-added", "pane-closed",
             "screen-added", "screen-closed", "title-changed", "surface-exited":
            scheduleRefresh()
        case "agent-changed":
            guard let agent = try? event.payload.decode(DaemonAgent.self) else { return }
            let previous = agents[agent.surface]
            agents[agent.surface] = agent
            onAgentChange?(agent, previous)
        case "notification":
            guard var notification = try? event.payload.decode(DaemonNotification.self) else { return }
            if notification.createdAtMs == nil { notification.createdAtMs = Date().timeIntervalSince1970 * 1000 }
            guard !notifications.contains(where: { $0.id == notification.id }) else { return }
            notifications.insert(notification, at: 0)
            onNotification?(notification)
        case "overflow":
            scheduleRefresh()
        default:
            break
        }
    }

    // MARK: Actions

    /// A fresh daemon connection for one terminal (attach streams are per connection).
    func openTerminalClient() async throws -> DaemonClient {
        let channel = try await link.openChannel(label: "daemon:\(UUID().uuidString)")
        let client = DaemonClient(channel: channel)
        await client.start()
        try? await client.setClientInfo(deviceID: Self.deviceID, name: UIDevice.current.name)
        return client
    }

    func send(surface: Int, text: String) async throws {
        guard let control else { throw DaemonClient.Failure(message: "Not connected.") }
        try await control.send(surface: surface, text: text)
    }

    func sendKeys(surface: Int, _ keys: [String]) async throws {
        guard let control else { throw DaemonClient.Failure(message: "Not connected.") }
        try await control.sendKeys(surface: surface, keys)
    }

    func scrollback(surface: Int) async -> String {
        (try? await control?.readScrollback(surface: surface)) ?? ""
    }

    @discardableResult
    func newWorkspace(name: String?) async throws -> Int? {
        guard let control else { return nil }
        let surface = try await control.newWorkspace(name: name)
        await refresh()
        return surface
    }

    @discardableResult
    func newTerminal(in workspace: DaemonWorkspace) async throws -> Int? {
        guard let control, let pane = workspace.screens.first(where: { $0.active ?? false })?.panes.first ?? workspace.screens.first?.panes.first else { return nil }
        let surface = try await control.newTab(pane: pane.id)
        await refresh()
        return surface
    }

    func close(surface: Int) async {
        try? await control?.closeSurface(surface)
        await refresh()
    }

    func acknowledge(surface: Int) async {
        try? await control?.acknowledge(surface: surface)
    }

    static var deviceID: String {
        if let id = UserDefaults.standard.string(forKey: "deviceID") { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "deviceID")
        return id
    }
}
