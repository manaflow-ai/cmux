#if os(iOS)
import CnxAgentChat
import CnxArtifacts
import CnxBrowserStream
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
    /// Pairing with the linked Mac (verify/phone-approvals.md): the Mac asks the
    /// user the first time; Allow then signs with Face ID.
    public private(set) var pairingState: LinkPairing.State = .idle
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
    /// A Mac left the account (removed here or on another device), after
    /// the store forgot it: screens showing one of its workspaces close.
    @ObservationIgnored public var onMacRemoved: ((String) -> Void)?

    public let link: LinkController
    public let workspaces: WorkspaceSync
    public let acpmux = AcpmuxHub()
    /// This phone's APNs registration (the token goes on the link device id).
    public let push = PushRegistration.shared
    /// Whether the service could include a TURN relay in `GET /v1/ice` (nil
    /// before the first look). Without one, WebRTC outside the Mac's network
    /// may fail, and the app says so.
    public private(set) var relayAvailable: Bool?
    @ObservationIgnored public let feed: LiveFeed
    /// Terminal agents' events in the Feed (the daemon's notification ledger).
    @ObservationIgnored public let terminalFeed: TerminalFeed

    @ObservationIgnored let store: AppStore
    @ObservationIgnored let api: LiveAPI
    @ObservationIgnored let identity: DeviceIdentity
    /// Where `identity` and the pairing keys are kept (the Keychain; memory in tests).
    @ObservationIgnored let secrets: any DeviceSecretStore
    @ObservationIgnored let userID: String
    @ObservationIgnored let deviceName: String
    /// The phone's keys; nil (tests, mock) skips pairing.
    @ObservationIgnored let pairing: LinkPairing?
    @ObservationIgnored let clock: any Clock<Duration>
    @ObservationIgnored private var presence: PresenceListener?
    @ObservationIgnored private var teamTask: Task<Void, Never>?
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    @ObservationIgnored private var everConnected = false
    @ObservationIgnored private var tree: DaemonTree?
    /// The acpmux session each cached chat store was built for (nil: unbound).
    @ObservationIgnored private var sourcedSessions: [String: String?] = [:]
    /// The link to the targeted Mac (identity: a newer link replaces it).
    @ObservationIgnored private var currentLink: (any MacLink)?
    /// `currentLink` once its `auth` channel opened (at once without pairing keys): what
    /// terminal tabs, files, uploads and browser tabs open their channels on, so none of
    /// them reaches the Mac ahead of `auth` (hostd refuses those `unpaired`).
    @ObservationIgnored private var servedLink: (any MacLink)?
    /// The pairing run on a link: input-lane channels (another stream, which can
    /// overtake `auth`) wait for it (review m6), and Retry re-runs a refused one (M2).
    @ObservationIgnored private var pairingGate: (link: any MacLink, passed: Task<Bool, Never>)?
    /// The account was deleted: sign-out keeps nothing of it.
    @ObservationIgnored public private(set) var accountDeleted = false
    /// Signed out: nothing more is saved for the account.
    @ObservationIgnored private var stopped = false
    /// "Remove This iPhone from My Macs" is running.
    @ObservationIgnored private var removalRunning = false
    /// How many times this phone was removed from its Macs (tests).
    @ObservationIgnored public private(set) var removedFromMacsCount = 0
    /// Terminal tabs handed out, reattached on every new link.
    @ObservationIgnored private var terminals: [WeakTerminal] = []
    /// A terminal session and the Mac it belongs to.
    private struct WeakTerminal {
        weak var session: DaemonTerminalSession?
        var macID: String?
    }
    /// Whether terminal tabs say their Mac is offline (termfix-r13 D4).
    @ObservationIgnored private var terminalsOffline = false
    /// When the link last stopped being connected (nil: connected or idle).
    @ObservationIgnored private var linkDownSince: ContinuousClock.Instant?
    @ObservationIgnored private var offlineTask: Task<Void, Never>?
    @ObservationIgnored private var chiefLive = false
    /// A `startChief` is opening the channel (Try Again does not start a second one).
    @ObservationIgnored private var chiefStarting = false
    @ObservationIgnored private var discoveryTask: Task<Void, Never>?
    /// Follows the phone's network (Wi-Fi, cellular, airplane mode).
    @ObservationIgnored private var networkTask: Task<Void, Never>?
    /// The account's Macs that were online at the last look (nil before the first).
    @ObservationIgnored private var previouslyOnline: Set<String>?
    /// The account's own Macs at the last discovery (nil before the first):
    /// one that drops out of the list was removed elsewhere.
    @ObservationIgnored private var discoveredMacIDs: Set<String>?
    /// Macs removed from this phone, against answers already on their way.
    @ObservationIgnored private var removedMacs = RemovedMacs()
    /// A team the user picked in the sidebar: discovery leaves it while it is empty.
    @ObservationIgnored private var pinnedTeamID: String?
    /// What this account last saw (restored at launch, saved as it changes).
    @ObservationIgnored private let snapshots: LiveSnapshotStore
    @ObservationIgnored private var snapshot: LiveSnapshot?
    @ObservationIgnored private var snapshotSavePending = false
    /// The team whose registration, Macs and presence are running or done.
    @ObservationIgnored private var startedTeamID: String?
    /// The team the Feed's items came from. Feed items carry no Mac, so on a switch they
    /// go (the new team's Macs fill it on connect): an old team's ask answered here went to
    /// the new team's Mac and failed, or reached the wrong one.
    @ObservationIgnored private var feedTeamID: String?
    /// The Mac whose data and connection state the link last fed.
    @ObservationIgnored private var dataMacID: String?
    /// Macs whose cnx host predates the `version` service (link protocol 1):
    /// they work, but drop links under load; the status line says to update.
    @ObservationIgnored private var outdatedMacs: Set<String> = []
    /// Why the chat (acpmux) channel failed on the current link, shown in the status line.
    @ObservationIgnored private var chatsError: String?
    @ObservationIgnored private var workspacesTimeout: Task<Void, Never>?
    /// How long a connected Mac may take to send its workspace list before
    /// the list says it could not load them (with Retry), instead of a
    /// skeleton that never ends.
    static let workspacesDeadline: Duration = .seconds(10)
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
        blockUDP: Bool = false,
        dialer: any MacLinkDialer,
        feedStore: FeedStore = .shared,
        keys: PhoneKeys? = nil,
        snapshots: LiveSnapshotStore = .standard,
        secrets: any DeviceSecretStore = KeychainSecretStore(),
        readMarks: FeedReadMarks? = nil,
        pins: MacPins? = nil,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.secrets = secrets
        ConnectTimeline.shared.mark("coordinator_start")
        self.snapshots = snapshots
        self.store = store
        self.api = api
        self.identity = identity
        self.userID = userID
        self.deviceName = deviceName
        pairing = keys.map { LinkPairing(keys: $0, phoneID: identity.link, name: deviceName, pins: pins ?? .forAccount(userID)) }
        self.clock = clock
        workspaces = WorkspaceSync(deviceID: identity.link, deviceName: deviceName)
        let apiForLink = api
        link = LinkController(transport: transport, relayOnly: relayOnly, blockUDP: blockUDP, dialer: dialer, clock: clock,
                              accessToken: { try await apiForLink.accessToken($0) })
        // The default Chief is the account's Cloud Chief (same sign-in);
        // the Mac Chief below stays reachable beside it.
        ChiefSources.shared.start(userID: userID) { try await apiForLink.accessToken($0) }
        feed = LiveFeed(store: feedStore, hub: nil, place: { _ in nil })
        terminalFeed = TerminalFeed(store: feedStore)
        link.endpoint = { [weak self] macID in
            guard let self, let teamID = self.registeredTeamID else { return nil }
            return LinkEndpoint(baseURL: self.api.baseURL, teamID: teamID, deviceID: self.identity.link, macDeviceID: macID)
        }
        feed.place = { [weak self] sessionID in self?.place(sessionID: sessionID) }
        feed.hub = acpmux
        feed.terminal = terminalFeed
        terminalFeed.request = { [weak self] command, params, connection in
            // Never another connection's (or another Mac's) channel.
            guard let self, self.workspaces.connectionSerial == connection, let client = self.workspaces.daemon else {
                throw LinkError(code: "no-link", message: "Not connected to the Mac")
            }
            var fields: [String: Any] = [:]
            for (key, value) in params { fields[key] = value }
            return try await client.request(command, params: fields)
        }
        // The Feed as this phone last saw it; the Mac's history merges in on connect.
        let archive = FeedArchive.forAccount(userID)
        feedStore.useReadMarks(readMarks ?? .forAccount(userID))
        feedStore.replaceAll(archive.load())
        feedStore.onItemsChange = { [weak self] items in
            self?.scheduleFeedSave(archive)
            self?.terminalFeed.itemsChanged(items)
        }
        feedStore.actions = feed
        feedStore.syncState = .connecting
        store.workspaces = []
        store.tracksMacData = true
        store.macData = [:]
        store.macConnection = [:]
        store.teamDataState = .loading
        link.onLink = { [weak self] link in self?.linkChanged(link) }
        // Right after each dial, off the main actor: open `auth` then `daemon`
        // (in that order: a Mac that pairs serves channels opened behind
        // `auth`) and send the workspace setup batch.
        let pairing = pairing
        let deviceID = identity.link
        link.prepare = { link, _ in
            await Self.prepareLink(link, pairing: pairing, deviceID: deviceID, deviceName: deviceName)
        }
        workspaces.onTree = { [weak self] tree in self?.apply(tree) }
        workspaces.onNotification = { [weak self] in self?.terminalFeed.notificationPosted() }
        acpmux.onWatchEvent = { [weak self] event in
            guard let self else { return }
            self.feed.handle(event, sessions: self.acpmux.sessions)
            self.workspaces.setPending(self.acpmux.sessions.mapValues { $0.pendingPermissions > 0 }, waitingFor: self.feed.waitingFor)
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
        watchNetwork()
    }

    // MARK: Network changes

    #if DEBUG
    private static var networkProbeStarted = false

    /// DEBUG: launched with `CNX_NETWORK_PROBE=roam` (or `loss`, no roam),
    /// measure a simulated network change once, `CNX_NETWORK_PROBE_DELAY`
    /// seconds (default 3) after the first link comes up, and log the result
    /// as `network_probe {json}`.
    private func runNetworkProbeIfAsked(_ link: any MacLink) {
        guard !Self.networkProbeStarted, let mode = ProcessInfo.processInfo.environment["CNX_NETWORK_PROBE"],
              let probing = link as? any NetworkChangeProbing else { return }
        Self.networkProbeStarted = true
        let roam = mode != "loss"
        let delay = Double(ProcessInfo.processInfo.environment["CNX_NETWORK_PROBE_DELAY"] ?? "") ?? 3
        let clock = clock
        Task.detached {
            try? await clock.sleep(for: .seconds(delay))
            log.notice("network_probe start roam=\(roam, privacy: .public)")
            let result = await probing.networkChangeProbe(roam: roam, windowMillis: roam ? 3000 : 20000)
            log.notice("network_probe \(result, privacy: .public)")
        }
    }
    #endif

    private func watchNetwork() {
        let monitor = NetworkPathMonitor()
        networkTask = Task { [weak self] in
            for await event in monitor.events {
                guard let self else { return }
                self.networkPathChanged(event)
            }
        }
    }

    /// The phone moved to another network or lost it: links roam in place
    /// (no redial), presence reconnects.
    func networkPathChanged(_ event: NetworkPathEvent) {
        switch event {
        case .lost:
            log.info("network lost")
            ConnectTimeline.shared.mark("network_lost")
        case .changed(let path):
            log.info("network changed: \(path, privacy: .public)")
            presence?.kick()
            guard let teamID = registeredTeamID else { return }
            link.networkChanged(baseURL: api.baseURL, teamID: teamID, deviceID: identity.link)
        }
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
        feedTeamID = snapshot.teamID
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
        let keepsPersonal = store.activeTeamID == personal.id || store.teams.contains(where: { $0.id == personal.id && !$0.macs.isEmpty })
        if !teams.isEmpty, keepsPersonal { list.append(personal) }
        // A team the phone already shows (picked, or followed to a Mac) stays active.
        let keep = list.contains { $0.id == store.activeTeamID } ? store.activeTeamID : selectedID
        store.applyLiveTeams(list, selectedID: keep)
        activeTeamChanged()
        for team in list { loadPrefs(team.id) }
        if discoveryTask == nil { startDiscovery() }
    }

    /// The user chose their personal space (setup's "Choose a space"): it
    /// joins the list if it wasn't there and becomes the active space.
    public func selectPersonal() {
        if !store.teams.contains(where: { $0.id == personal.id }) {
            let list = store.teams.map { AppStore.AccountTeam(id: $0.id, name: $0.name) } + [personal]
            store.applyLiveTeams(list, selectedID: personal.id)
        }
        store.selectTeam(personal.id)
        activeTeamChanged(byUser: true)
    }

    /// Call after `store.selectTeam`: re-registers, reloads Macs, re-targets
    /// the link. `byUser` marks a sidebar pick, which discovery respects.
    public func activeTeamChanged(byUser: Bool = false) {
        let teamID = store.activeTeamID
        if byUser { pinnedTeamID = teamID }
        guard !teamID.isEmpty, teamID != registeredTeamID, teamID != startedTeamID else { return }
        startedTeamID = teamID
        if let feedTeamID, feedTeamID != teamID { feed.store.replaceAll([]) }
        feedTeamID = teamID
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
            // One round trip: both registrations, this team's Macs and the account's Macs.
            let asked = removedMacs.mark
            if let boot = try await api.bootstrap(teamID: teamID, devices: [
                (identity.link, "phone", deviceName), (identity.presence, "phone", "\(deviceName) (presence)"),
            ]) {
                ConnectTimeline.shared.mark("registered", detail: "bootstrap")
                guard !Task.isCancelled, store.activeTeamID == teamID else { return }
                if !warm { link.prewarm(baseURL: api.baseURL, teamID: teamID, deviceID: identity.link) }
                registeredTeamID = teamID
                push.attach(api: api, deviceID: identity.link)
                checkRelay()
                ConnectTimeline.shared.mark("macs_loaded", detail: "\(boot.macs.count)")
                applyMacs(boot.macs, teamID: teamID, askedAt: asked)
                store.teamDataState = .loaded
                if let mine = boot.myMacs { applyDiscovered(mine, askedAt: asked) }
                startPresence(teamID)
                return
            }
            // A service before 0.8.0: the separate calls, both registrations at once.
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
            push.attach(api: api, deviceID: identity.link)
            checkRelay()
            let askedForMacs = removedMacs.mark
            let macs = try await api.macs(teamID: teamID)
            guard !Task.isCancelled, store.activeTeamID == teamID else { return }
            ConnectTimeline.shared.mark("macs_loaded", detail: "\(macs.count)")
            applyMacs(macs, teamID: teamID, askedAt: askedForMacs)
            store.teamDataState = .loaded
            log.info("team \(teamID, privacy: .private) registered, \(macs.count, privacy: .public) Macs")
            startPresence(teamID)
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

    private func startPresence(_ teamID: String) {
        let listener = PresenceListener(api: api, teamID: teamID, deviceID: identity.presence, clock: clock) { [weak self] update in
            self?.presenceUpdate(update, teamID: teamID)
        }
        presence = listener
        listener.start()
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
            applyMacs(macs, teamID: teamID, askedAt: removedMacs.mark)
        case .mac(let mac) where mac.removed == true:
            forgetMac(mac.deviceId)
        case .mac(let mac):
            var current = store.teams.first { $0.id == teamID }?.macs ?? []
            let device = MacDevice(id: mac.deviceId, name: mac.name, isOnline: mac.online, lastSeenAt: mac.lastSeenDate)
            if let index = current.firstIndex(where: { $0.id == mac.deviceId }) { current[index] = device } else { current.append(device) }
            store.setMacs(current, teamID: teamID)
            let generationBefore = link.dialGeneration
            retarget()
            // The linked Mac's signaling socket is up (again): its host may
            // have restarted under the live link. Probe it now instead of at
            // the next heartbeat (termfix-r13 D2b), or dial now if waiting.
            // Only when retarget() did not just dial (a Mac back from offline):
            // a second dial at once would abandon the first, whose offer the
            // host may already be answering (r13 review).
            if mac.online, mac.deviceId == link.target?.macID, link.dialGeneration == generationBefore { link.send(.macSignaled) }
        }
    }

    /// Macs registered by another member (a shared team): listed, never
    /// dialed. Protocol v1 admits only the Mac owner's own phones.
    @ObservationIgnored private var othersMacs: Set<String> = []

    /// A Mac its owner deleted (here or on another device): gone from every
    /// team with its cached workspaces and connection state. When the link
    /// was on it, the link moves to another Mac (or to none) at once, so
    /// nothing keeps saying "Connecting…" to a Mac that no longer exists.
    func forgetMac(_ id: String) {
        let linked = link.target?.macID == id
        // The link's phase change must not write data for the removed Mac back.
        if dataMacID == id { dataMacID = nil }
        let known = store.forgetMac(id)
        othersMacs.remove(id)
        outdatedMacs.remove(id)
        discoveredMacIDs?.remove(id)
        previouslyOnline = previouslyOnline?.filter { !$0.hasPrefix("\(id)\u{0}") }
        if snapshot?.linkedMacID == id { snapshot?.linkedMacID = nil }
        if linked { link.send(.target(nil)) }
        retarget()
        scheduleSnapshotSave()
        if known || linked { onMacRemoved?(id) }
    }

    private func applyMacs(_ macs: [LiveAPI.Mac], teamID: String, askedAt: Int) {
        let macs = removedMacs.filter(macs, askedAt: askedAt, id: \.deviceId)
        for mac in macs {
            if let owner = mac.ownerUserId, owner != userID { othersMacs.insert(mac.deviceId) } else { othersMacs.remove(mac.deviceId) }
        }
        store.setMacs(macs.map { MacDevice(id: $0.deviceId, name: $0.name, isOnline: $0.online, lastSeenAt: $0.lastSeenDate) }, teamID: teamID)
        retarget()
        scheduleSnapshotSave()
    }

    /// Dials the selected Mac (remembered per team), else the first online one.
    private func retarget() {
        guard let team = store.activeTeam, registeredTeamID == team.id else { return }
        let remembered = UserDefaults.standard.string(forKey: "cnx.live.mac.\(team.id)")
            ?? (snapshot?.teamID == team.id ? snapshot?.linkedMacID : nil)
        let mac = LinkMachine.target(in: team.macs.filter { !othersMacs.contains($0.id) }, remembered: remembered, current: link.target?.macID)
        link.send(.target(mac.map { LinkMachine.Target(macID: $0.id, name: $0.name, isOnline: $0.isOnline) }))
    }


    /// Moves the link to a Mac and remembers it for the team (the next
    /// launch dials it first). Nothing changes when it is already the link's
    /// Mac, or for a Mac this phone may not dial.
    public func select(macID: String) {
        guard let team = store.activeTeam, canLink(macID: macID) else { return }
        UserDefaults.standard.set(macID, forKey: "cnx.live.mac.\(team.id)")
        retarget()
    }

    /// Whether this phone may dial the Mac: protocol v1 admits only the
    /// Mac owner's own phones, so a teammate's Mac is listed, never dialed.
    public func canLink(macID: String) -> Bool {
        !othersMacs.contains(macID)
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
            let asked = removedMacs.mark
            let macs = try await api.myMacs()
            guard !Task.isCancelled else { return }
            applyDiscovered(macs, askedAt: asked)
        } catch {
            guard !Task.isCancelled else { return }
            log.error("Mac discovery failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The account's Macs everywhere (`/me/macs`, or the bootstrap's copy): shows each in its
    /// team and moves to the team of an online Mac while the active team has none.
    private func applyDiscovered(_ macs: [LiveAPI.Mac], askedAt: Int) {
        let macs = removedMacs.filter(macs, askedAt: askedAt, id: \.deviceId)
        // An own Mac the last look listed and this one does not was removed
        // on another device (the Mac app's unpair, another phone).
        let ids = Set(macs.map(\.deviceId))
        for id in (discoveredMacIDs ?? []).subtracting(ids) { forgetMac(id) }
        discoveredMacIDs = ids
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
    }

    private func follow(_ team: Team, macName: String) {
        log.info("following \(macName, privacy: .private) to team \(team.id, privacy: .private)")
        store.selectTeam(team.id)
        activeTeamChanged()
        followed = Followed(serial: (followed?.serial ?? 0) + 1, teamID: team.id, teamName: team.name, macName: macName)
        onFollow?(team.id)
    }

    /// Looks once per team start whether the service has a TURN relay.
    private func checkRelay() {
        Task { [weak self] in
            guard let self else { return }
            if let ice = try? await self.api.ice() { self.relayAvailable = ice.turn ?? true }
        }
    }

    // MARK: Devices (Settings → Connection) and account

    /// Every Mac and phone of this account.
    public func myDevices() async throws -> [LiveAPI.Device] {
        try await api.myDevices()
    }

    /// This phone's own device ids (link and presence).
    public var ownDeviceIDs: Set<String> { [identity.link, identity.presence] }

    /// Deletes a device of this account; a Mac leaves every list at once.
    public func removeDevice(id: String) async throws {
        do {
            try await api.deleteDevice(id: id)
        } catch let failure as LiveAPI.Failure where failure.status == 404 {
            // Already gone (removed on another device): the outcome the user asked for.
        }
        removedMacs.removed(id)
        forgetMac(id)
        // Its identity pin goes too: a re-added Mac pins its key again.
        (pairing?.pins ?? .standard).forget(id)
    }

    /// Signs Chief question answers for the linked Mac with this phone's
    /// approval key (Face ID); nil without pairing keys or a paired Mac.
    public func chiefAnswerSigner() -> ChiefAnswerSigner? {
        guard let pairing, let macID = link.target?.macID, pairingState == .paired else { return nil }
        return ChiefAnswerSigner(keys: pairing.keys, macDevice: macID, phoneID: pairing.phoneID)
    }

    /// Account deletion, first step: the service forgets the account's
    /// devices, push tokens and preferences.
    public func deleteAccountData() async throws {
        try await api.deleteMe()
        forgetThisPhone()
    }

    /// Where a notification's session lives: the agent tab bound to it, or
    /// the tab the Mac named.
    public func destination(sessionID: String?, workspaceID: String?, tabID: String?) -> AgentChatDestination? {
        if let sessionID, let place = place(sessionID: sessionID) {
            return AgentChatDestination(workspaceID: place.workspaceID, tabID: place.tabID)
        }
        guard let workspaceID, let tabID, store.workspace(id: workspaceID)?.tabs.contains(where: { $0.id == tabID }) == true else { return nil }
        return AgentChatDestination(workspaceID: workspaceID, tabID: tabID)
    }

    /// Sign-out: stops discovery, presence and the link.
    public func stop() {
        stopped = true
        ChiefSources.shared.stop()
        networkTask?.cancel()
        networkTask = nil
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

    /// Debug UDP-blocked mode (Settings → Developer); a change redials.
    public func setBlockUDP(_ blockUDP: Bool) {
        link.send(.blockUDP(blockUDP))
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
        #if DEBUG
        if let link { runNetworkProbeIfAsked(link) }
        #endif
        acpmux.macLink = nil
        currentLink = link
        servedLink = nil
        pairingGate = nil
        acpmux.approver = nil
        // Pairing belongs to one link (review M1): a banner for another Mac, or a
        // stale "waiting" that holds back the workspaces deadline, never carries over.
        pairingState = .idle
        guard let link, let macID = self.link.target?.macID else {
            Task {
                await workspaces.bind(nil, macID: "")
                await acpmux.bind(nil)
            }
            if chiefLive {
                // Live mode never falls back to the mock Chief.
                ChiefSession.shared.use(ChiefOfflineBackend())
                ChiefSession.shared.status = nil
                chiefLive = false
            }
            return
        }
        if let prepared = self.link.takePrepared(for: link) as? PreparedLink {
            // The dial already opened `auth` and `daemon`: serve now, in this turn.
            ConnectTimeline.shared.mark("link_served")
            let passed = startServing(link, macID: macID, auth: prepared.auth, daemon: prepared.daemon)
            Task { [weak self] in await self?.finishServing(link, macID: macID, passed: passed) }
            return
        }
        Task { [weak self] in await self?.serve(link, macID: macID) }
    }

    /// What the dial step opened on a link before handing it over
    /// (`LinkController.prepare`): no main-actor turn per channel.
    struct PreparedLink: Sendable {
        let auth: Result<LinkPairing.Opened, LinkError>?
        let daemon: Result<WorkspaceSync.Prepared, LinkError>
    }

    nonisolated static func prepareLink(_ link: any MacLink, pairing: LinkPairing?, deviceID: String,
                                        deviceName: String) async -> PreparedLink {
        let auth = await pairing?.open(link: link)
        ConnectTimeline.shared.mark("pairing_opened")
        do {
            let channel = try await link.openChannel(service: "daemon", args: [:])
            ConnectTimeline.shared.mark("daemon_channel_open")
            return PreparedLink(auth: auth, daemon: .success(await WorkspaceSync.prepare(channel, deviceID: deviceID, deviceName: deviceName)))
        } catch {
            return PreparedLink(auth: auth, daemon: .failure(error as? LinkError ?? LinkError(code: "daemon", message: LinkController.reason(error))))
        }
    }

    /// Pairs `link` and serves its channels. Runs again on the same link from
    /// Retry after the Mac refused or nobody answered (review M2).
    private func serve(_ link: any MacLink, macID: String) async {
        // Pairing first: a Mac that pairs serves a channel only after `auth`, and holds the
        // ones opened behind it until it passes. Workspaces, the chats and the Feed open
        // right behind it, without waiting for each other (an open costs no round trip).
        ConnectTimeline.shared.mark("link_served")
        let auth = await self.openPairing(link)
        guard let passed = startServing(link, macID: macID, auth: auth, daemon: nil) else { return }
        await finishServing(link, macID: macID, passed: passed)
    }

    /// Serves `link` from this turn: workspaces bind, the version check and
    /// pairing start. Nil (and `auth` closed) when the link moved on.
    private func startServing(_ link: any MacLink, macID: String, auth: Result<LinkPairing.Opened, LinkError>?,
                              daemon: Result<WorkspaceSync.Prepared, LinkError>?) -> Task<Bool, Never>? {
        guard currentLink === link else {
            if case .success(let opened)? = auth { Task { await opened.close() } }
            if case .success(let prepared)? = daemon { Task { await prepared.client.close() } }
            return nil
        }
        servedLink = link
        acpmux.macLink = link
        bindWorkspaces(link, macID: macID, prepared: daemon)
        Task { [weak self] in await self?.checkVersion(link, macID: macID) }
        let passed = startPairing(link, macID: macID, auth: auth)
        pairingGate = (link, passed)
        return passed
    }

    private func finishServing(_ link: any MacLink, macID: String, passed: Task<Bool, Never>?) async {
        guard let passed else { return }
        do {
            guard await passed.value else {
                // Nothing on this link is served now: terminals, files and uploads say
                // "not connected" instead of `unpaired`, and Retry pairs again.
                if self.currentLink === link {
                    self.servedLink = nil
                    self.acpmux.macLink = nil
                }
                return
            }
            // The workspaces deadline waited while the Mac asked its person: start it again.
            if self.store.macData[macID]?.source != .live { self.armWorkspacesDeadline(link, macID: macID) }
            // Terminal tabs attach lazily (`terminalSession(tabID:)`), each on its
            // own `daemon` channel of this link; open ones reattach now. Input-lane
            // channels may ride another stream, so they wait for pairing here.
            self.terminals.removeAll { $0.session == nil }
            let tree = self.workspaces.tree
            for terminal in self.terminals {
                // Only this Mac's terminals: another Mac's would resolve their ids
                // here, get terminal_not_found and end for good (PR #22555 review).
                guard let session = terminal.session,
                      terminal.macID == nil || terminal.macID == macID,
                      DaemonTerminalSession.shouldReattach(surface: session.surface, terminalID: session.terminalID, tree: tree)
                else { continue }
                session.reconnect()
            }
            // Streamed browser tabs that dropped open again on this link.
            StreamedBrowserDirectory.shared.linkChanged()
            do {
                let channel = try await link.openChannel(service: "acpmux", args: [:])
                await self.acpmux.bind(channel)
                if self.acpmux.isReady { self.feed.store.syncState = .live }
            } catch {
                log.error("acpmux channel: \(String(describing: error), privacy: .public)")
            }
            // A failed chat channel is shown, not only logged.
            self.chatsError = self.acpmux.isReady ? nil : (self.acpmux.lastError ?? "chats are unavailable")
            self.phaseChanged()
            await self.startChief(link)
        }
    }

    /// The current link once its pairing passed, for channels that may overtake
    /// `auth` (the input lane rides another stream).
    private func pairedLink() async throws -> any MacLink {
        guard let link = servedLink else { throw LinkError(code: "no-link", message: "Not connected to the Mac") }
        if let gate = pairingGate, gate.link === link, !(await gate.passed.value) {
            throw LinkError(code: "unpaired", message: "This iPhone is not paired with the Mac")
        }
        guard let current = servedLink, current === link else {
            throw LinkError(code: "no-link", message: "Not connected to the Mac")
        }
        return link
    }

    /// The current link, for streamed browser tabs (`browser` service).
    public func browserLink() async -> (any BrowserStreamOpening)? {
        servedLink as? any BrowserStreamOpening
    }

    /// Opens the `daemon` channel and loads the workspaces; a failure or a
    /// Mac that never answers shows as a failure with Retry.
    private func bindWorkspaces(_ link: any MacLink, macID: String, prepared: Result<WorkspaceSync.Prepared, LinkError>? = nil) {
        armWorkspacesDeadline(link, macID: macID)
        Task { [weak self] in
            guard let self else { return }
            do {
                let cached = self.store.workspaces.filter { $0.macID == macID }
                if let prepared {
                    await self.workspaces.bind(try prepared.get(), macID: macID, cached: cached)
                } else {
                    let daemon = try await link.openChannel(service: "daemon", args: [:])
                    ConnectTimeline.shared.mark("daemon_channel_open")
                    await self.workspaces.bind(daemon, macID: macID, cached: cached)
                }
                // The link may have moved on (another Mac, or this one was removed).
                if let error = self.workspaces.lastError, self.link.target?.macID == macID, self.store.macData[macID]?.source != .live {
                    self.store.handleMacData(.failed(error), macID: macID)
                }
            } catch {
                log.error("daemon channel: \(String(describing: error), privacy: .public)")
                if self.link.target?.macID == macID {
                    self.store.handleMacData(.failed(LinkController.reason(error)), macID: macID)
                }
            }
        }
    }

    /// Fails the workspace list when `link` does not bring it in time.
    private func armWorkspacesDeadline(_ link: any MacLink, macID: String) {
        workspacesTimeout?.cancel()
        workspacesTimeout = Task { [weak self, clock] in
            do { try await clock.sleep(for: Self.workspacesDeadline) } catch { return }
            guard let self, self.currentLink === link, self.link.target?.macID == macID,
                  self.store.macData[macID]?.source != .live else { return }
            // The Mac holds the daemon channel while its person answers "Allow … to connect?"
            // on this link; pairing re-arms the deadline once it passes, and a refusal or
            // timeout fails the channel itself.
            if self.pairingState.isWaiting { return }
            log.error("workspaces did not arrive in time")
            self.store.handleMacData(.failed("the Mac didn't send its workspaces"), macID: macID)
        }
    }

    /// Retry for a Mac (the Workspaces Retry and Reconnect): pairs the link
    /// again when the Mac refused it or nobody answered, reloads the
    /// workspaces on a live link, redials a waiting one, or switches to it.
    public func retry(macID: String) {
        guard link.target?.macID == macID else {
            select(macID: macID)
            return
        }
        if link.phase.isConnected, let current = currentLink, servedLink == nil, let gate = pairingGate, gate.link === current {
            // Review M2: the link is up but its pairing failed. Ask again on it, so an
            // Allow given on the Mac since (or a prompt answered now) takes effect.
            pairingGate = nil
            pairingState = .idle
            store.handleMacData(.connecting, macID: macID)
            Task { [weak self] in await self?.serve(current, macID: macID) }
            return
        }
        if link.phase.isConnected, let servedLink, store.macData[macID]?.source != .live {
            store.handleMacData(.connecting, macID: macID)
            bindWorkspaces(servedLink, macID: macID)
        } else {
            foreground()
        }
    }

    /// Asks the Mac's host which link protocol it speaks. A host that refuses
    /// the `version` service is from before link protocol 2 (control frames
    /// ahead of data, no reader stalls) and drops links under load.
    private func checkVersion(_ link: any MacLink, macID: String) async {
        guard let channel = try? await link.openChannel(service: "version", args: [:]) else { return }
        let reply = try? await channel.receive()
        await channel.close(code: "eof", reason: "")
        // Only a host without the service is old; another refusal (`unpaired` while pairing
        // fails) says nothing about its protocol.
        if reply == nil, let closed = channel.closedBy, closed.code != "unknown_service" { return }
        let object = reply.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let protocolVersion = object?["link"] as? Int ?? 1
        let capabilities = Set(object?["capabilities"] as? [String] ?? [])
        if store.macCapabilities[macID] != capabilities { store.macCapabilities[macID] = capabilities }
        log.info("Mac host: \(object?["hostd"] as? String ?? "before 0.2", privacy: .public), link protocol \(protocolVersion, privacy: .public)")
        let outdated = protocolVersion < 2
        guard outdated != outdatedMacs.contains(macID) else { return }
        if outdated { outdatedMacs.insert(macID) } else { outdatedMacs.remove(macID) }
        phaseChanged()
    }

    /// Opens `auth` on `link` (no round trip); nil without pairing keys.
    private func openPairing(_ link: any MacLink) async -> Result<LinkPairing.Opened, LinkError>? {
        guard let pairing else { return nil }
        return await pairing.open(link: link)
    }

    /// Proves this phone's keys on the `auth` channel `auth`; false when the Mac refused it.
    /// Proves this phone's keys on `auth`, starting at once off the main actor
    /// (the Mac holds the `daemon` answers until it passes). The task's value
    /// is false when the Mac refused it.
    private func startPairing(_ link: any MacLink, macID: String, auth: Result<LinkPairing.Opened, LinkError>?) -> Task<Bool, Never> {
        guard let pairing, let auth else { return Task { true } }
        let name = self.link.target?.name ?? "your Mac"
        let keys = pairing.keys
        let onWaiting: @MainActor @Sendable () -> Void = { [weak self] in
            // Only the current link's pairing speaks for the banner (review M1).
            guard let self, self.currentLink === link else { return }
            self.pairingState = keys.takeReplaced() ? .waitingAfterNewKeys(mac: name) : .waiting(mac: name)
        }
        let outcome = Task.detached { await pairing.finish(auth, macID: macID, onWaiting: onWaiting) }
        return Task { @MainActor [weak self] in
            let outcome = await outcome.value
            guard let self, self.currentLink === link else { return false }
            switch outcome {
            case .paired(let macDevice):
                self.pairingState = .paired
                self.acpmux.approver = AcpmuxHub.Approver(phoneID: pairing.phoneID, macDevice: macDevice) { reason in
                    try await keys.authorizeApproval(reason: reason)
                }
                return true
            case .legacy:
                self.pairingState = .idle
                return true
            case .refused(let error):
                log.error("pairing refused: \(error.code, privacy: .public) \(error.message, privacy: .public)")
                self.pairingState = error.code == "denied" ? .denied(mac: name) : .failed(LinkPairing.refusalText(error))
                return false
            }
        }
    }

    /// Settings → Devices → "Remove This iPhone from My Macs": asks the linked
    /// Mac to forget this phone, deletes this account's pairing keys (so no
    /// Mac that approved them can be reached with them again), and redials,
    /// so the next link asks the Mac to allow this iPhone again.
    /// Sign-out does not do this: it keeps the phone's identity and approvals
    /// (verify/persistence.md). One removal at a time (review m4: a second
    /// one racing it would load, and so create, new keys mid-unpair).
    public func removeThisPhoneFromMacs() async {
        guard let pairing, !removalRunning else { return }
        removalRunning = true
        defer { removalRunning = false }
        if let link = currentLink, let macID = self.link.target?.macID {
            await pairing.unpair(link: link, macID: macID)
        }
        // Drop the link the Mac approved with the old keys before they go, so
        // nothing on it loads (and so makes) new keys mid-removal; then dial again.
        let target = self.link.target
        self.link.send(.target(nil))
        pairing.keys.reset()
        removedFromMacsCount += 1
        if target != nil { retarget() }
    }

    /// Account deletion, after the service forgot the account: this phone's
    /// keys and device ids for it go too (they can never be used again).
    public func forgetThisPhone() {
        accountDeleted = true
        pairing?.keys.reset()
        pairing?.pins.removeAll()
        DeviceIdentity.forget(userID: userID, store: secrets)
    }

    /// A live session for a terminal tab of the Mac (`s<surface>`), or nil
    /// when the tab is not a daemon surface. The channel opens when the screen
    /// starts the session; without a link it says so and attaches when the
    /// link comes back (as after any drop).
    public func terminalSession(tabID: String, programName: String) -> DaemonTerminalSession? {
        guard let surface = workspaces.tree?.surfaces[tabID] else { return nil }
        // The daemon titles a shell tab with its folder; the composer says "Send to <program>".
        let program = programName.hasPrefix("/") || programName.hasPrefix("~") || programName.isEmpty ? "terminal" : programName
        let info = ["name": deviceName, "kind": "ios", "device_kind": "iphone", "device_name": deviceName, "device_id": identity.link]
        let terminalID = workspaces.tree?.terminals[tabID].map { $0.resourceID ?? $0.id }
        let session = DaemonTerminalSession(surface: surface, terminalID: terminalID, programName: program, clientInfo: info, open: { [weak self] in
            guard let link = await self?.servedLink else { throw LinkError(code: "no-link", message: "Not connected to the Mac") }
            let channel = try await link.openChannel(service: "daemon", args: [:])
            return DaemonClient(channel: channel)
        }, openInput: { [weak self] in
            // Keystrokes ride the link's input lane (PROTOCOL.md "Lanes"), another stream that
            // can overtake `auth`: it opens only once pairing passed (review m6).
            guard let self else { throw LinkError(code: "no-link", message: "Not connected to the Mac") }
            let link = try await self.pairedLink()
            let channel = try await link.openInputChannel(service: "daemon", args: [:])
            return DaemonClient(channel: channel)
        })
        session.macName = link.target?.name
        let macID = link.target?.macID
        session.setMacOffline(LinkMachine.terminalOffline(macID: macID, linkedMacID: macID, linkOffline: terminalsOffline))
        terminals.removeAll { $0.session == nil }
        terminals.append(WeakTerminal(session: session, macID: macID))
        return session
    }

    /// The Mac's screen of a terminal tab as plain text (`read-screen`, one
    /// short-lived `daemon` channel), for the grid card of a tab not opened
    /// in this launch (D5). Nil without a link or on any failure.
    public func terminalScreenText(tabID: String) async -> String? {
        guard let surface = workspaces.tree?.surfaces[tabID], let link = await servedLink,
              let channel = try? await link.openChannel(service: "daemon", args: [:]) else { return nil }
        let client = DaemonClient(channel: channel)
        await client.start()
        defer { Task { await client.close() } }
        guard let reply = try? await client.request("read-screen", params: ["surface": surface]),
              let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
              object["ok"] as? Bool != false,
              let data = object["data"] as? [String: Any] else { return nil }
        return data["text"] as? String
    }

    /// Files and Links previews for a terminal tab: real files on the linked
    /// Mac over the `file` service, relative paths resolved against the tab's
    /// directory.
    public func terminalArtifactSource(tabID: String) -> any ArtifactSource {
        LinkFileArtifactSource(macName: link.target?.name ?? "your Mac", baseDirectory: workspaces.tree?.directories[tabID]) { [weak self] in
            await self?.servedLink
        }
    }

    /// Sends a terminal attachment to the linked Mac (the `upload` service)
    /// into the tab's folder, next to acpmux's attachments, or the Mac's own
    /// uploads folder when the tab has none; returns the file's path there.
    public func terminalUploader(tabID: String) -> @MainActor (Data, String) async throws -> String {
        { [weak self] data, name in
            guard let self, let link = self.servedLink else {
                throw LinkUpload.Failure(code: "offline", message: "the Mac isn't connected")
            }
            let cwd = LinkUpload.folder(self.workspaces.tree?.directories[tabID])
            do {
                return try await LinkUpload.upload(data, name: name, cwd: cwd, over: link)
            } catch let failure as LinkUpload.Failure where cwd != nil && (failure.code == "forbidden" || failure.code == "not_found") {
                return try await LinkUpload.upload(data, name: name, cwd: nil, over: link)
            }
        }
    }

    /// Chief over the daemon's local conversations, when the Mac's link allows them.
    /// Chief on the Mac: its Chief owner over the link's scoped `chief`
    /// channel (cnx-hostd). Every failure leaves Chief offline with the
    /// reason; there is no stand-in Chief.
    private func startChief(_ link: any MacLink) async {
        let session = ChiefSession.shared
        chiefStarting = true
        // Every way out ends a Try Again in flight, even one for a link replaced meanwhile.
        defer {
            chiefStarting = false
            session.endReconnect()
        }
        // Try Again on Chief's unavailable bar opens the channel again on this link.
        session.reconnect = { [weak self] in self?.retryChief() }
        session.macName = self.link.target?.name
        // Chief's settings show this Mac's last known model until it answers.
        session.macID = self.link.target?.macID
        // A newer link (or none) took over while this one was opening: leave it be.
        func current() -> Bool { (currentLink as AnyObject?) === (link as AnyObject) }
        func offline(_ reason: String) {
            guard current() else { return }
            chiefStatus = reason
            session.status = reason
            if chiefLive || !(session.backend is ChiefOfflineBackend) {
                session.use(ChiefOfflineBackend(reason: reason))
            }
            chiefLive = false
            log.info("chief unavailable: \(reason, privacy: .public)")
        }
        do {
            let channel = try await link.openChannel(service: ChiefDaemonBackend.service, args: [:])
            let client = DaemonClient(channel: channel)
            let probe = try await client.request("conversation-list", params: [:])
            let object = try? JSONSerialization.jsonObject(with: probe) as? [String: Any]
            if object?["ok"] as? Bool == false {
                await channel.close(code: "eof", reason: "chief unavailable")
                offline(String(localized: "Chief on this Mac: \(object?["error"] as? String ?? "unavailable")"))
                return
            }
            let conversations = (object?["data"] as? [String: Any])?["conversations"] as? [[String: Any]] ?? []
            let identity = ChiefIdentity.standard
            let hasChief = conversations.contains { summary in
                let ids = (summary["participants"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
                return ids.contains(identity.chiefID) && ids.contains(identity.meID)
            }
            guard hasChief else {
                await channel.close(code: "eof", reason: "chief not started")
                offline(ChiefDaemonBackend.notStarted)
                return
            }
            guard current() else {
                await channel.close(code: "eof", reason: "link replaced")
                return
            }
            session.status = nil
            // Answers to Chief's questions sign with this phone's key after Face ID.
            session.answerSigner = { [weak self] in self?.chiefAnswerSigner() }
            session.use(ChiefDaemonBackend(client: client))
            chiefLive = true
            chiefStatus = nil
        } catch {
            // An older hostd without the `chief` service closes it as unknown.
            let reason = LinkController.reason(error)
            log.info("chief channel refused: \(reason, privacy: .public)")
            offline(Self.chiefRefusal(reason, macName: self.link.target?.name))
        }
    }

    /// Try Again on Chief's unavailable bar: the Chief channel again, on the
    /// link that is up now. Without one, the bar says so.
    func retryChief() {
        // One open at a time: the one running now ends the try.
        guard !chiefStarting else { return }
        guard let link = servedLink else {
            ChiefSession.shared.status = String(localized: "Your Mac isn't connected. Chief comes back when it is.")
            return
        }
        Task { [weak self] in await self?.startChief(link) }
    }

    /// The bar's sentence for a refused `chief` channel. hostd's own text
    /// ("cmux-tui session chief: No such file or directory") is for the log.
    static func chiefRefusal(_ reason: String, macName: String?) -> String {
        let mac = macName ?? String(localized: "your Mac")
        if reason.contains("unknown_service") || reason.contains("no service chief") {
            return String(localized: "This Mac's cmux is too old for Chief on iPhone. Update cmux on the Mac.")
        }
        // hostd closes the channel when the owner's socket is missing ("daemon channel closed").
        if reason.contains("No such file") || reason.contains("not set up") || reason.contains("Connection refused")
            || reason.contains("channel closed") {
            return String(localized: "Chief isn't running on \(mac). Open cmux on the Mac to start it, then try again.")
        }
        return String(localized: "Chief on \(mac) didn't answer (\(reason)).")
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
        // Streamed browser tabs of workspaces closed on the Mac go: a redial
        // must not open them again (transport-verify-20261019.md defect 7).
        // This phone's pending workspaces keep theirs.
        StreamedBrowserDirectory.shared.retain(
            tabs: Set(tree.surfaces.keys).union(store.workspaces.flatMap { $0.tabs.map(\.id) }))
        ConnectTimeline.shared.mark("workspaces_live", detail: "\(tree.workspaces.count) workspaces")
        scheduleSnapshotSave()
        // History items name their workspace and tab once the tree places their session.
        if acpmux.isReady { feed.hydrate(Array(acpmux.sessions.values)) }
        terminalFeed.treeChanged(tree, macID: macID, connection: workspaces.connectionSerial)
    }

    @ObservationIgnored private var feedSavePending = false

    /// One write per main-queue turn, however many items a burst changed.
    private func scheduleFeedSave(_ archive: FeedArchive) {
        guard !feedSavePending else { return }
        feedSavePending = true
        Task { @MainActor [weak self] in
            guard let self, !stopped else { return }
            feedSavePending = false
            // Encoded and written off the main thread (a save per change dropped frames while scrolling).
            archive.saveInBackground(feed.store.items)
        }
    }

    private func place(sessionID: String) -> LiveFeed.Place? {
        guard let tree else { return nil }
        for workspace in tree.workspaces + tree.homeWorkspaces {
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
            _ = link.media
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

    /// Terminal tabs say the Mac is offline once the link has been down
    /// for a bounded time, or at once when presence says so (T-LIFE-13:
    /// offline label ≤ 5 s), never "Reattaching…" for 20 minutes (D4).
    private func updateTerminalsOffline(_ phase: LinkMachine.Phase) {
        let now = ContinuousClock.now
        if phase.isConnected || phase == .idle {
            linkDownSince = nil
        } else if linkDownSince == nil {
            linkDownSince = now
        }
        let down = linkDownSince.map { now - $0 } ?? .zero
        let offline = phase.showsTerminalsOffline(notConnectedFor: down)
        terminalsOffline = offline
        terminals.removeAll { $0.session == nil }
        let linked = link.target?.macID
        for terminal in terminals {
            terminal.session?.setMacOffline(LinkMachine.terminalOffline(macID: terminal.macID, linkedMacID: linked, linkOffline: offline))
        }
        offlineTask?.cancel()
        offlineTask = nil
        guard !offline, linkDownSince != nil, down < LinkMachine.Phase.offlineAfter * 2 else { return }
        // Look again when the next bound is reached (a retry or redial, then a first dial's longer one).
        let wait = (down < LinkMachine.Phase.offlineAfter ? LinkMachine.Phase.offlineAfter : LinkMachine.Phase.offlineAfter * 2) - down
        offlineTask = Task { [weak self] in
            guard let clock = self?.clock else { return }
            do { try await clock.sleep(for: wait) } catch { return }
            guard let self else { return }
            self.updateTerminalsOffline(self.link.phase)
        }
    }

    private func phaseChanged() {
        let phase = link.phase
        let target = link.target
        updateMacState(phase, target: target)
        updateTerminalsOffline(phase)
        var status = store.macLinkStatus
        status = [:]
        if let target, let line = phase.statusLine(macName: target.name, media: link.media) {
            var parts = [line]
            if phase.isConnected, let chatsError { parts.append("Chats: \(chatsError)") }
            if outdatedMacs.contains(target.macID) { parts.append("Update cmux on this Mac") }
            status[target.macID] = parts.joined(separator: " · ")
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
            // An offline Mac is not a connection failure; without TURN, neither
            // transport gets through from another network (WireGuard's backend
            // relay is retired), so say so.
            let relay = relayAvailable == false ? ". Relay (TURN) unavailable" : ""
            banner = reason == LinkController.reason(LinkError(code: "offline", message: ""))
                ? .macOffline(name) : .failed("Can't reach \(name) over \(transport.displayName)\(relay)")
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
