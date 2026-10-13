#if os(iOS)
import CnxAgentChat
import CnxArtifacts
import CnxChief
import CnxDesign
import CnxFeed
import CnxModel
import CnxTransport
import Foundation
import Observation
import OSLog

private let log = Logger(subsystem: "dev.cmux.cnx", category: "live")

/// Wires the signed-in app to real data: registers this phone in the active
/// team (the personal space `personal-<userId>` when the account has no
/// teams), keeps the team's Macs live from presence, holds a link to the
/// selected online Mac over the Settings transport, and feeds the daemon's
/// workspaces, acpmux chats, the Feed and Chief from that link.
@MainActor
@Observable
public final class LiveCoordinator {
    public private(set) var banner: ConnectionBannerState?
    public private(set) var registeredTeamID: String?
    public private(set) var presenceConnected = false
    public private(set) var chiefStatus: String?

    public let link: LinkController
    public let workspaces: WorkspaceSync
    public let acpmux = AcpmuxHub()
    @ObservationIgnored public let feed: LiveFeed

    @ObservationIgnored let store: AppStore
    @ObservationIgnored let api: LiveAPI
    @ObservationIgnored let identity: DeviceIdentity
    @ObservationIgnored let userID: String
    @ObservationIgnored let deviceName: String
    @ObservationIgnored let clock: any Clock<Duration>
    @ObservationIgnored private var presence: PresenceListener?
    @ObservationIgnored private var teamTask: Task<Void, Never>?
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    @ObservationIgnored private var everConnected = false
    @ObservationIgnored private var tree: DaemonTree?
    /// The link to the targeted Mac, for terminal tabs (each attaches on its own channel).
    @ObservationIgnored private var currentLink: (any MacLink)?
    @ObservationIgnored private var chiefLive = false

    /// The personal space id for a user (PROTOCOL.md "Personal space").
    public static func personalTeamID(userID: String) -> String { "personal-\(userID)" }

    public init(
        store: AppStore,
        api: LiveAPI,
        identity: DeviceIdentity,
        userID: String,
        deviceName: String,
        transport: CnxTransport.TransportKind,
        relayOnly: Bool = false,
        dialer: any MacLinkDialer,
        feedStore: FeedStore = .shared,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.store = store
        self.api = api
        self.identity = identity
        self.userID = userID
        self.deviceName = deviceName
        self.clock = clock
        workspaces = WorkspaceSync(deviceID: identity.link, deviceName: deviceName)
        let apiForLink = api
        link = LinkController(transport: transport, relayOnly: relayOnly, dialer: dialer, clock: clock,
                              accessToken: { try await apiForLink.accessToken($0) })
        feed = LiveFeed(store: feedStore, hub: nil, place: { _ in nil })
        link.endpoint = { [weak self] macID in
            guard let self, let teamID = self.registeredTeamID else { return nil }
            return LinkEndpoint(baseURL: self.api.baseURL, teamID: teamID, deviceID: self.identity.link, macDeviceID: macID)
        }
        feed.place = { [weak self] sessionID in self?.place(sessionID: sessionID) }
        feed.hub = acpmux
        feedStore.replaceAll([])
        feedStore.actions = feed
        store.workspaces = []
        store.teamDataState = .loading
        link.onLink = { [weak self] link in self?.linkChanged(link) }
        workspaces.onTree = { [weak self] tree in self?.apply(tree) }
        acpmux.onWatchEvent = { [weak self] event in
            guard let self else { return }
            self.feed.handle(event, sessions: self.acpmux.sessions)
            self.workspaces.setPending(self.acpmux.sessions.mapValues { $0.pendingPermissions > 0 })
        }
        AgentSessionDirectory.shared.makeSource = { [weak self] summary in
            guard let self, let session = self.tree?.agentTabs[summary.id]?.session else {
                return UnboundAgentSource(summary: summary)
            }
            return self.acpmux.source(sessionID: session, summary: summary)
        }
        observeLink()
    }

    // MARK: Teams

    /// Applies the account's teams (or the personal space) and starts the active one.
    public func applyAccountTeams(_ teams: [AppStore.AccountTeam], selectedID: String?) {
        let list = teams.isEmpty ? [AppStore.AccountTeam(id: Self.personalTeamID(userID: userID), name: "Personal")] : teams
        store.applyLiveTeams(list, selectedID: selectedID)
        activeTeamChanged()
        for team in list { loadPrefs(team.id) }
    }

    /// Call after `store.selectTeam`: re-registers, reloads Macs, re-targets the link.
    public func activeTeamChanged() {
        let teamID = store.activeTeamID
        guard !teamID.isEmpty, teamID != registeredTeamID else { return }
        teamTask?.cancel()
        presence?.stop()
        presence = nil
        registeredTeamID = nil
        store.teamDataState = .loading
        link.send(.target(nil))
        teamTask = Task { [weak self] in await self?.startTeam(teamID) }
    }

