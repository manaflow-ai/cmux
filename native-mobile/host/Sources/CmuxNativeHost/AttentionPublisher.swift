import Foundation
import CmuxNativeWire

/// Turns daemon events into push work. Pure state, no I/O: the publisher
/// feeds it `notification` and `agent-changed` events and posts what it returns.
public struct AttentionTracker: Sendable {
    struct AgentState: Sendable {
        var state: String
        var agent: String?
        var workingSince: Double?
    }

    public struct AgentOutcome: Equatable, Sendable {
        /// An alert derived from the state change, posted after a short hold
        /// so the agent's own notification (richer text) wins the dedupe.
        public var heldAlert: AttentionEvent?
        public var activity: ActivityUpdate?
    }

    private var agents: [Int: AgentState] = [:]

    public init() {}

    public func agentName(surface: Int?) -> String? { surface.flatMap { agents[$0]?.agent } }

    /// Seeds states from `list-agents` without producing anything.
    public mutating func prime(_ rows: [JSONValue], nowMs: Double) {
        for row in rows {
            guard let surface = row["surface"]?.intValue, let state = row["state"]?.stringValue else { continue }
            agents[surface] = AgentState(state: state, agent: row["agent"]?.stringValue,
                                         workingSince: state == "working" || state == "blocked" ? nowMs : nil)
        }
    }

    public func alert(forNotification event: JSONValue, workspace: (Int) -> String?, nowMs: Double) -> AttentionEvent? {
        let id = event["id"]?.stringValue ?? event["id"]?.intValue.map(String.init) ?? event["notification"]?.intValue.map(String.init)
        guard let id else { return nil }
        let title = event["title"]?.stringValue ?? ""
        let subtitle = event["subtitle"]?.stringValue
        let body = event["body"]?.stringValue ?? ""
        let surface = event["surface"]?.intValue
        let kind = AttentionClassifier.kind(title: title, subtitle: subtitle, body: body, level: event["level"]?.stringValue)
        return AttentionEvent(
            id: "n-\(id)", kind: kind, title: title, body: body.isEmpty ? (subtitle ?? "") : body, surface: surface,
            workspace: surface.flatMap(workspace),
            agent: agentName(surface: surface) ?? AttentionClassifier.agentName(in: title),
            createdAt: event["created_at_ms"]?.doubleValue ?? nowMs)
    }

    public mutating func agentChanged(_ event: JSONValue, workspace: (Int) -> String?, nowMs: Double) -> AgentOutcome {
        guard let surface = event["surface"]?.intValue, let state = event["state"]?.stringValue else { return AgentOutcome() }
        let previous = agents[surface]
        let agent = event["agent"]?.stringValue ?? previous?.agent
        var next = AgentState(state: state, agent: agent, workingSince: previous?.workingSince)
        defer { agents[surface] = next }
        guard previous?.state != state else { return AgentOutcome() }
        let name = AttentionClassifier.displayName(agent)
        let ws = workspace(surface)
        var outcome = AgentOutcome()
        switch state {
        case "working":
            if previous?.state != "blocked" || next.workingSince == nil { next.workingSince = nowMs }
            outcome.activity = ActivityUpdate(state: .working, surface: surface, agent: agent, workspace: ws, startedAt: next.workingSince ?? nowMs)
        case "blocked":
            let since = next.workingSince ?? nowMs
            next.workingSince = since
            outcome.activity = ActivityUpdate(state: .needsInput, surface: surface, agent: agent, workspace: ws, startedAt: since)
            outcome.heldAlert = AttentionEvent(
                id: "a-\(surface)-\(Int(nowMs))", kind: .question, title: "\(name) needs your input", body: "",
                surface: surface, workspace: ws, agent: agent, createdAt: nowMs)
        case "done", "idle":
            guard let since = previous?.workingSince, previous?.state == "working" || previous?.state == "blocked" else { break }
            next.workingSince = nil
            outcome.activity = ActivityUpdate(state: .done, surface: surface, agent: agent, workspace: ws, startedAt: since)
            if state == "done" {
                outcome.heldAlert = AttentionEvent(
                    id: "a-\(surface)-\(Int(nowMs))", kind: .done, title: "\(name) finished", body: "",
                    surface: surface, workspace: ws, agent: agent, createdAt: nowMs)
            }
        default:
            break
        }
        return outcome
    }
}

