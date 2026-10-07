import CmuxFeedPushCore
import CmuxHomeCore
import CmuxHomeUI
import CMUXMobileCore
import CmuxiOSAuth
import CmuxiOSCrashReporting
import CmuxiOSFeatureKit
import CmuxiOSIdentity
import CmuxiOSPlatform
import CmuxiOSOnboarding
import CmuxiOSOnboardingCore
import CmuxiOSPush
import CmuxiOSShell
import CmuxiOSSSHCore
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
    /// B1 fills this when the control plane serves `config.snapshot`; nil
    /// keeps the mock (an empty config).
    var remoteConfigFactory: (@Sendable () -> any RemoteConfigSource)?
    private let remoteConfigCache = RemoteConfigCache()
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
    /// SSH state that stays on this device (lane C9): logins, keys, pins.
    let sshDevice: SSHDeviceState
    /// Lane C1 sets the cmux session host's byte sources (`.host` over
    /// `CmuxLink`); nil keeps A2's mock host behind workspace terminals.
    var terminalSources: (any WorkspaceTerminalSourceFactory)?
    private var features: FeatureSources?
    private var featuresAccount: String?
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
        auth = StackAuthGate(composition: composition)
        devOptions = DevOptions(environment: environment)
        #if DEBUG
        let isDebug = true
        #else
        let isDebug = false
        #endif
        flags = FeatureFlagStore(environment: environment, isDebug: isDebug)
        // Lane C9: SSH and direct host records live on this device until B1
        // syncs them; one owner instance per process, shared by every shell.
        let sshDirectory = Self.sshDirectory()
        sshDevice = SSHDeviceState(directory: sshDirectory)
        let localHosts = LocalHostsStore(url: sshDirectory.appendingPathComponent("hosts.json"))
        var factories = RealFeatureFactories()
        factories.hosts = { localHosts }
        // Lane C5: workspaces of the account's paired Macs over the control
        // plane. B1 replaces the channel factory with its ControlPlaneClient
        // adapter (c5-workspaces.md section 4); until then each Mac shows as
        // unreachable with this reason.
        let unavailable = WorkspacesFeature.controlPlaneUnavailable
        factories.workspaces = { devices in
            ControlPlaneWorkspaceSource(directory: DeviceRegistryHostDirectory(registry: devices),
                                        channels: UnavailableWorkspaceChannelFactory(reason: unavailable))
        }
        realFactories = factories
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
        feedResponder = FeedNotificationResponder(ops: ops)
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
        // The last account's config applies before auth restores; sign-out clears it.
        if let cached = remoteConfigCache.load() { applyRemoteConfig(cached) }
        feedResponder.openItem = { item in
            // The feed list is not on iPhone yet; Home stays in front.
            Logger(subsystem: "dev.cmux.ios", category: "push").info("open feed item \(item, privacy: .public)")
        }
    }

    /// Follows the account's remote config until sign-out.
    private func startRemoteConfig() {
        remoteConfigTask?.cancel()
        let source = remoteConfigFactory?() ?? MockRemoteConfigSource(remoteConfigCache.load() ?? .empty)
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
        remoteConfigCache.save(config)
        flags.applyRemote(config)
        if isDemo != wasDemo {
            diagnostics.info("demo", isDemo ? "demo content on" : "demo content off")
            onDemoChange?()
        }
    }

    private func stopRemoteConfig() {
        remoteConfigTask?.cancel()
        remoteConfigTask = nil
        remoteConfigCache.clear()
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
        if mockOffline { Task { await made.setMockConnection(.offline(reason: nil)) } }
        return made
    }

    /// A mode change rebuilds the seams on next use.
    func dropFeatureSources() {
        features = nil
        featuresAccount = nil
    }

    func setMockOffline(_ offline: Bool) async {
        mockOffline = offline
        await features?.setMockConnection(offline ? .offline(reason: nil) : .live(path: "mock"))
    }

    /// Signing out drops the account's Home mirror. `requestPushPermission`
    /// is false while onboarding will prime the notifications prompt.
    func signedIn(account: SignedInAccount, requestPushPermission: Bool = true) {
        diagnostics.info("auth", "signed in")
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
        }
    }

    func signedOut() {
        diagnostics.info("auth", "signed out")
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
    }

    var apiBaseURL: String { auth.composition.config.apiBaseURL }
}

/// Adapts the install principal to the push client's token seam.
struct IdentityTokens: InstallTokenProviding {
    let identity: InstallIdentity
    func installToken(for user: String?) async throws -> String { try await identity.token(for: user) }
    func invalidate(for user: String?) async { await identity.invalidate(for: user) }
}