    private func startTeam(_ teamID: String) async {
        do {
            try await api.registerDevice(id: identity.link, kind: "phone", name: deviceName, teamID: teamID)
            try await api.registerDevice(id: identity.presence, kind: "phone", name: "\(deviceName) (presence)", teamID: teamID)
            guard !Task.isCancelled, store.activeTeamID == teamID else { return }
            registeredTeamID = teamID
            let macs = try await api.macs(teamID: teamID)
            guard !Task.isCancelled, store.activeTeamID == teamID else { return }
            applyMacs(macs, teamID: teamID)
            store.teamDataState = .loaded
            log.info("team \(teamID, privacy: .private) registered, \(macs.count, privacy: .public) Macs")
            let listener = PresenceListener(api: api, teamID: teamID, deviceID: identity.presence, clock: clock) { [weak self] update in
                self?.presenceUpdate(update, teamID: teamID)
            }
            presence = listener
            listener.start()
        } catch {
            guard !Task.isCancelled else { return }
            log.error("team start failed: \(String(describing: error), privacy: .public)")
            store.teamDataState = .failed
            // Try again on its own (the list's Retry also works).
            do { try await clock.sleep(for: .seconds(5)) } catch { return }
            guard store.activeTeamID == teamID, registeredTeamID == nil else { return }
            await startTeam(teamID)
        }
    }

    /// Retry after a failed team load (the Workspaces Retry button).
    public func retry() {
        registeredTeamID = nil
        activeTeamChanged()
    }

    private func presenceUpdate(_ update: PresenceListener.Update, teamID: String) {
        guard store.activeTeamID == teamID else { return }
        switch update {
        case .connected(let connected):
            presenceConnected = connected
        case .snapshot(let macs):
            applyMacs(macs, teamID: teamID)
        case .mac(let mac):
            var current = store.teams.first { $0.id == teamID }?.macs ?? []
            let device = MacDevice(id: mac.deviceId, name: mac.name, isOnline: mac.online, lastSeenAt: mac.lastSeenDate)
            if let index = current.firstIndex(where: { $0.id == mac.deviceId }) { current[index] = device } else { current.append(device) }
            store.setMacs(current, teamID: teamID)
            retarget()
        }
    }

    private func applyMacs(_ macs: [LiveAPI.Mac], teamID: String) {
        store.setMacs(macs.map { MacDevice(id: $0.deviceId, name: $0.name, isOnline: $0.online, lastSeenAt: $0.lastSeenDate) }, teamID: teamID)
        retarget()
    }

    /// Dials the selected Mac (remembered per team), else the first online one.
    private func retarget() {
        guard let team = store.activeTeam, registeredTeamID == team.id else { return }
        let remembered = UserDefaults.standard.string(forKey: "cnx.live.mac.\(team.id)")
        let mac = team.macs.first { $0.id == remembered && $0.isOnline } ?? team.macs.first(where: \.isOnline)
            ?? team.macs.first { $0.id == remembered } ?? team.macs.first
        link.send(.target(mac.map { LinkMachine.Target(macID: $0.id, name: $0.name, isOnline: $0.isOnline) }))
    }

    public func select(macID: String) {
        guard let team = store.activeTeam else { return }
        UserDefaults.standard.set(macID, forKey: "cnx.live.mac.\(team.id)")
        retarget()
    }

    // MARK: Prefs and invites

    private func loadPrefs(_ teamID: String) {
        Task { [weak self] in
            guard let self, let prefs = try? await self.api.prefs(teamID: teamID),
                  let color = prefs.color, color.hasPrefix("#") else { return }
            self.store.setAppearance(TeamAppearance(colorHex: color, emoji: prefs.emoji), for: teamID)
        }
    }

    /// Saves a team's color and emoji locally and with `PUT /prefs`.
    public func saveAppearance(_ appearance: TeamAppearance, teamID: String) async throws {
        store.setAppearance(appearance, for: teamID)
        try await api.putPrefs(teamID: teamID, color: appearance.colorHex, emoji: appearance.emoji)
    }

    public func invite(email: String, teamID: String) async throws {
        try await api.invite(teamID: teamID, email: email)
    }

    // MARK: Transport and lifecycle

    public func setTransport(_ transport: CnxTransport.TransportKind) {
        link.send(.transport(transport))
    }

    /// Debug relay-only mode (Settings → Developer); a change redials.
    public func setRelayOnly(_ relayOnly: Bool) {
        link.send(.relayOnly(relayOnly))
    }

    /// App foreground: probe or redial the link and the presence socket.
    public func foreground() {
        presence?.kick()
        link.send(.foreground)
    }

    // MARK: Link

