public import CmuxiOSFeatureKit
import Foundation
public import Observation

/// State behind the Settings tab. Devices mirror `DeviceRegistry` while the
/// screen is visible; account and actions come from the composition root.
@MainActor
@Observable
public final class ShellSettingsModel {
    public let account: ShellAccount
    public let about: ShellAbout
    public private(set) var devices: [DeviceRecord] = []
    public private(set) var devicesConnection: SourceConnection = .connecting
    public private(set) var isSigningOut = false
    @ObservationIgnored private let registry: any DeviceRegistry
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
        signOut: @escaping @MainActor () async -> Void
    ) {
        self.account = account
        self.about = about
        self.registry = registry
        self.developer = developer
        self.links = links
        self.replayTour = replayTour
        signOutAction = signOut
    }

    /// Mirrors the device registry until the calling task is cancelled
    /// (SwiftUI's `.task` cancels it when Settings leaves the screen).
    public func observeDevices() async {
        for await snapshot in await registry.updates() {
            devices = snapshot.value.filter { $0.trust != .revoked }
            devicesConnection = snapshot.connection
        }
    }

    public func signOut() async {
        guard !isSigningOut else { return }
        isSigningOut = true
        await signOutAction()
        isSigningOut = false
    }
}
