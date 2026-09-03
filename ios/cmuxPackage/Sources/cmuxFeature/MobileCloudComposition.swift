#if os(iOS)
import CMUXMobileCore
import CmuxAuthRuntime
import CmuxMobileCloud
import CmuxMobileCloudUI
import Foundation
import UIKit

/// Builds the app's one ``CloudSessionController`` from the auth composition.
///
/// The controller owns the in-process WireGuard tunnel and daemon links for
/// the Cloud section. Tokens are read live through the coordinator, the
/// WireGuard identity lives in a per-bundle Keychain item, and the link
/// client's device identity persists under Application Support.
enum MobileCloudComposition {
    /// The Keychain service base; the bundle id is appended so tagged builds
    /// never share a tunnel identity.
    static let keychainServiceBase = "com.cmuxterm.cloud.wireguard.v1"
    /// The Application Support subdirectory for the link client's state.
    static let stateDirectoryName = "cmux-cloud-remote"

    @MainActor
    static func makeController(auth: MobileAuthComposition) -> CloudSessionController? {
        let baseURL = auth.config.apiBaseURL
        guard !baseURL.isEmpty, let appNamespace = auth.appNamespace else { return nil }
        let coordinator = auth.coordinator
        let service = CloudVMService(
            baseURL: baseURL,
            tokens: CloudAPITokenSource(
                accessToken: { try? await coordinator.accessToken() },
                refreshToken: { await coordinator.refreshToken() }
            )
        )
        let identityStore = KeychainCloudDeviceIdentityStore(
            service: appNamespace.keychainService(base: keychainServiceBase),
            accessGroup: auth.keychainAccessGroup
        )
        return CloudSessionController(
            service: service,
            identityStore: identityStore,
            tunnelStarter: CmuxTerminalClientCloudTunnelStarter(),
            connector: CmuxTerminalClientCloudConnector(),
            stateDirectory: stateDirectory(),
            deviceName: UIDevice.current.name
        )
    }

    /// `<Application Support>/cmux-cloud-remote`, created 0700 on first use.
    static func stateDirectory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let directory = base.appendingPathComponent(stateDirectoryName, isDirectory: true)
        try? fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }
}
#endif
