import Foundation
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
        /// Why there is no Cloud Chief to talk to.
        case unavailable(String)
    }

    public private(set) var cloudState: CloudState = .off

    @ObservationIgnored private var http: ChiefCloudHTTP?
    @ObservationIgnored private var userID: String?
    @ObservationIgnored private var lookup: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var foregroundObserver: (any NSObjectProtocol)?

    public init(mac: ChiefSession = .shared, cloud: ChiefSession = .cloud) {
        self.mac = mac
        self.cloud = cloud
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
        if case let .unavailable(reason) = cloudState { return reason }
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
            ) { _ in
                MainActor.assumeIsolated { ChiefSources.shared.refreshIfNeeded() }
            }
        }
        #endif
        refresh()
    }

    /// Signed out: the Cloud Chief goes offline; Home shows the Mac Chief.
    public func stop() {
        generation += 1
        lookup?.cancel()
        lookup = nil
        http = nil
        userID = nil
        cloudState = .off
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
        lookup = Task { [weak self] in
            let found = await Self.lookUp(http)
            guard let self, self.generation == current, !Task.isCancelled else { return }
            switch found {
            case let .ready(chief):
                self.adopt(chief, userID: userID, http: http)
            case let .unavailable(reason):
                self.cloudState = .unavailable(reason)
                if !(self.cloud.backend is ChiefOfflineBackend) {
                    self.cloud.use(ChiefOfflineBackend(reason: reason))
                }
            }
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
        cloudState = .unavailable(reason)
        cloud.use(ChiefOfflineBackend(reason: reason))
    }

    // MARK: Lookup

    enum Lookup: Sendable {
        case ready(CloudChief)
        case unavailable(String)
    }

    /// The user's preferred Cloud Chief, when it answers: placed on a server
    /// (that server's brain answers), or its Cloud brain is on. A service
    /// with Chief brains off answers the brain read with 404.
    nonisolated static func lookUp(_ http: ChiefCloudHTTP) async -> Lookup {
        do {
            let body = try ChiefCloudHTTP.json(["op": "chief.list", "params": [String: Any]()])
            let reply = try await http.send("POST", "/v1/read", body: body)
            let chiefs = CloudChief.parseList(try ChiefCloudHTTP.value(reply))
            guard let chief = CloudChief.preferred(in: chiefs) else {
                return .unavailable(String(localized: "You don't have a Cloud Chief yet."))
            }
            if chief.brainPlace != nil { return .ready(chief) }
            let brain = try await http.send("GET", "/v1/chiefs/\(chief.id)/brain")
            if brain.status == 404 {
                return .unavailable(String(localized: "Cloud Chief isn't available on this service yet."))
            }
            let status = try ChiefCloudHTTP.value(brain) as? [String: Any]
            let enabled = (status?["config"] as? [String: Any])?["enabled"] as? Bool ?? false
            return enabled ? .ready(chief) : .unavailable(String(localized: "Cloud Chief is turned off."))
        } catch {
            return .unavailable(String(localized: "Couldn't reach Cloud Chief. Check your connection."))
        }
    }
}