/// Watches the daemon (`subscribe`: `notification`, `agent-changed`) and
/// posts attention events and Live Activity updates to the Worker
/// (`POST /v1/hosts/:id/events`). Alerts are held back while a phone says
/// it is showing cmux. Also carries out notification responses the Worker
/// relays (reply text, menu choice, allow or deny).
public actor AttentionPublisher {
    public struct Configuration: Sendable {
        public var apiBase: URL
        public var hostID: String
        public var hostSecret: String
        public var agentHold: Duration

        public init(apiBase: URL, hostID: String, hostSecret: String, agentHold: Duration = .milliseconds(1500)) {
            self.apiBase = apiBase
            self.hostID = hostID
            self.hostSecret = hostSecret
            self.agentHold = agentHold
        }
    }

    /// Posts one JSON body to the Worker's events endpoint.
    public typealias Poster = @Sendable (Data) async -> Void

    struct Posted: Sendable {
        var surface: Int
        var kind: AttentionEvent.Kind
        var options: [AttentionOption]
    }

    private let configuration: Configuration
    private let locator: DaemonSocketLocator
    private let presence: PresenceBoard
    private let log: @Sendable (String) -> Void
    private let poster: Poster
    private var tracker = AttentionTracker()
    private var deduper = AttentionDeduper()
    private var daemon: DaemonLineClient?
    private var loop: Task<Void, Never>?
    private var workspaces: [Int: String] = [:]
    private var posted: [String: Posted] = [:]
    private var postedOrder: [String] = []

    public init(configuration: Configuration, locator: DaemonSocketLocator, presence: PresenceBoard,
                log: @escaping @Sendable (String) -> Void = { _ in }, poster: Poster? = nil) {
        self.configuration = configuration
        self.locator = locator
        self.presence = presence
        self.log = log
        self.poster = poster ?? Self.httpPoster(configuration, log: log)
    }

    public func start() {
        guard loop == nil else { return }
        loop = Task { await self.run() }
    }

    public func stop() async {
        loop?.cancel()
        loop = nil
        await daemon?.close()
        daemon = nil
    }

    private func run() async {
        var delay: Duration = .seconds(1)
        while !Task.isCancelled {
            if let path = locator.resolve(), let client = try? DaemonLineClient(path: path) {
                await client.start()
                do {
                    _ = try await client.request("identify")
                    try await client.request("subscribe", ["tree_events": "coarse"])
                    daemon = client
                    delay = .seconds(1)
                    workspaces = await client.workspaceNames()
                    tracker.prime(await client.agents(), nowMs: Self.nowMs())
                    log("attention: watching daemon \(path)")
                    for await event in client.events {
                        await handle(event)
                    }
                    log("attention: daemon connection ended")
                } catch {
                    log("attention: daemon setup failed: \(error)")
                }
                await client.close()
                daemon = nil
            }
            if Task.isCancelled { return }
            // Bounded reconnect backoff (daemon not running or restarting).
            try? await Task.sleep(for: delay)
            delay = min(delay * 2, .seconds(30))
        }
    }

    func handle(_ event: JSONValue) async {
        switch event["event"]?.stringValue {
        case "notification":
            guard let alert = tracker.alert(forNotification: event, workspace: { self.workspaces[$0] }, nowMs: Self.nowMs()) else { return }
            await offer(alert)
        case "agent-changed":
            if let surface = event["surface"]?.intValue, workspaces[surface] == nil, let daemon {
                workspaces = await daemon.workspaceNames()
            }
            let outcome = tracker.agentChanged(event, workspace: { self.workspaces[$0] }, nowMs: Self.nowMs())
            if let activity = outcome.activity { await post(activity) }
            if let held = outcome.heldAlert {
                let hold = configuration.agentHold
                Task {
                    try? await Task.sleep(for: hold)
                    await self.offer(held)
                }
            }
        case "workspace-added", "workspace-closed", "workspace-renamed", "tab-added", "tab-closed", "tree-changed":
            if let daemon { workspaces = await daemon.workspaceNames() }
        default:
            break
        }
    }

    /// Dedupes, enriches from the terminal text and posts one alert.
    func offer(_ candidate: AttentionEvent) async {
        guard deduper.admit(candidate, now: Self.nowMs() / 1000) else { return }
        if presence.anyVisible {
            log("attention: \(candidate.id) not pushed (a phone is showing cmux)")
            return
        }
        var event = candidate
        if let surface = event.surface, let daemon, event.kind != .notice {
            let parsed = TerminalTextParser.parse(await daemon.scrollback(surface: surface))
            if event.quote == nil { event.quote = parsed.lastPrompt }
            if event.options.isEmpty, event.kind == .question || event.kind == .permission { event.options = parsed.options }
            if event.body.count < 40, let reply = parsed.lastReply { event.body = reply }
        }
        if let surface = event.surface { remember(event.id, Posted(surface: surface, kind: event.kind, options: event.options)) }
        await post(event)
    }

    private func remember(_ id: String, _ value: Posted) {
        if posted[id] == nil { postedOrder.append(id) }
        posted[id] = value
        if postedOrder.count > 256 { posted.removeValue(forKey: postedOrder.removeFirst()) }
    }

    private func post<T: Encodable>(_ body: T) async {
        guard let data = try? JSONEncoder().encode(body) else { return }
        await poster(data)
    }

    // MARK: Notification responses

    public enum ActionOutcome: Equatable, Sendable {
        case sent(surface: Int, keys: [String], text: String?)
        case refused(String)
    }

    /// Carries out `{event_id, surface, type, text?, key?}` from the Worker.
    /// Only events this host posted, for the surface it posted them for, are
    /// accepted; option keys must be one of that event's choices.
    @discardableResult
    public func perform(action: JSONValue, userID: String?) async -> ActionOutcome {
        let outcome = resolve(action)
        guard case .sent(let surface, let keys, let text) = outcome else {
            if case .refused(let why) = outcome { log("attention: refused action from \(userID ?? "?"): \(why)") }
            return outcome
        }
        guard let daemon else { return .refused("daemon not connected") }
        let live = await daemon.workspaceNames()
        guard live[surface] != nil else { return .refused("surface \(surface) is gone") }
        do {
            if let text {
                try await daemon.request("send", ["surface": .number(Double(surface)), "text": .string(text)])
            }
            if !keys.isEmpty {
                try await daemon.request("send-key", ["surface": .number(Double(surface)), "keys": .array(keys.map(JSONValue.string))])
            }
            log("attention: action on surface \(surface) from \(userID ?? "?")")
            return outcome
        } catch {
            return .refused("daemon: \(error)")
        }
    }

    /// Validation and key mapping, without I/O.
    func resolve(_ action: JSONValue) -> ActionOutcome {
        guard let eventID = action["event_id"]?.stringValue, let surface = action["surface"]?.intValue,
              let type = action["type"]?.stringValue else { return .refused("malformed action") }
        guard let record = posted[eventID] else { return .refused("unknown event \(eventID)") }
        guard record.surface == surface else { return .refused("event \(eventID) is not for surface \(surface)") }
        switch type {
        case "reply":
            guard let text = action["text"]?.stringValue, !text.isEmpty else { return .refused("empty reply") }
            return .sent(surface: surface, keys: ["enter"], text: String(text.prefix(4000)))
        case "option":
            guard let key = action["key"]?.stringValue, record.options.contains(where: { $0.key == key }) else {
                return .refused("not one of the event's choices")
            }
            return .sent(surface: surface, keys: [key], text: nil)
        case "allow":
            if let yes = record.options.first(where: { $0.label.lowercased().hasPrefix("yes") || $0.label.lowercased().hasPrefix("allow") })
                ?? record.options.first {
                return .sent(surface: surface, keys: [yes.key], text: nil)
            }
            return .sent(surface: surface, keys: ["enter"], text: nil)
        case "deny":
            if let no = record.options.last(where: { $0.label.lowercased().hasPrefix("no") || $0.label.lowercased().hasPrefix("deny") }) {
                return .sent(surface: surface, keys: [no.key], text: nil)
            }
            return .sent(surface: surface, keys: ["escape"], text: nil)
        default:
            return .refused("unknown action \(type)")
        }
    }

    // MARK: Transport

    static func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }

    static func httpPoster(_ configuration: Configuration, log: @escaping @Sendable (String) -> Void) -> Poster {
        let url = configuration.apiBase.appending(path: "/v1/hosts/\(configuration.hostID)/events")
        let secret = configuration.hostSecret
        return { body in
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 15
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "authorization")
            for attempt in 1...2 {
                do {
                    let (data, response) = try await URLSession.shared.data(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    if (200..<300).contains(status) {
                        log("attention: posted (\(String(decoding: data.prefix(200), as: UTF8.self)))")
                        return
                    }
                    log("attention: worker returned \(status)")
                    if status < 500 { return }
                } catch {
                    log("attention: post failed (attempt \(attempt)): \(error.localizedDescription)")
                }
            }
        }
    }
}
