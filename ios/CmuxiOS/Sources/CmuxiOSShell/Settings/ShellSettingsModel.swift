public import CmuxiOSFeatureKit
public import CmuxiOSSettingsCore
import Foundation
public import Observation

/// State behind the Settings tab (plans/cmux-next/ios-next/c11-settings.md).
/// Devices mirror `DeviceRegistry` (plus link badges) while the screen is
/// visible; account, preferences and actions come from the composition root.
/// Every optional part hides its section when nil.
@MainActor
@Observable
public final class ShellSettingsModel {
    /// The account as auth reported it at shell build time; the Account
    /// section prefers `accountModel`'s live snapshot when present.
    public let account: ShellAccount
    public let about: ShellAbout
    public private(set) var isSigningOut = false
    /// A page pushed on the Settings stack from outside (lane C15 search);
    /// the stack clears it when the user goes back.
    public var openedPage: ShellSettingsPage?
    /// Devices & Macs.
    public let devicesModel: DeviceSettingsModel
    /// Team switcher and Delete Account; nil hides both.
    public let accountModel: AccountSettingsModel?
    public let terminal: TerminalPreferencesStore?
    public let notifications: NotificationPreferencesStore?
    @ObservationIgnored public let notificationAuthorization: (any NotificationAuthorizationReading)?
    public let privacy: PrivacyPreferences?
    /// The haptics toggle (lane E5); nil hides it.
    public let haptics: HapticsSettings?
    /// Erase All Data (lane E5): the app's wipe; nil hides the section.
    @ObservationIgnored public let eraseAllData: (@MainActor () async -> EraseReport)?
    @ObservationIgnored private let signOutAction: @MainActor () async -> Void
    /// DEBUG builds pass the DEV screen; nil hides the Developer section.
    @ObservationIgnored public let developer: (@MainActor () -> DevSourcesModel)?
    /// Rows added by the composition root (platform screens), in order.
    @ObservationIgnored public let links: [ShellSettingsLink]
    /// Replays the welcome tour (lane C10); nil hides the row.
    @ObservationIgnored public let replayTour: (@MainActor () -> Void)?

    public init(
        account: ShellAccount, about: ShellAbout, registry: any DeviceRegistry,
        developer: (@MainActor () -> DevSourcesModel)?, links: [ShellSettingsLink] = [],
        replayTour: (@MainActor () -> Void)? = nil,
        accountController: (any AccountControlling)? = nil,
        linkDiagnostics: (any LinkDiagnosticsSource)? = nil,
        terminal: TerminalPreferencesStore? = nil,
        notifications: NotificationPreferencesStore? = nil,
        notificationAuthorization: (any NotificationAuthorizationReading)? = nil,
        privacy: PrivacyPreferences? = nil,
        haptics: HapticsSettings? = nil,
        eraseAllData: (@MainActor () async -> EraseReport)? = nil,
        signOut: @escaping @MainActor () async -> Void
    ) {
        self.account = account
        self.about = about
        devicesModel = DeviceSettingsModel(registry: registry, links: linkDiagnostics)
        accountModel = accountController.map(AccountSettingsModel.init(controller:))
        self.terminal = terminal
        self.notifications = notifications
        self.notificationAuthorization = notificationAuthorization
        self.privacy = privacy
        self.haptics = haptics
        self.eraseAllData = eraseAllData
        self.developer = developer
        self.links = links
        self.replayTour = replayTour
        signOutAction = signOut
    }

    /// The profile the Account section shows.
    public var profile: ShellAccount {
        guard let snapshot = accountModel?.snapshot else { return account }
        return ShellAccount(displayName: snapshot.displayName, email: snapshot.email)
    }

    /// Mirrors devices, link badges and the account until the calling task
    /// is cancelled (SwiftUI's `.task` cancels it when Settings leaves).
    public func observe() async {
        await withDiscardingTaskGroup { group in
            group.addTask { await self.devicesModel.observe() }
            if let accountModel = self.accountModel {
                group.addTask { await accountModel.observe() }
            }
        }
    }

    /// A fresh typed confirmation for one presentation of Erase All Data.
    func makeEraseModel() -> EraseAllDataModel? {
        guard let eraseAllData else { return nil }
        return EraseAllDataModel(rule: EraseConfirmationRule(word: SettingsText.eraseWord), perform: eraseAllData)
    }

    public func signOut() async {
        guard !isSigningOut else { return }
        isSigningOut = true
        await signOutAction()
        isSigningOut = false
    }
}
