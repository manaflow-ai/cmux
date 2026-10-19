import Foundation
import Network
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// Which Chiefs Home shows. The user's Cloud Chief (``ChiefSession/cloud``,
/// the main conversation of their default Cloud Chief) is the default Chief
/// once it answers; the Mac Chief (``ChiefSession/shared``, over the Mac
/// link) stays reachable beside it while a Mac is linked. Without a Cloud
/// Chief that answers (none yet, the Cloud brain off, the service
/// unreachable) Home shows the Mac Chief as before, and ``cloudStatus`` says why.
@MainActor
@Observable
public final class ChiefSources {
    public static let shared = ChiefSources()

    /// The Mac Chief; `LiveCoordinator` swaps its backend as the Mac link changes.
    public let mac: ChiefSession
    /// The Cloud Chief; this object sets its backend.
    public let cloud: ChiefSession

    public enum CloudState: Equatable, Sendable {
        /// Signed out, or this build has no Cloud service address.
        case off
        case looking
        case ready(CloudChief)
        /// Why there is no Cloud Chief to talk to, and what the user can do about it.
        case unavailable(String, CloudAction?)
    }

    /// What Home offers when the Cloud Chief is unavailable.
    public enum CloudAction: Equatable, Sendable {
        /// The account has no Cloud Chief: make one (``createChief(named:)``).
        case create
        /// The chief's Cloud brain is off: turn it on (``turnOn(_:)``).
        case turnOn(CloudChief)
    }

    public private(set) var cloudState: CloudState = .off
    /// The account's active Cloud Chiefs (`chief.list`), in the service's order.
    public private(set) var cloudChiefs: [CloudChief] = []
    /// A create or turn-on request is running.
    public private(set) var isChanging = false
    /// Why the last create or turn-on failed (the service's answer); nil after a success.
    public private(set) var changeError: String?

    /// The model and effort a Chief made or turned on here runs with.
    nonisolated static let defaultModel = "claude-opus-5-5"
    nonisolated static let defaultEffort = "low"

    @ObservationIgnored private var http: ChiefCloudHTTP?
    @ObservationIgnored private var userID: String?
    @ObservationIgnored private var lookup: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var foregroundObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var lastPath: NWPath.Status?
    @ObservationIgnored private let selection: UserDefaults

    public init(mac: ChiefSession = .shared, cloud: ChiefSession = .cloud, selection: UserDefaults = .standard) {
        self.mac = mac
        self.cloud = cloud
        self.selection = selection
    }

    /// The chief this account last opened on this phone (``select(_:)``).
    private var selectedChiefID: String? {
        get { userID.flatMap { selection.string(forKey: "cnx.chief.cloud.selected.\($0)") } }
        set {
            guard let userID else { return }
            selection.set(newValue, forKey: "cnx.chief.cloud.selected.\(userID)")
        }
    }

    static let signedOutReason = String(localized: "Sign in to use Cloud Chief.")

    public var isCloudReady: Bool {
        if case .ready = cloudState { return true }
        return false
    }

    /// The Chief Home pins first, compose writes to and New Message names.
    public var primary: ChiefSession { isCloudReady ? cloud : mac }

    /// The Mac Chief beside the Cloud Chief, while the Cloud Chief is the
    /// default. It stays reachable once a Mac was linked in this session
    /// (the link can drop; the last Mac's name is kept), and while it holds
    /// anything for the user: an outbox, unread messages, an open question.
    public var secondary: ChiefSession? {
        guard isCloudReady else { return nil }
        let holdsSomething = !mac.outbox.isEmpty || mac.unreadCount > 0 || mac.openQuestion != nil
        return mac.macName != nil || holdsSomething ? mac : nil
    }

    /// Why the Cloud Chief is not the default; nil when it is, or when this
    /// build or account has no Cloud at all.
    public var cloudStatus: String? {
        if case let .unavailable(reason, _) = cloudState { return reason }
        return nil
    }

    /// What the user can do about ``cloudStatus``.
    public var cloudAction: CloudAction? {
        if case let .unavailable(_, action) = cloudState { return action }
        return nil
    }

    /// The Cloud Chief Home shows, when it is ready.
    public var cloudChief: CloudChief? {
        if case let .ready(chief) = cloudState { return chief }
        return nil
    }

    #if os(iOS)
    /// The session for a route.
    public func session(for place: ChiefRoute.Place) -> ChiefSession {
        switch place {
        case .cloud: cloud
        case .mac: mac
        }
    }

    /// Where the default Chief is now, for a route pushed now.
    public var primaryPlace: ChiefRoute.Place { isCloudReady ? .cloud : .mac }
    #endif

    // MARK: Lifecycle

