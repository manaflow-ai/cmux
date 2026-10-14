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

/// Wires the signed-in app to real data, from sign-in on (setup included):
/// registers this phone in the active team (the personal space
/// `personal-<userId>` when the account has no teams), keeps the team's Macs
/// live from presence, finds the account's Macs in every other team and the
/// personal space (`GET /v1/me/macs`) and moves to the one where a Mac is,
/// holds a link to the selected online Mac over the Settings transport, and
/// feeds the daemon's workspaces, acpmux chats, the Feed and Chief from that
/// link.
@MainActor
@Observable
public final class LiveCoordinator {
    public private(set) var banner: ConnectionBannerState?
    public private(set) var registeredTeamID: String?
    public private(set) var presenceConnected = false
    public private(set) var chiefStatus: String?
    /// The last time the phone moved to another team because one of the
    /// account's Macs is there (the shell shows a toast).
    public private(set) var followed: Followed?

    /// A move to the team where the account's Mac is.
    public struct Followed: Equatable, Sendable {
        public let serial: Int
        public let teamID: String
        public let teamName: String
        public let macName: String
    }

    /// Called after a move to another team (persists the Stack selection).
    @ObservationIgnored public var onFollow: ((String) -> Void)?

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
    /// The acpmux session each cached chat store was built for (nil: unbound).
    @ObservationIgnored private var sourcedSessions: [String: String?] = [:]
    /// The link to the targeted Mac, for terminal tabs (each attaches on its own channel).
    @ObservationIgnored private var currentLink: (any MacLink)?
    /// Terminal tabs handed out, reattached on every new link.
    @ObservationIgnored private var terminals: [WeakTerminal] = []
    private struct WeakTerminal { weak var session: DaemonTerminalSession? }
    @ObservationIgnored private var chiefLive = false
    @ObservationIgnored private var discoveryTask: Task<Void, Never>?
    /// The account's Macs that were online at the last look (nil before the first).
    @ObservationIgnored private var previouslyOnline: Set<String>?
    /// A team the user picked in the sidebar: discovery leaves it while it is empty.
    @ObservationIgnored private var pinnedTeamID: String?
    /// What this account last saw (restored at launch, saved as it changes).
    @ObservationIgnored private let snapshots: LiveSnapshotStore
    @ObservationIgnored private var snapshot: LiveSnapshot?
    @ObservationIgnored private var snapshotSavePending = false
    /// The team whose registration, Macs and presence are running or done.
    @ObservationIgnored private var startedTeamID: String?
    /// The Mac whose data and connection state the link last fed.
    @ObservationIgnored private var dataMacID: String?
    /// Macs whose cnx host predates the `version` service (link protocol 1):
    /// they work, but drop links under load; the status line says to update.
    @ObservationIgnored private var outdatedMacs: Set<String> = []
    /// How often discovery looks while the active team has no online Mac, and otherwise.
    static let waitingPoll: Duration = .seconds(4)
    static let idlePoll: Duration = .seconds(30)

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
        snapshots: LiveSnapshotStore = .standard,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        ConnectTimeline.shared.mark("coordinator_start")
        self.snapshots = snapshots
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
        // The Feed as this phone last saw it; the Mac's history merges in on connect.
        let archive = FeedArchive.forAccount(userID)
        feedStore.replaceAll(archive.load())
        feedStore.onItemsChange = { [weak self] _ in self?.scheduleFeedSave(archive) }
        feedStore.actions = feed
        feedStore.syncState = .connecting
        store.workspaces = []
        store.tracksMacData = true
        store.macData = [:]
        store.macConnection = [:]
        store.teamDataState = .loading
        link.onLink = { [weak self] link in self?.linkChanged(link) }
        workspaces.onTree = { [weak self] tree in self?.apply(tree) }
        acpmux.onWatchEvent = { [weak self] event in
            guard let self else { return }
            self.feed.handle(event, sessions: self.acpmux.sessions)
            self.workspaces.setPending(self.acpmux.sessions.mapValues { $0.pendingPermissions > 0 })
        }
        AgentSessionDirectory.shared.makeSource = { [weak self] summary in
            let session = self?.tree?.agentTabs[summary.id]?.session
            self?.sourcedSessions[summary.id] = .some(session)
            guard let self, let session else {
                return UnboundAgentSource(summary: summary, macName: self?.link.target?.name)
            }
            return self.acpmux.source(sessionID: session, summary: summary)
        }
        observeLink()
        restoreSnapshot()
    }

    // MARK: Warm start

    /// Launch with a snapshot: show the space, its Macs and their last-known
    /// workspaces (marked cached), warm the signaling socket, and dial the
    /// Mac this phone last reached, all before Stack's team list or the
    /// service's Mac list answers. Registration, Macs and presence start at
    /// once in the background and correct anything that changed.
    private func restoreSnapshot() {
        guard let snapshot = snapshots.load(accountID: userID) else { return }
        self.snapshot = snapshot
        store.teams = [Team(id: snapshot.teamID, name: snapshot.teamName, macs: snapshot.macs)]
        store.activeTeamID = snapshot.teamID
        var workspaces: [Workspace] = []
        for mac in snapshot.macs {
            guard let saved = snapshot.workspaces[mac.id] else { continue }
            workspaces += saved.workspaces
            store.handleMacData(.restored(count: saved.workspaces.count, savedAt: saved.savedAt), macID: mac.id)
        }
        store.workspaces = workspaces
        store.teamDataState = .loaded
        ConnectTimeline.shared.mark("snapshot_restored", detail: "\(workspaces.count) workspaces")
        // The link device was registered in this space when the snapshot was
        // saved (registration is an upsert and survives), so the socket and
        // the dial need not wait for it.
        registeredTeamID = snapshot.teamID
        link.prewarm(baseURL: api.baseURL, teamID: snapshot.teamID, deviceID: identity.link)
        retarget()
        startedTeamID = snapshot.teamID
        teamTask = Task { [weak self] in await self?.startTeam(snapshot.teamID, warm: true) }
    }

    /// Saves what the phone sees now (coalesced to one write per main-queue turn).
    private func scheduleSnapshotSave() {
        guard !snapshotSavePending else { return }
        snapshotSavePending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            snapshotSavePending = false
            saveSnapshot()
        }
    }

    private func saveSnapshot() {
        guard let team = store.activeTeam, registeredTeamID == team.id else { return }
        var saved = snapshot?.teamID == team.id ? snapshot?.workspaces ?? [:] : [:]
        let macIDs = Set(team.macs.map(\.id))
        saved = saved.filter { macIDs.contains($0.key) }
        for mac in team.macs where store.macData[mac.id]?.source == .live {
            saved[mac.id] = .init(workspaces: store.workspaces.filter { $0.macID == mac.id && !store.isPending($0.id) }, savedAt: Date())
        }
        let next = LiveSnapshot(teamID: team.id, teamName: team.name, macs: team.macs,
                                linkedMacID: link.target?.macID ?? snapshot?.linkedMacID, workspaces: saved)
        guard next != snapshot else { return }
        snapshot = next
        snapshots.save(next, accountID: userID)
    }

    // MARK: Teams

    private var personal: AppStore.AccountTeam {
        AppStore.AccountTeam(id: Self.personalTeamID(userID: userID), name: "Personal")
    }

    /// Applies the account's teams (or the personal space) and starts the
    /// active one. The personal space stays listed next to Stack teams while
    /// one of the account's Macs is in it. Starts Mac discovery.
    public func applyAccountTeams(_ teams: [AppStore.AccountTeam], selectedID: String?) {
        var list = teams.isEmpty ? [personal] : teams
        if !teams.isEmpty, store.teams.contains(where: { $0.id == personal.id && !$0.macs.isEmpty }) { list.append(personal) }
        // A team the phone already shows (picked, or followed to a Mac) stays active.
        let keep = list.contains { $0.id == store.activeTeamID } ? store.activeTeamID : selectedID
        store.applyLiveTeams(list, selectedID: keep)
        activeTeamChanged()
        for team in list { loadPrefs(team.id) }
        if discoveryTask == nil { startDiscovery() }
    }

    /// Call after `store.selectTeam`: re-registers, reloads Macs, re-targets
    /// the link. `byUser` marks a sidebar pick, which discovery respects.
    public func activeTeamChanged(byUser: Bool = false) {
        let teamID = store.activeTeamID
        if byUser { pinnedTeamID = teamID }
        guard !teamID.isEmpty, teamID != registeredTeamID, teamID != startedTeamID else { return }
        startedTeamID = teamID
        teamTask?.cancel()
        presence?.stop()
        presence = nil
        registeredTeamID = nil
        store.teamDataState = .loading
        link.send(.target(nil))
        teamTask = Task { [weak self] in await self?.startTeam(teamID) }
    }

    /// Registers both device ids, then loads the Macs and starts presence.
    /// `warm`: the link is already dialing in this team from the snapshot,
    /// so nothing on screen is reset while this runs.
    private func startTeam(_ teamID: String, warm: Bool = false) async {
        do {
            // Both registrations at once (one round trip, not two).
            async let linkDevice: Void = api.registerDevice(id: identity.link, kind: "phone", name: deviceName, teamID: teamID)
            async let presenceDevice: Void = api.registerDevice(id: identity.presence, kind: "phone", name: "\(deviceName) (presence)", teamID: teamID)
            try await linkDevice
            if !warm {
                // The link device is registered: warm its socket while the rest loads.
                link.prewarm(baseURL: api.baseURL, teamID: teamID, deviceID: identity.link)
            }
            try await presenceDevice
            ConnectTimeline.shared.mark("registered")
            guard !Task.isCancelled, store.activeTeamID == teamID else { return }
            registeredTeamID = teamID
            let macs = try await api.macs(teamID: teamID)
            guard !Task.isCancelled, store.activeTeamID == teamID else { return }
            ConnectTimeline.shared.mark("macs_loaded", detail: "\(macs.count)")
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
            // A warm start keeps its cached list; the retry below catches up.
            if !warm { store.teamDataState = .failed }
            // Try again on its own (the list's Retry also works).
            do { try await clock.sleep(for: .seconds(5)) } catch { return }
            guard store.activeTeamID == teamID, registeredTeamID == nil || warm else { return }
            await startTeam(teamID, warm: warm)
        }
    }

    /// Retry after a failed team load (the Workspaces Retry button).
    public func retry() {
        registeredTeamID = nil
        startedTeamID = nil
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
        scheduleSnapshotSave()
    }

    /// Dials the selected Mac (remembered per team), else the first online one.
    private func retarget() {
        guard let team = store.activeTeam, registeredTeamID == team.id else { return }
        let remembered = UserDefaults.standard.string(forKey: "cnx.live.mac.\(team.id)")
            ?? (snapshot?.teamID == team.id ? snapshot?.linkedMacID : nil)
        let mac = LinkMachine.target(in: team.macs, remembered: remembered, current: link.target?.macID)
        link.send(.target(mac.map { LinkMachine.Target(macID: $0.id, name: $0.name, isOnline: $0.isOnline) }))
    }


    public func select(macID: String) {
        guard let team = store.activeTeam else { return }
        UserDefaults.standard.set(macID, forKey: "cnx.live.mac.\(team.id)")
        retarget()
    }

    // MARK: Discovery across spaces

    private func startDiscovery() {
        discoveryTask?.cancel()
        discoveryTask = Task { [weak self] in await self?.discover() }
    }

    private func discover() async {
        while !Task.isCancelled {
            await discoverOnce()
            let waiting = !(store.activeTeam?.macs.contains(where: \.isOnline) ?? false)
            do { try await clock.sleep(for: waiting ? Self.waitingPoll : Self.idlePoll) } catch { return }
        }
    }

    /// One look at the account's Macs everywhere: shows each in its team and
    /// moves to the team of an online Mac while the active team has none.
    func discoverOnce() async {
        do {
            let macs = try await api.myMacs()
            guard !Task.isCancelled else { return }
            let found = macs.compactMap { mac -> DiscoveredMac? in
                guard let teamID = mac.teamId else { return nil }
                return DiscoveredMac(id: mac.deviceId, name: mac.name, isOnline: mac.online, lastSeenAt: mac.lastSeenDate, teamID: teamID)
            }
            store.mergeDiscoveredMacs(found, personal: personal)
            if store.accountMacCount != found.count { store.accountMacCount = found.count }
            if let team = store.teamToFollow(found, previouslyOnline: previouslyOnline, pinnedTeamID: pinnedTeamID) {
                follow(team, macName: found.first { $0.teamID == team.id && $0.isOnline }?.name ?? "Your Mac")
            }
            previouslyOnline = Set(found.filter(\.isOnline).map(\.placement))
            retarget()
        } catch {
            guard !Task.isCancelled else { return }
            log.error("Mac discovery failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func follow(_ team: Team, macName: String) {
        log.info("following \(macName, privacy: .private) to team \(team.id, privacy: .private)")
        store.selectTeam(team.id)
        activeTeamChanged()
        followed = Followed(serial: (followed?.serial ?? 0) + 1, teamID: team.id, teamName: team.name, macName: macName)
        onFollow?(team.id)
    }

    /// Sign-out: stops discovery, presence and the link.
    public func stop() {
        discoveryTask?.cancel()
        discoveryTask = nil
        teamTask?.cancel()
        presence?.stop()
        presence = nil
        registeredTeamID = nil
        startedTeamID = nil
        link.send(.target(nil))
        let link = link
        Task { await link.resetWarmState() }
    }

    /// Sign-out: forget every account's snapshot on this device.
    public static func forgetSnapshots(_ snapshots: LiveSnapshotStore = .standard) {
        snapshots.removeAll()
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
        log.info("foreground: \(String(describing: self.link.phase), privacy: .public)")
        // The first activation is the launch itself, already being measured.
        if ConnectTimeline.shared.sinceProcessStart > 5 { ConnectTimeline.shared.begin("foreground") }
        if let teamID = registeredTeamID {
            link.prewarm(baseURL: api.baseURL, teamID: teamID, deviceID: identity.link)
        }
        presence?.kick()
        if discoveryTask != nil { startDiscovery() }
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
        // Workspaces first, and the chats and Feed alongside: each channel
        // opens without waiting for the other (an open costs no round trip).
        Task { [weak self] in
            guard let self else { return }
            do {
                let daemon = try await link.openChannel(service: "daemon", args: [:])
                ConnectTimeline.shared.mark("daemon_channel_open")
                await self.workspaces.bind(daemon, macID: macID)
            } catch {
                log.error("daemon channel: \(String(describing: error), privacy: .public)")
            }
        }
        Task { [weak self] in await self?.checkVersion(link, macID: macID) }
        Task { [weak self] in
            guard let self else { return }
            do {
                let channel = try await link.openChannel(service: "acpmux", args: [:])
                await self.acpmux.bind(channel)
                if self.acpmux.isReady { self.feed.store.syncState = .live }
            } catch {
                log.error("acpmux channel: \(String(describing: error), privacy: .public)")
            }
            await self.startChief(link)
        }
        // Terminal tabs attach lazily (`terminalSession(tabID:)`), each on its
        // own `daemon` channel of this link; open ones reattach now.
        terminals.removeAll { $0.session == nil }
        for terminal in terminals { terminal.session?.reconnect() }
    }

    /// Asks the Mac's host which link protocol it speaks. A host that refuses
    /// the `version` service is from before link protocol 2 (control frames
    /// ahead of data, no reader stalls) and drops links under load.
    private func checkVersion(_ link: any MacLink, macID: String) async {
        guard let channel = try? await link.openChannel(service: "version", args: [:]) else { return }
        let reply = try? await channel.receive()
        await channel.close(code: "eof", reason: "")
        let object = reply.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let protocolVersion = object?["link"] as? Int ?? 1
        log.info("Mac host: \(object?["hostd"] as? String ?? "before 0.2", privacy: .public), link protocol \(protocolVersion, privacy: .public)")
        let outdated = protocolVersion < 2
        guard outdated != outdatedMacs.contains(macID) else { return }
        if outdated { outdatedMacs.insert(macID) } else { outdatedMacs.remove(macID) }
        phaseChanged()
    }

    /// A live session for a terminal tab of the Mac (`s<surface>`), or nil
    /// when the tab is not a daemon surface. The channel opens when the screen
    /// starts the session; without a link it says so and attaches when the
    /// link comes back (as after any drop).
    public func terminalSession(tabID: String, programName: String) -> DaemonTerminalSession? {
        guard let surface = workspaces.tree?.surfaces[tabID] else { return nil }
        // The daemon titles a shell tab with its folder; the composer says "Send to <program>".
        let program = programName.hasPrefix("/") || programName.hasPrefix("~") || programName.isEmpty ? "terminal" : programName
        let session = DaemonTerminalSession(surface: surface, programName: program) { [weak self] in
            guard let link = await self?.currentLink else { throw LinkError(code: "no-link", message: "Not connected to the Mac") }
            let channel = try await link.openChannel(service: "daemon", args: [:])
            return DaemonClient(channel: channel)
        }
        terminals.removeAll { $0.session == nil }
        terminals.append(WeakTerminal(session: session))
        return session
    }

    /// Files and Links previews for a terminal tab: real files on the linked
    /// Mac over the `file` service, relative paths resolved against the tab's
    /// directory.
    public func terminalArtifactSource(tabID: String) -> any ArtifactSource {
        LinkFileArtifactSource(macName: link.target?.name ?? "your Mac", baseDirectory: workspaces.tree?.directories[tabID]) { [weak self] in
            await self?.currentLink
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
        // A chat opened before its tab had a session (a new chat the Mac
        // started later, or a tab shown from the list before the tree came)
        // was built unbound and cached; rebuild it on the bound session.
        for (tabID, used) in sourcedSessions where tree.agentTabs[tabID]?.session != used {
            sourcedSessions[tabID] = nil
            AgentSessionDirectory.shared.invalidate(id: tabID)
        }
        store.replaceWorkspaces(macID: macID, with: tree.workspaces)
        store.handleMacData(.received(count: tree.workspaces.count), macID: macID)
        ConnectTimeline.shared.mark("workspaces_live", detail: "\(tree.workspaces.count) workspaces")
        scheduleSnapshotSave()
        // History items name their workspace and tab once the tree places their session.
        if acpmux.isReady { feed.hydrate(Array(acpmux.sessions.values)) }
    }

    @ObservationIgnored private var feedSavePending = false

    /// One write per main-queue turn, however many items a burst changed.
    private func scheduleFeedSave(_ archive: FeedArchive) {
        guard !feedSavePending else { return }
        feedSavePending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            feedSavePending = false
            archive.save(feed.store.items)
        }
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

    /// Feeds the targeted Mac's data and connection state from the link phase.
    private func updateMacState(_ phase: LinkMachine.Phase, target: LinkMachine.Target?) {
        if let old = dataMacID, old != target?.macID {
            store.handleMacData(.disconnected(at: Date()), macID: old)
            store.macConnection[old] = nil
        }
        dataMacID = target?.macID
        guard let macID = target?.macID else { return }
        switch phase {
        case .idle:
            break
        case .macOffline:
            store.handleMacData(.offline, macID: macID)
            store.macConnection[macID] = nil
        case .connecting:
            if store.macData[macID]?.source == .live { store.handleMacData(.disconnected(at: Date()), macID: macID) }
            store.handleMacData(.connecting, macID: macID)
            if store.macConnection[macID] == nil || store.macConnection[macID] == .connected {
                store.macConnection[macID] = .connecting
            }
        case .connected:
            store.macConnection[macID] = .connected
        case .waiting(_, _, let reason, _):
            store.handleMacData(.failed(reason), macID: macID)
            store.macConnection[macID] = .failed(reason)
        }
        scheduleSnapshotSave()
    }

    private func phaseChanged() {
        let phase = link.phase
        let target = link.target
        updateMacState(phase, target: target)
        var status = store.macLinkStatus
        status = [:]
        if let target, let line = phase.statusLine(macName: target.name) {
            status[target.macID] = outdatedMacs.contains(target.macID) ? line + " · Update cmux on this Mac" : line
        }
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
        case .waiting(let transport, _, let reason, _):
            // An offline Mac is not a connection failure.
            banner = reason == LinkController.reason(LinkError(code: "offline", message: ""))
                ? .macOffline(name) : .failed("Can't reach \(name) over \(transport.displayName)")
        }
    }
}

/// An agent tab with no acpmux session yet: a new chat on the Mac that has
/// not had its first message. The Mac starts a chat's session from its own
/// first send (the daemon starts only `registry:` tabs), so the phone says so;
/// once the Mac binds the session the coordinator rebuilds the store live.
@MainActor
final class UnboundAgentSource: AgentSessionSource {
    let summary: AgentSessionSummary
    let macName: String

    init(summary: AgentSessionSummary, macName: String?) {
        self.summary = summary
        self.macName = macName ?? summary.macName
    }

    static func notStarted(agent: String, mac: String) -> String {
        "\(agent) hasn't started in this tab yet. Send the first message from cmux on \(mac); the chat continues here."
    }

    private var continuations: [AsyncStream<AgentSessionEvent>.Continuation] = []

    func events() -> AsyncStream<AgentSessionEvent> {
        let (stream, continuation) = AsyncStream<AgentSessionEvent>.makeStream()
        continuation.yield(.clientError(Self.notStarted(agent: summary.agentName, mac: macName)))
        continuations.append(continuation)
        return stream
    }

    /// A prompt can't start the chat from the phone: say why again.
    func send(_ intent: AgentClientIntent) {
        let message = Self.notStarted(agent: summary.agentName, mac: macName)
        for continuation in continuations { continuation.yield(.clientError(message)) }
    }

    var artifactSource: any ArtifactSource {
        LinkFileArtifactSource(macName: summary.macName, baseDirectory: summary.cwd) { nil }
    }
}
#endif
