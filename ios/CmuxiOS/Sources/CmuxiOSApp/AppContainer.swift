import CmuxControlPlane
import CmuxFeedPushCore
import CmuxHomeCore
import CmuxHomeUI
import CMUXMobileCore
import CmuxiOSAuth
import CmuxiOSBrowserCore
import CmuxiOSComposerCore
import CmuxiOSCrashReporting
import CmuxiOSFeatureKit
import CmuxiOSFeed
import CmuxiOSFeedCloud
import CmuxiOSFiles
import CmuxiOSFilesCore
import CmuxiOSIdentity
import CmuxiOSNotifyCore
import CmuxPhonePush
import CmuxiOSPlatform
import CmuxiOSOnboarding
import CmuxiOSOnboardingCore
import CmuxiOSPush
import CmuxiOSSettingsCore
import CmuxiOSShell
import CmuxiOSSSHCore
import CmuxiOSSSHWorkspacesCore
import CmuxiOSTerminalComposeCore
import CmuxiOSTerminalLink
import CmuxiOSViewers
import CmuxiOSViewersCore
import CmuxiOSWorkspaces
import CmuxiOSWorkspacesCore
import Foundation
import OSLog
import UIKit
import UserNotifications

/// The composition root: built once at launch, owns every long-lived object.
/// No singletons below it; everything is injected.
@MainActor
final class AppContainer {
    let auth: StackAuthGate
    let devOptions: DevOptions
    /// The scrubbed diagnostic log (c16-platform.md section 3).
    let diagnostics: DiagnosticLogSink
    /// Sentry under the shared telemetry consent.
    let crashReporter: CrashReporter
    /// Delivers links and notification taps, deferred until signed in.
    let router: ShellRouter
    /// The one toast owner; feature screens get it from here.
    let toasts = ToastCenter()
    /// The authenticated API config projection. Nil keeps the mock when no
    /// API origin is configured (SSH-only and preview launches).
    var remoteConfigFactory: (@Sendable () -> any RemoteConfigSource)?
    private let remoteConfigCache = RemoteConfigCache()
    private var remoteConfigFactoryForAccount: (@Sendable (String) -> any RemoteConfigSource)? = nil
    private var remoteConfigAccountID: String? = nil
    private var remoteConfigTask: Task<Void, Never>?
    /// The account's remote config (flags, Mac floor, demo content).
    private(set) var remoteConfig = RemoteConfig.empty
    /// App Review demo content: every seam on its mock's canned fixtures.
    let demo: DemoModePolicy
    var isDemo: Bool { demo.isActive(remote: remoteConfig) }
    /// Fires when demo mode turns on or off (the shell rebuilds its seams).
    var onDemoChange: (() -> Void)?
    /// B5 fills this from capability negotiation; nil keeps the mock.
    var macCapabilitiesFactory: (@Sendable () -> any MacCapabilitiesSource)?
    /// B5 fills this with the Mac's power assertion; nil keeps the mock.
    var keepAwakeFactory: (@Sendable () -> any KeepAwakeControl)?
    /// The StoreKit store once plans are decided (C12); nil keeps the mock.
    var billingFactory: (@Sendable () -> any BillingStore)?
    private var featuresDemo = false
    /// Root tab and surface flags (plans/cmux-next/ios-next/a1-shell.md).
    let flags: FeatureFlagStore
    /// Mock or real per feature seam (DEV switch).
    let sourceModes: FeatureSourceModeStore
    /// Real seam implementations. Each feature lane sets its slot here when
    /// its carrier lands; an empty slot keeps that seam on its mock.
    let realFactories: RealFeatureFactories
    /// Opens feed items from push taps (lane C6).
    let feedNavigator = FeedNavigator()
    /// SSH state that stays on this device (lane C9): logins, keys, pins.
    let sshDevice: SSHDeviceState
    /// Lane E3: SSH hosts' sessions in the Workspaces list (discovery and
    /// catalog-checked attach over the on-device host records).
    let sshWorkspaces: SSHWorkspacesComposition
    /// Lane E5: SSH hosts' files over SFTP (sessions, transfers, viewers).
    let sftp = SFTPComposition()
    /// Lane E5 deferred sign-in (e5-extras.md section 5): the stored "Use SSH
    /// Without an Account" choice, how this launch applies it, and the hosts
    /// added signed out (offered for sync on sign-in).
    let guestMode = GuestModeStore()
    let guestPolicy: GuestAccessPolicy
    let guestHostsLedger: GuestHostsLedger
    /// Set by the root controller: the sign-in screens' guest entry.
    var onContinueWithoutAccount: (@MainActor () -> Void)?
    /// Lane C11 (c11-settings.md): this device's terminal look, fed to every
    /// terminal surface, and the crash-report consent (shared key).
    let terminalPreferences = TerminalPreferencesStore()
    /// Lane E4 (e4-compose.md): the terminal composer's drafts per terminal
    /// and sent history on this device; cleared on sign-out.
    let terminalCompose = TerminalComposeStore(persistence: FileTerminalComposePersistence.standard())
    let privacy = PrivacyPreferences(consentKey: UserDefaultsAnalyticsConsentProvider.telemetryKey)
    /// Lane E5: the haptics toggle over the one `HapticsPreference` owner.
    let haptics = HapticsSettings()
    /// C7 fills this with the push owner's per-device filter; nil keeps the
    /// notification preferences on this device.
    var notificationPreferencesSinkFactory: (@Sendable () -> any NotificationPreferencesSink)?
    private(set) lazy var notificationPreferences = NotificationPreferencesStore(sink: notificationPreferencesSinkFactory?())
    /// The live path badge per device from the account's links (D1); nil
    /// (no API origin) serves mock badges while devices are mocked.
    var linkDiagnosticsFactory: (@Sendable () -> any LinkDiagnosticsSource)?
    /// D1 (d1-terminal-ux.md): the signed-in account's one `MobileLinkClient`
    /// per Mac over B4 direct, B2 WebRTC and (DEV) B3, shared by terminals,
    /// files and the browser stream. Bound on sign-in, closed on sign-out.
    let accountLinks: AccountLinkDirectory
    /// B6's runtime shared by the device registry and the links (nil without an API origin).
    private let pairing: PairingComposition?
    /// DEV switches of the link layer (V2 carrier, echo prediction).
    let linkDev = LinkDevOptions()
    var linkDirectory: any MobileLinkDirectory { accountLinks }
    /// C14: the same per-Mac clients for the tunnel browser and simulator
    /// streams; nil without pairing (as for the browser stream).
    var webClients: (any MobileLinkClientProvider)? {
        pairing == nil ? nil : LinkClientProvider(directory: accountLinks)
    }
    /// Workspace terminals of real Macs over each Mac's `cmux.mobile/1`
    /// session. Mock workspaces keep A2's mock host (ShellComposition).
    private(set) lazy var linkTerminalSources = LinkWorkspaceTerminalSourceFactory(
        directory: accountLinks, options: LinkWorkspaceTerminalSourceFactory.defaultOptions(prediction: linkDev.prediction))
    var terminalSources: (any WorkspaceTerminalSourceFactory)? { linkTerminalSources }
    /// The browser seam's tab records follow the resolved workspace source.
    private let browserTabs: CurrentWorkspaceTabs
    /// The user's saved direct addresses (C9/B4), joined into link routes.
    private let localHosts: LocalHostsStore
    private var features: FeatureSources?
    private var featuresAccount: String?
    /// Lane C4: pickers, uploads and the transfer list over the account's
    /// files seam; one per seam set so its background handling lives as long.
    private var files: FilesFeature?
    /// Lane C13: changes, file browser and viewers over the account's seams.
    private var viewers: ViewersFeature?
    /// C1/D1 fill this with the terminal channel's paste; nil skips the paste.
    var terminalPathPasterFactory: (@Sendable () -> any TerminalPathPaster)?
    /// C8 fills this with the composer's attachment intake; nil keeps uploads in the inbox.
    var fileAttachmentSinkFactory: (@Sendable () -> any FileAttachmentSink)?
    /// DEV: the mock owners' simulated connection.
    private(set) var mockOffline = false
    let push: PushRegistration
    /// Onboarding (plans/cmux-next/ios-next/c10-onboarding.md): whether this
    /// launch runs it, where its progress lives, and the system prompts.
    let onboardingPolicy: OnboardingLaunchPolicy
    let onboardingStore: any OnboardingProgressPersisting
    let permissions: SystemPermissionCenter
    /// The install principal (nil when no API origin is configured).
    let identity: InstallIdentity?
    /// Account changes apply in order (sign-in, sign-out, switch).
    private var accountChanges: Task<Void, Never>?
    let feedResponder: FeedNotificationResponder
    private let notificationDelegate: NotificationDelegate
    /// Lane C7: dismiss pushes, the foreground badge and banner sync, and
    /// Live Activities for running agents (c7-notify.md).
    let remoteNotifications = RemoteNotificationHandler()
    let activities: AgentActivityCenter
    private var foregroundSync: ForegroundNotificationSync?
    private var signedInAccount: SignedInAccount?
    private(set) var home: HomeStore?
    private var homeAccount: String?
    /// Set while the API Worker refuses this app version (enterprise P17,
    /// `client.too_old`); Home shows it as an update-required banner.
    private(set) var updateRequired: HomeUpdateRequired? {
        didSet { if updateRequired != oldValue { onUpdateRequiredChange?(updateRequired) } }
    }
    var onUpdateRequiredChange: ((HomeUpdateRequired?) -> Void)?

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let composition = MobileAuthComposition(
            environment: environment,
            reachability: PathReachability()
        )
        diagnostics = DiagnosticLogSink(directory: Self.diagnosticsDirectory())
        crashReporter = CrashReporter(consent: UserDefaultsAnalyticsConsentProvider(defaults: .standard),
                                      environment: environment)
        crashReporter.activate()
        let sink = diagnostics
        Task {
            await sink.setTap { line in
                CrashReporter.breadcrumb(level: line.level.rawValue, category: line.category, message: line.message)
            }
        }
        diagnostics.info("app", "launch")
        router = ShellRouter(parser: ShellRouteParser(bundleScheme: Self.bundleURLScheme()), log: diagnostics)
        let gate = StackAuthGate(composition: composition)
        auth = gate
        devOptions = DevOptions(environment: environment)
        #if DEBUG
        let isDebug = true
        #else
        let isDebug = false
        #endif
        let flagStore = FeatureFlagStore(environment: environment, isDebug: isDebug)
        flags = flagStore
        // Lane C9: SSH and direct host records live on this device until B1
        // syncs them; one owner instance per process, shared by every shell.
        let sshDirectory = Self.sshDirectory()
        sshDevice = SSHDeviceState(directory: sshDirectory)
        let localHosts = LocalHostsStore(url: sshDirectory.appendingPathComponent("hosts.json"))
        self.localHosts = localHosts
        let madeSSHWorkspaces = SSHWorkspacesComposition(hosts: localHosts, device: sshDevice, catalog: SSHSessionCatalog())
        sshWorkspaces = madeSSHWorkspaces
        guestHostsLedger = GuestHostsLedger(url: sshDirectory.appendingPathComponent("guest-hosts.json"))
        guestPolicy = GuestAccessPolicy(environment: environment, isDebug: isDebug)
        var factories = RealFeatureFactories()
        factories.hosts = { localHosts }
        sourceModes = FeatureSourceModeStore(environment: environment, isDebug: isDebug)
        demo = DemoModePolicy(environment: environment, isDebug: isDebug)
        onboardingPolicy = OnboardingLaunchPolicy(environment: environment, isDebug: isDebug)
        switch onboardingPolicy.decision {
        case .stored: onboardingStore = OnboardingProgressStore(defaults: .standard)
        case .fresh, .skip: onboardingStore = InMemoryProgressStore()
        }
        // Feed pushes (plans/cmux-next/feed.md 7.3) go through the API Worker as
        // this install's principal (identity D5, InstallIdentity).
        let base = Self.cloudAPIBaseURL()
        let madeIdentity = base.map {
            InstallIdentity(baseURL: $0, bundleID: Bundle.main.bundleIdentifier ?? "", deviceName: UIDevice.current.name)
        }
        identity = madeIdentity
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let madePairing = base.flatMap { base in
            madeIdentity.map {
                PairingComposition(base: base, identity: $0, bundleID: Bundle.main.bundleIdentifier ?? "", appVersion: version)
            }
        }
        pairing = madePairing
        // D1: one link client per Mac for terminals (C1), files (C4) and the browser (C2).
        let madeLinks = AccountLinkDirectory()
        accountLinks = madeLinks
        let tabs = CurrentWorkspaceTabs()
        browserTabs = tabs
        let links = LinkClientProvider(directory: madeLinks)
        if madePairing != nil {
            factories.browser = BrowserComposition.realSource(clients: links, directory: tabs)
        }
        // C12: the team's Cloud machines over CloudDO.
        let coordinator = gate.coordinator
        if let base {
            let cache = remoteConfigCache
            let sessionToken: @Sendable () async throws -> String = { @MainActor in
                try await coordinator.accessToken()
            }
            remoteConfigFactoryForAccount = { account in
                URLSessionRemoteConfigSource(
                    baseURL: base,
                    appVersion: version,
                    initial: cache.load(for: account) ?? .empty,
                    token: sessionToken
                )
            }
        }
        let withCloud = CloudComposition.adding(to: factories, base: base, identity: madeIdentity,
                                                sessionToken: { @MainActor in try await coordinator.accessToken() })
        realFactories = Self.addingFiles(to: Self.addingWorkspaces(
            to: Self.addingFeed(to: withCloud, base: base, identity: madeIdentity, pairing: madePairing),
            base: base, identity: madeIdentity, cloudHosts: flagStore.isEnabled(.cloudWorkspaces),
            sockets: madePairing?.hostSockets, ssh: madeSSHWorkspaces),
            connector: madePairing == nil ? nil : links)
        let ops: any CloudOpsSending
        if let base, let madeIdentity {
            ops = CloudOpsClient(baseURL: base, tokens: IdentityTokens(identity: madeIdentity))
        } else {
            ops = DisabledCloudOps()
        }
        #if DEBUG
        let environment: CloudOp.APNsEnvironment = .development
        #else
        let environment: CloudOp.APNsEnvironment = .production
        #endif
        push = PushRegistration(ops: ops, topic: Bundle.main.bundleIdentifier ?? "", environment: environment)
        let pushForPermissions = push
        permissions = SystemPermissionCenter(defaults: .standard, clock: ContinuousClock()) {
            Task { await pushForPermissions.authorizationChanged() }
        }
        feedResponder = FeedNotificationResponder(performer: OpsFeedIntentPerformer(ops: ops, device: UIDevice.current.name))
        activities = AgentActivityCenter(ops: ops)
        // C11's preferences reach the push owner and the extension (c7-notify.md section 4).
        // The keychain store the extension reads (an App Group is absent on release App IDs).
        let share = NotificationPreferencesShare(
            read: { Bundle.main.phonePushSharedStateStorage.data(forKey: NotificationPreferencesShare.key) },
            write: { Bundle.main.phonePushSharedStateStorage.setData($0, forKey: NotificationPreferencesShare.key) })
        notificationPreferencesSinkFactory = { CloudNotificationPreferencesSink(ops: ops, share: share) }
        notificationDelegate = NotificationDelegate(responder: feedResponder, router: router)
        UNUserNotificationCenter.current().delegate = notificationDelegate
        // A banner answer can arrive before auth restores (background launch):
        // bind the last user now; minting needs only its record and the key.
        if let madeIdentity { accountChanges = Task { await madeIdentity.restoreLast() } }
        // P17: a too-old refusal from the API Worker becomes Home's banner.
        if let madeIdentity {
            let report: @Sendable (ClientUpdateRequired?) async -> Void = { [weak self] required in
                await self?.setUpdateRequired(required.map { HomeUpdateRequired(minimumVersion: $0.minimumVersion) })
            }
            Task { await madeIdentity.observeUpdateRequired(report) }
        }
        // L14-2: a user sign-out removes the push target and revokes the
        // install while the Stack session still works. A passive sign-out
        // (expired session) cannot revoke; it still removes the push target.
        let pushRef = push
        auth.beforeSignOut = {
            guard let identity = madeIdentity, let user = await identity.current else { return }
            await pushRef.signOut(of: user)
            do { try await identity.revoke(user) } catch {
                Logger(subsystem: "dev.cmux.ios", category: "identity").error("install revoke failed")
            }
        }
        feedResponder.openItem = { item in
            // Replaced by the root controller, which opens the Feed tab.
            Logger(subsystem: "dev.cmux.ios", category: "push").info("open feed item \(item, privacy: .public)")
        }
        foregroundSync = ForegroundNotificationSync { [weak self] in
            guard let self, let account = self.signedInAccount else { return nil }
            return self.featureSources(for: account).feed
        }
        activities.resume()
        if madePairing != nil {
            linkDiagnosticsFactory = { AccountLinkDiagnostics(directory: madeLinks) }
            let terminals = linkTerminalSources.openTerminals
            terminalPathPasterFactory = { LinkTerminalPathPaster(terminals: terminals) }
        }
    }

    /// C6: the feed seam's real owner is `FeedDO` over `/v1/wire/feed`,
    /// authenticated as this install. Without an API origin the slot stays
    /// empty and the DEV screen shows the seam on its mock.
    private static func addingFeed(to factories: RealFeatureFactories, base: URL?,
                                   identity: InstallIdentity?, pairing: PairingComposition?) -> RealFeatureFactories {
        var factories = factories
        if let base, let identity {
            let device = UIDevice.current.name
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            // B6: the account's trust store, pairing and Mac presence (one registry per account build).
            if let pairing { factories.devices = { pairing.registry() } }
            factories.feed = {
                CloudFeedSource(apiBaseURL: base, device: device, clientVersion: version) {
                    try await identity.token(for: nil)
                }
            }
        }
        return factories
    }

    /// C5: workspaces of the account's paired Macs over the control plane;
    /// C8: the composer over the same Macs' `task:` streams.
    /// `cloudHosts` (flag `cloudWorkspaces`, read at launch) adds the team's
    /// bound Cloud machines as hosts (C12); off until the VM serves the host
    /// socket, so no socket opens that HostDO would refuse.
    private static func addingWorkspaces(to factories: RealFeatureFactories, base: URL?,
                                         identity: InstallIdentity?, cloudHosts: Bool,
                                         sockets: HostSocketPool?,
                                         ssh: SSHWorkspacesComposition) -> RealFeatureFactories {
        var factories = factories
        // A lease on each paired Mac's one `/v1/wire/host/<host>` socket
        // (D1b, shared with presence, tasks and signaling), as this install
        // (b1-control-do.md). Without an API origin each Mac shows as
        // unreachable instead of as fake data.
        let channels: any WorkspaceChannelFactory
        if let base, let identity {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            channels = ControlPlaneWorkspaceChannelFactory(
                apiBaseURL: base, appVersion: version ?? "0", reasons: WorkspacesFeature.controlPlaneReasons,
                sessions: sockets,
                install: { try await identity.ownerInstall().install },
                token: { try await identity.token(for: nil) })
        } else {
            channels = UnavailableWorkspaceChannelFactory(reason: WorkspacesFeature.controlPlaneUnavailable)
        }
        // E3: the device's SSH hosts join the list after the Macs (and Cloud
        // machines); their channels run discovery instead of a host socket.
        let routed = ssh.channels(fallback: channels)
        factories.workspaces = { devices, cloud in
            let macs = DeviceRegistryHostDirectory(registry: devices)
            var directories: [any WorkspaceHostDirectory] = [macs]
            if cloudHosts { directories.append(CloudMachineHostDirectory(source: cloud)) }
            directories.append(ssh.directory)
            return ControlPlaneWorkspaceSource(directory: CompositeHostDirectory(directories), channels: routed)
        }
        // C8: the composer's `task:<host>` streams ride the same host sockets
        // (one more subscription per Mac while a composer is open).
        let taskChannels: any WorkspaceChannelFactory
        if let controlPlane = channels as? ControlPlaneWorkspaceChannelFactory {
            taskChannels = controlPlane.streaming("task")
        } else {
            taskChannels = channels
        }
        factories.composer = { workspaces in
            ControlPlaneTaskComposerSink(workspaces: workspaces, channels: taskChannels)
        }
        return factories
    }

    /// C4: the real `FileTransfer` over the account's link clients (D1);
    /// without an API origin the files seam stays on its mock.
    private static func addingFiles(to factories: RealFeatureFactories,
                                    connector: (any FileHostConnector)?) -> RealFeatureFactories {
        guard let connector else { return factories }
        var factories = factories
        // One instance per process: one journal per file, whatever rebuilds the seams.
        let transfer = LinkFileTransfer(connector: connector, journalURL: LinkFileTransfer.defaultJournalURL)
        factories.files = { transfer }
        return factories
    }

    /// The account's files feature (built with its seams).
    func filesFeature(for sources: FeatureSources) -> FilesFeature {
        if let files { return files }
        let made = FilesFeature(transfer: sources.files, paster: terminalPathPasterFactory?(),
                                attachments: fileAttachmentSinkFactory?())
        files = made
        return made
    }

    /// The account's viewers (c13-viewers.md): real Macs read over the
    /// account's link clients (D1), the same ones files use; without an API
    /// origin they say "No connection to this Mac". Mock workspaces read the
    /// canned repository. Downloads finished in the transfer list open in
    /// its router instead of QuickLook.
    func viewersFeature(for sources: FeatureSources, real: Bool) -> ViewersFeature {
        if let viewers { return viewers }
        let source: any ViewerContentSource
        if !real {
            source = MockViewerContentSource()
        } else if pairing != nil {
            source = LinkViewerContentSource(connector: LinkClientProvider(directory: accountLinks), transfer: sources.files)
        } else {
            source = UnavailableViewerContentSource()
        }
        let made = ViewersFeature(source: source)
        filesFeature(for: sources).viewer = made.router
        viewers = made
        return made
    }

    /// DEV: the files feature of the signed-in seams, or one over the mock.
    var currentFilesFeature: FilesFeature {
        filesFeature(for: features ?? FeatureSources.mock())
    }

    /// Follows the account's remote config until sign-out.
    private func startRemoteConfig() {
        remoteConfigTask?.cancel()
        let source = remoteConfigFactory?() ?? MockRemoteConfigSource(
            remoteConfigAccountID.flatMap { remoteConfigCache.load(for: $0) } ?? .empty
        )
        remoteConfigTask = Task { [weak self] in
            for await snapshot in await source.updates() {
                guard !Task.isCancelled else { return }
                self?.applyRemoteConfig(snapshot.value)
            }
        }
    }

    private func applyRemoteConfig(_ config: RemoteConfig) {
        guard config != remoteConfig else { return }
        let wasDemo = isDemo
        remoteConfig = config
        if let account = remoteConfigAccountID { remoteConfigCache.save(config, for: account) }
        flags.applyRemote(config)
        if isDemo != wasDemo {
            diagnostics.info("demo", isDemo ? "demo content on" : "demo content off")
            onDemoChange?()
        }
    }

    private func stopRemoteConfig() {
        remoteConfigTask?.cancel()
        remoteConfigTask = nil
        if let account = remoteConfigAccountID { remoteConfigCache.clear(for: account) }
        remoteConfigAccountID = nil
        remoteConfigFactory = nil
        let wasDemo = isDemo
        remoteConfig = .empty
        flags.applyRemote(.empty)
        if isDemo != wasDemo { onDemoChange?() }
    }

    /// The Mac compatibility rules, with the account's remote floor.
    var macCompatibility: MacCompatibilityPolicy {
        MacCompatibilityPolicy(remoteMinimum: remoteConfig.minimumMacProtocol)
    }

    func makeMacCapabilitiesSource() -> any MacCapabilitiesSource {
        macCapabilitiesFactory?() ?? MockMacCapabilitiesSource()
    }

    func makeKeepAwakeControl() -> any KeepAwakeControl {
        keepAwakeFactory?() ?? MockKeepAwakeControl()
    }

    func makeBillingStore() -> any BillingStore {
        billingFactory?() ?? MockBillingStore()
    }

    func setUpdateRequired(_ requirement: HomeUpdateRequired?) {
        updateRequired = requirement
    }

    /// Application Support/ssh: SSH records and device state (no secrets).
    private static func sshDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ssh", isDirectory: true)
    }

    /// The exact-bundle URL scheme registered in Info.plist (`cmux-ios-<bundle id>`).
    private static func bundleURLScheme() -> String? {
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        return types.lazy.compactMap { ($0["CFBundleURLSchemes"] as? [String])?.first }.first
    }

    /// `Application Support/cmux-next`; nil keeps the log in memory.
    private static func diagnosticsDirectory() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("cmux-next", isDirectory: true)
    }

    /// `CMUXCloudAPIBaseURL` from Info.plist (set per configuration in the
    /// xcconfigs). Missing or not https: no ops at all (fail closed), never a
    /// fallback origin that could receive a production credential.
    private static func cloudAPIBaseURL() -> URL? {
        let raw = Bundle.main.object(forInfoDictionaryKey: "CMUXCloudAPIBaseURL") as? String ?? ""
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespaces)), url.scheme == "https",
              url.host?.isEmpty == false else { return nil }
        return url
    }

    /// The Home store for the signed-in account. Home talks only to a
    /// `HomeSource`; until the Home messaging backend lands this is the mock
    /// owner (plans/cmux-next/ios-rewrite.md, step 5).
    func homeStore(for account: SignedInAccount) -> HomeStore {
        if let home, homeAccount == account.userID { return home }
        home?.stop()
        homeAccount = account.userID
        let store = HomeStore(source: MockHomeSource())
        store.start()
        home = store
        return store
    }

    /// The feature seams for the signed-in account, built once per account
    /// and per mode change. Feature screens get only the seams they use.
    func featureSources(for account: SignedInAccount) -> FeatureSources {
        if let features, featuresAccount == account.userID, featuresDemo == isDemo { return features }
        featuresAccount = account.userID
        featuresDemo = isDemo
        // Demo mode resolves every seam to its mock (canned fixtures).
        let made = realFactories.resolve(isDemo ? [:] : sourceModes.modes)
        features = made
        browserTabs.set(made.workspaces)
        files = nil
        viewers = nil
        if mockOffline { Task { await made.setMockConnection(.offline(reason: nil)) } }
        return made
    }

    /// A mode change rebuilds the seams on next use.
    func dropFeatureSources() {
        features = nil
        featuresAccount = nil
        files = nil
        viewers = nil
    }

    func setMockOffline(_ offline: Bool) async {
        mockOffline = offline
        await features?.setMockConnection(offline ? .offline(reason: nil) : .live(path: "mock"))
    }

    /// Signing out drops the account's Home mirror. `requestPushPermission`
    /// is false while onboarding will prime the notifications prompt.
    func signedIn(account: SignedInAccount, requestPushPermission: Bool = true) {
        diagnostics.info("auth", "signed in")
        let switched = signedInAccount.map { $0.userID != account.userID } ?? false
        let previousRemoteAccount = remoteConfigAccountID
        signedInAccount = account
        remoteConfigAccountID = account.userID
        if let factory = remoteConfigFactoryForAccount {
            let accountID = account.userID
            remoteConfigFactory = { factory(accountID) }
        } else {
            remoteConfigFactory = nil
        }
        // Account-scoped flags must not remain visible during an account
        // switch while the new source performs its first network refresh.
        if switched || previousRemoteAccount != account.userID {
            applyRemoteConfig(remoteConfigCache.load(for: account.userID) ?? .empty)
        }
        startLinks(resetting: switched)
        startRemoteConfig()
        let coordinator = auth.coordinator
        let identity = self.identity
        let push = self.push
        let previous = accountChanges
        accountChanges = Task {
            await previous?.value
            if let replaced = await identity?.signedIn(stackUser: account.userID,
                                                      sessionToken: { @MainActor in try await coordinator.accessToken() }) {
                // A direct switch: the old account's target goes first.
                await push.signOut(of: replaced)
                await identity?.signedOut(of: replaced)
            }
            await push.start(for: account.userID, requestPermission: requestPushPermission)
            // This install starts on the owner's defaults: send the device's choice.
            await MainActor.run { self.notificationPreferences.resend() }
        }
        foregroundSync?.run()
    }

    func signedOut() {
        diagnostics.info("auth", "signed out")
        signedInAccount = nil
        foregroundSync?.cancel()
        stopRemoteConfig()
        let identity = self.identity
        let push = self.push
        let previous = accountChanges
        // Remove the push target as the signed-out user's install, then forget it.
        accountChanges = Task {
            await previous?.value
            guard let user = await identity?.current else { return }
            await push.signOut(of: user)
            await identity?.signedOut(of: user)
        }
        home?.stop()
        home = nil
        homeAccount = nil
        dropFeatureSources()
        terminalCompose.clearAll()
        accountLinks.stop()
        if let pairing {
            Task {
                await pairing.cache.reset()
                await pairing.hostSockets.stopAll()
            }
        }
    }

    /// Binds the account's links (D1): routes from B6's trust store, Bonjour
    /// and saved direct addresses; an account switch drops the old runtime first.
    private func startLinks(resetting: Bool) {
        guard let pairing else { return }
        let composition = LinkComposition(pairing: pairing, bundleID: Bundle.main.bundleIdentifier ?? "",
                                          appVersion: pairing.appVersion, dev: linkDev)
        let reset: Task<Void, Never>? = resetting ? Task {
            await pairing.cache.reset()
            await pairing.hostSockets.stopAll()
        } : nil
        accountLinks.start(bootstrap: {
            await reset?.value
            return try await composition.bootstrap()
        }, saved: SavedDirectEndpoints.stream(from: localHosts))
    }

    var apiBaseURL: String { auth.composition.config.apiBaseURL }

    /// Signed out by choice: the guest shell shows instead of sign-in.
    var isGuest: Bool { guestPolicy.isGuest(stored: guestMode.isChosen) }

    /// The guest shell's hosts: the device's owner, recording what is added.
    var guestHosts: any HostsStore {
        GuestRecordingHostsStore(base: localHosts, ledger: guestHostsLedger)
    }

    /// Hosts added signed out that still exist (the sync offer).
    func pendingGuestHosts() async -> [HostRecord] {
        await guestHostsLedger.pending(in: await localHosts.current())
    }

    /// Joins hosts added signed out to the account's synced set.
    func adoptGuestHosts(_ hosts: [HostID]) async {
        await LocalHostsAdopter(store: localHosts).adopt(hosts)
        await guestHostsLedger.clear()
    }
}

/// Adapts the install principal to the push client's token seam.
struct IdentityTokens: InstallTokenProviding {
    let identity: InstallIdentity
    func installToken(for user: String?) async throws -> String { try await identity.token(for: user) }
    func invalidate(for user: String?) async { await identity.invalidate(for: user) }
}