    private func linkChanged(_ link: (any MacLink)?) {
        acpmux.macLink = link
        currentLink = link
        guard let link, let macID = self.link.target?.macID else {
            Task {
                await workspaces.bind(nil, macID: "")
                await acpmux.bind(nil)
            }
            if chiefLive {
                ChiefSession.shared.use(ChiefMockBackend())
                chiefLive = false
            }
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let daemon = try await link.openChannel(service: "daemon", args: [:])
                await self.workspaces.bind(daemon, macID: macID)
            } catch {
                log.error("daemon channel: \(String(describing: error), privacy: .public)")
            }
            do {
                let channel = try await link.openChannel(service: "acpmux", args: [:])
                await self.acpmux.bind(channel)
            } catch {
                log.error("acpmux channel: \(String(describing: error), privacy: .public)")
            }
            await self.startChief(link)
        }
        // Terminal tabs attach lazily (`terminalSession(tabID:)`), each on its
        // own `daemon` channel of this link.
    }

    /// A live session for a terminal tab of the linked Mac (`s<surface>`), or
    /// nil when the tab is not a daemon surface or there is no link. The
    /// channel opens when the screen starts the session.
    public func terminalSession(tabID: String, programName: String) -> DaemonTerminalSession? {
        guard currentLink != nil, let surface = workspaces.tree?.surfaces[tabID] else { return nil }
        return DaemonTerminalSession(surface: surface, programName: programName) { [weak self] in
            guard let link = await self?.currentLink else { throw LinkError(code: "no-link", message: "Not connected to the Mac") }
            let channel = try await link.openChannel(service: "daemon", args: [:])
            return DaemonClient(channel: channel)
        }
    }

    /// Chief over the daemon's local conversations, when the Mac's link allows them.
    private func startChief(_ link: any MacLink) async {
        do {
            let channel = try await link.openChannel(service: "daemon", args: [:])
            let client = DaemonClient(channel: channel)
            let probe = try await client.request("conversation-list", params: [:])
            if let object = try? JSONSerialization.jsonObject(with: probe) as? [String: Any], object["ok"] as? Bool == false {
                chiefStatus = "Chief on this Mac: \(object["error"] as? String ?? "unavailable")"
                await channel.close(code: "eof", reason: "chief unavailable")
                log.info("chief unavailable: \(self.chiefStatus ?? "", privacy: .public)")
                return
            }
            ChiefSession.shared.use(ChiefDaemonBackend(client: client))
            chiefLive = true
            chiefStatus = nil
        } catch {
            chiefStatus = "Chief on this Mac: \(LinkController.reason(error))"
        }
    }

    private func apply(_ tree: DaemonTree) {
        guard let macID = link.target?.macID else { return }
        self.tree = tree
        store.replaceWorkspaces(macID: macID, with: tree.workspaces)
    }

    private func place(sessionID: String) -> LiveFeed.Place? {
        guard let tree else { return nil }
        for workspace in tree.workspaces {
            for tab in workspace.tabs where tree.agentTabs[tab.id]?.session == sessionID {
                return LiveFeed.Place(workspaceID: workspace.id, tabID: tab.id, workspaceTitle: workspace.title)
            }
        }
        return nil
    }

    // MARK: Status and banner (SPEC 7.4)

    private func observeLink() {
        withObservationTracking {
            _ = link.phase
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.phaseChanged()
                self?.observeLink()
            }
        }
    }

    private func phaseChanged() {
        let phase = link.phase
        let target = link.target
        var status = store.macLinkStatus
        status = [:]
        if let target, let line = phase.statusLine(macName: target.name) { status[target.macID] = line }
        if status != store.macLinkStatus { store.macLinkStatus = status }
        bannerTask?.cancel()
        let name = target?.name ?? "Mac"
        switch phase {
        case .idle:
            banner = nil
        case .macOffline:
            banner = .macOffline(name)
        case .connected:
            if everConnected, banner != nil, banner != .connected {
                banner = .connected
                bannerTask = Task { [weak self, clock] in
                    do { try await clock.sleep(for: .milliseconds(1500)) } catch { return }
                    self?.banner = nil
                }
            } else {
                banner = nil
            }
            everConnected = true
        case .connecting(let transport, let attempt):
            // Blips heal silently: the reconnecting banner waits 1.5 s.
            if attempt == 1, !everConnected {
                banner = .connecting(to: "\(name) over \(transport.displayName)")
            } else if banner == nil || banner == .connected {
                bannerTask = Task { [weak self, clock] in
                    do { try await clock.sleep(for: .milliseconds(1500)) } catch { return }
                    self?.banner = .reconnecting(to: name)
                }
            }
        case .waiting(let transport, _, _, _):
            banner = .failed("Can't reach \(name) over \(transport.displayName)")
        }
    }
}

/// An agent tab with no acpmux session yet (a new chat the Mac has not started).
@MainActor
final class UnboundAgentSource: AgentSessionSource {
    let summary: AgentSessionSummary

    init(summary: AgentSessionSummary) {
        self.summary = summary
    }

    func events() -> AsyncStream<AgentSessionEvent> {
        AsyncStream { continuation in
            continuation.yield(.clientError("This chat hasn't started on the Mac yet."))
        }
    }

    func send(_ intent: AgentClientIntent) {}

    var artifactSource: any ArtifactSource {
        LinkFileArtifactSource(macName: summary.macName, baseDirectory: summary.cwd) { nil }
    }
}
#endif