    /// Signed in: finds the user's Cloud Chief with this account's access
    /// token, and looks again whenever the app returns to the foreground
    /// while it has none.
    public func start(userID: String, config: ChiefCloudConfig? = .current(),
                      accessToken: @escaping @Sendable (_ forceRefresh: Bool) async throws -> String) {
        guard let config else {
            stop()
            return
        }
        self.userID = userID
        http = ChiefCloudHTTP(base: config.baseURL, accessToken: accessToken)
        #if canImport(UIKit)
        if foregroundObserver == nil {
            foregroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.wake() }
            }
        }
        #endif
        if pathMonitor == nil {
            // A network change: the socket may have died with the old path.
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                let status = path.status
                Task { @MainActor in self?.pathChanged(status) }
            }
            monitor.start(queue: .main)
            pathMonitor = monitor
        }
        refresh()
    }

    /// Back in the foreground or on a new network: a ready Cloud Chief checks
    /// its socket now; one that was not reachable is looked up again.
    func wake() {
        if case .ready = cloudState, let backend = cloud.backend as? ChiefCloudBackend {
            backend.reconnectNow()
        } else {
            refreshIfNeeded()
        }
    }

    private func pathChanged(_ status: NWPath.Status) {
        defer { lastPath = status }
        // The first report is the current path, not a change.
        guard lastPath != nil, status == .satisfied else { return }
        wake()
    }

    /// Signed out: the Cloud Chief goes offline; Home shows the Mac Chief.
    public func stop() {
        generation += 1
        lookup?.cancel()
        lookup = nil
        http = nil
        userID = nil
        cloudState = .off
        cloudChiefs = []
        changeError = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        lastPath = nil
        // Signed out: the next account starts without this one's Mac pin.
        mac.macName = nil
        if !(cloud.backend is ChiefOfflineBackend) {
            cloud.use(ChiefOfflineBackend(reason: Self.signedOutReason))
        }
    }

    /// Looks again unless the Cloud Chief is already up or a look is running.
    public func refreshIfNeeded() {
        switch cloudState {
        case .ready, .looking: return
        case .off, .unavailable: refresh()
        }
    }

    /// Reads `chief.list` (and the chief's brain state) and points the
    /// Cloud session at the preferred chief's main conversation.
    public func refresh() {
        guard let http, let userID else { return }
        generation += 1
        let current = generation
        lookup?.cancel()
        if !isCloudReady { cloudState = .looking }
        let selected = selectedChiefID
        lookup = Task { [weak self] in
            let found = await Self.lookUp(http, selected: selected)
            guard let self, self.generation == current, !Task.isCancelled else { return }
            self.apply(found, userID: userID, http: http)
        }
    }

    private func apply(_ found: Lookup, userID: String, http: ChiefCloudHTTP) {
        if let chiefs = found.chiefs { cloudChiefs = chiefs }
        switch found {
        case let .ready(chief, _):
            adopt(chief, userID: userID, http: http)
        case let .unavailable(reason, action, _):
            cloudState = .unavailable(reason, action)
            if !(cloud.backend is ChiefOfflineBackend) {
                cloud.use(ChiefOfflineBackend(reason: reason))
            }
        }
    }

    /// Opens another of the account's Cloud Chiefs (``cloudChiefs``); this
    /// phone keeps the choice for the account.
    public func select(_ chief: CloudChief) {
        guard chief.id != cloudChief?.id else { return }
        selectedChiefID = chief.id
        refresh()
    }

    /// Makes a Cloud Chief for this account (`chief.create`) and turns its
    /// Cloud brain on (``defaultModel``, ``defaultEffort``), then opens it.
    public func createChief(named name: String) async {
        guard let http, !isChanging else { return }
        isChanging = true
        changeError = nil
        defer { isChanging = false }
        let display = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // One key per request (isChanging stops a second tap): a fixed key
        // would replay an earlier, since archived, chief.
        let key = "chief-create-\(UUID().uuidString)"
        do {
            let chief = try await Self.create(http, displayName: display.isEmpty ? String(localized: "Chief") : display, key: key)
            // Open the new chief even if its brain then refuses to turn on.
            selectedChiefID = chief.id
            try await Self.turnOn(http, chiefID: chief.id)
            refresh()
        } catch {
            changeError = Self.changeMessage(error)
            refresh()
        }
    }

    /// Turns a chief's Cloud brain on (``defaultModel``, ``defaultEffort``).
    public func turnOn(_ chief: CloudChief) async {
        guard let http, !isChanging else { return }
        isChanging = true
        changeError = nil
        defer { isChanging = false }
        do {
            try await Self.turnOn(http, chiefID: chief.id)
            selectedChiefID = chief.id
            refresh()
        } catch {
            changeError = Self.changeMessage(error)
        }
    }

    private func adopt(_ chief: CloudChief, userID: String, http: ChiefCloudHTTP) {
        guard let conversation = chief.mainConversation else { return }
        let identity = chief.identity(userID: userID)
        let unchanged: Bool
        if case .ready = cloudState, let backend = cloud.backend as? ChiefCloudBackend {
            // A renamed chief takes a new identity (and backend) too.
            unchanged = backend.conversationID == conversation && cloud.identity == identity
        } else {
            unchanged = false
        }
        cloudState = .ready(chief)
        guard !unchanged else { return }
        cloud.status = nil
        let backend = ChiefCloudBackend(
            http: http, conversationID: conversation, identity: identity, preferences: cloud.preferences,
            refused: { [weak self] _ in
                Task { @MainActor [weak self] in self?.refused(conversation: conversation) }
            }
        )
        cloud.use(backend, identity: identity)
    }

    /// The service refused the Cloud Chief's conversation: Home falls back to
    /// the Mac Chief, and the next foreground or Home visit looks again.
    private func refused(conversation: String) {
        guard let backend = cloud.backend as? ChiefCloudBackend, backend.conversationID == conversation else { return }
        let reason = String(localized: "Cloud Chief couldn't open your conversation.")
        cloudState = .unavailable(reason, nil)
        cloud.use(ChiefOfflineBackend(reason: reason))
    }

    // MARK: Lookup

    enum Lookup: Sendable {
        case ready(CloudChief, chiefs: [CloudChief])
        /// `chiefs` nil: the list was not read (keep the last one).
        case unavailable(String, CloudAction?, chiefs: [CloudChief]?)

        var chiefs: [CloudChief]? {
            switch self {
            case let .ready(_, chiefs): chiefs
            case let .unavailable(_, _, chiefs): chiefs
            }
        }
    }

    nonisolated static let notOnThisServer = String(localized: "Cloud Chief is not available on this server.")

    /// A well-formed agent id no account owns: the brain route answers it
    /// 403 (forbidden) where Chief brains run, and 404 where they do not.
    nonisolated static let probeAgent = "agent_00000000000000000000000000"

    /// The user's Cloud Chief to open (`selected`, else the default one),
    /// when it answers: placed on a server (that server's brain answers), or
    /// its Cloud brain is on. A service without Chief brains answers the
    /// brain routes 404.
    nonisolated static func lookUp(_ http: ChiefCloudHTTP, selected: String?) async -> Lookup {
        do {
            let body = try ChiefCloudHTTP.json(["op": "chief.list", "params": [String: Any]()])
            let reply = try await http.send("POST", "/v1/read", body: body)
            let chiefs = CloudChief.parseList(try ChiefCloudHTTP.value(reply))
            let reachable = chiefs.filter { $0.mainConversation != nil }
            guard let chief = reachable.first(where: { $0.id == selected }) ?? CloudChief.preferred(in: chiefs) else {
                // No chief yet: offer to make one only where Chief brains run.
                let probe = try await http.send("GET", "/v1/chiefs/\(probeAgent)/brain")
                if probe.status == 404 { return .unavailable(notOnThisServer, nil, chiefs: chiefs) }
                return .unavailable(String(localized: "You don't have a Cloud Chief yet."), .create, chiefs: chiefs)
            }
            if chief.brainPlace != nil { return .ready(chief, chiefs: chiefs) }
            let brain = try await http.send("GET", "/v1/chiefs/\(chief.id)/brain")
            if brain.status == 404 { return .unavailable(notOnThisServer, nil, chiefs: chiefs) }
            let status = try ChiefCloudHTTP.value(brain) as? [String: Any]
            let enabled = (status?["config"] as? [String: Any])?["enabled"] as? Bool ?? false
            return enabled ? .ready(chief, chiefs: chiefs)
                : .unavailable(String(localized: "Cloud Chief is turned off."), .turnOn(chief), chiefs: chiefs)
        } catch let error as ChiefCloudError {
            // No Home routes at all on this service.
            if error.status == 404 { return .unavailable(notOnThisServer, nil, chiefs: nil) }
            return .unavailable(String(localized: "Cloud Chief couldn't load: \(error.message)"), nil, chiefs: nil)
        } catch {
            return .unavailable(String(localized: "Couldn't reach Cloud Chief. Check your connection."), nil, chiefs: nil)
        }
    }

    /// `chief.create {display_name}`: the new chief (with its main conversation).
    nonisolated static func create(_ http: ChiefCloudHTTP, displayName: String, key: String) async throws -> CloudChief {
        let body = try ChiefCloudHTTP.json([
            "op": "chief.create", "params": ["display_name": displayName], "idempotency_key": key, "origin": "user",
        ])
        let reply = try await http.send("POST", "/v1/ops", body: body)
        guard let chief = CloudChief.parse(try ChiefCloudHTTP.value(reply)) else {
            throw ChiefCloudError.badReply(String(localized: "The service made no chief."))
        }
        return chief
    }

    /// `PUT /v1/chiefs/<chief>/brain {enabled, model, effort}`.
    nonisolated static func turnOn(_ http: ChiefCloudHTTP, chiefID: String) async throws {
        let body = try ChiefCloudHTTP.json(["enabled": true, "model": defaultModel, "effort": defaultEffort])
        let reply = try await http.send("PUT", "/v1/chiefs/\(chiefID)/brain", body: body)
        if reply.status == 404 { throw ChiefCloudError.badReply(notOnThisServer) }
        _ = try ChiefCloudHTTP.value(reply)
    }

    /// The service's answer to a create or turn-on, for the user.
    static func changeMessage(_ error: any Error) -> String {
        switch error {
        case let error as ChiefCloudError: error.message
        default: String(localized: "Couldn't reach Cloud Chief. Check your connection.")
        }
    }
}
