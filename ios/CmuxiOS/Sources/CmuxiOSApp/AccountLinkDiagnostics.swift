import CmuxiOSFeatureKit
import CmuxiOSPairingCore
import CmuxiOSSettingsCore
import CmuxiOSTerminalLink
import CmuxLink

/// C11's live path badges (`LinkDiagnosticsSource`) from the account's link
/// directory: a badge per Mac, keyed by the device record that Mac has in
/// the B6 registry (own Mac: its install; another account's host: the
/// pairing of this install).
struct AccountLinkDiagnostics: LinkDiagnosticsSource {
    let directory: AccountLinkDirectory

    func updates() async -> AsyncStream<[DeviceRecord.ID: PathBadge]> {
        let directory = self.directory
        let badges = await directory.pathBadges()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task { @MainActor in
                for await byHost in badges {
                    var byDevice: [DeviceRecord.ID: PathBadge] = [:]
                    for (host, badge) in byHost {
                        guard let key = directory.trustedHost(host) else { continue }
                        let id: DeviceRecordID = key.isOwnAccount
                            ? .install(key.install)
                            : .remote(host: host, install: directory.install ?? "")
                        byDevice[id.rawValue] = badge
                    }
                    continuation.yield(byDevice)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
