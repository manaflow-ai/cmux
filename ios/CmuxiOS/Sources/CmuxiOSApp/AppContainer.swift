import CmuxFeedPushCore
import CmuxHomeCore
import CmuxHomeUI
import CmuxiOSAuth
import CmuxiOSIdentity
import CmuxiOSPush
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
    let push: PushRegistration
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
        auth = StackAuthGate(composition: composition)
        devOptions = DevOptions(environment: environment)
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
        feedResponder = FeedNotificationResponder(ops: ops)
        notificationDelegate = NotificationDelegate(responder: feedResponder)
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
            // The feed list is not on iPhone yet; Home stays in front.
            Logger(subsystem: "dev.cmux.ios", category: "push").info("open feed item \(item, privacy: .public)")
        }
    }

    func setUpdateRequired(_ requirement: HomeUpdateRequired?) {
        updateRequired = requirement
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

    /// Signing out drops the account's Home mirror.
    func signedIn(account: SignedInAccount) {
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
            await push.start(for: account.userID)
        }
    }

    func signedOut() {
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
    }

    var apiBaseURL: String { auth.composition.config.apiBaseURL }
}

/// Adapts the install principal to the push client's token seam.
struct IdentityTokens: InstallTokenProviding {
    let identity: InstallIdentity
    func installToken(for user: String?) async throws -> String { try await identity.token(for: user) }
    func invalidate(for user: String?) async { await identity.invalidate(for: user) }
}
