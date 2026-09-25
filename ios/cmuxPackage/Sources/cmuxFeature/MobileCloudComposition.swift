#if os(iOS)
import CMUXMobileCore
import CmuxAuthRuntime
import CmuxMobileCloud
import CmuxMobileCloudBridge
import CmuxMobileCloudUI
import Foundation
import UIKit

/// Builds the app's one ``CloudSessionController`` from the auth composition.
///
/// The controller owns the in-process WireGuard tunnel and daemon links for
/// the Cloud section. Tokens are read live through the coordinator, the
/// WireGuard identity lives in a per-bundle Keychain item, and the link
/// client's device identity persists under Application Support.
struct MobileCloudComposition {
    private let auth: MobileAuthComposition
    private let deviceID: @Sendable () async -> String?

    init(auth: MobileAuthComposition, deviceID: @escaping @Sendable () async -> String?) {
        self.auth = auth
        self.deviceID = deviceID
    }

    /// The Keychain service base; the bundle id is appended so tagged builds
    /// never share a tunnel identity.
    static let keychainServiceBase = "com.cmuxterm.cloud.wireguard.v1"
    /// The Application Support subdirectory for the link client's state.
    static let stateDirectoryName = "cmux-cloud-remote"

    @MainActor
    func makeController() -> CloudSessionController? {
        let baseURL = MobileAuthComposition.cloudAPIBaseURL(
            authEnvironment: auth.authEnvironment,
            configuredBaseURL: auth.config.apiBaseURL
        )
        guard !baseURL.isEmpty, let appNamespace = auth.appNamespace else { return nil }
        let coordinator = auth.coordinator
        // The app injects the active Iroh installation's identity reader.
        // Unavailable protected storage defers enrollment without minting a new ID.
        let service = CloudVMService(
            baseURL: baseURL,
            tokens: CloudAPITokenSource(
                accessToken: { try? await coordinator.accessToken() },
                refreshToken: { await coordinator.refreshToken() },
                teamID: { await coordinator.resolvedTeamID },
                coherentTokenPair: { try? await coordinator.coherentTokenPair() }
            ),
            deviceID: deviceID
        )
        // Unsigned simulator apps cannot use the data-protection Keychain (no
        // application-identifier entitlement), mirroring DeviceIdentityStore's
        // simulator split. Physical devices always use the Keychain.
        #if targetEnvironment(simulator)
        let identityStore: any CloudDeviceIdentityStoring = UserDefaultsCloudDeviceIdentityStore(defaults: .standard)
        _ = appNamespace
        #else
        let identityStore: any CloudDeviceIdentityStoring = KeychainCloudDeviceIdentityStore(
            service: appNamespace.keychainService(base: Self.keychainServiceBase),
            accessGroup: auth.keychainAccessGroup
        )
        #endif
        return CloudSessionController(
            service: service,
            identityStore: identityStore,
            tunnelStarter: CmuxTerminalClientCloudTunnelStarter(),
            connector: CmuxTerminalClientCloudConnector(),
            stateDirectory: stateDirectory(),
            deviceName: UIDevice.current.name
        )
    }

    /// Builds the bridge that publishes a controller's machines into the
    /// workspace experience, so their terminals open in the Workspaces tab
    /// through the same views a paired Mac's do.
    @MainActor
    func makeWorkspaceBridge(controller: CloudSessionController) -> CloudWorkspaceBridge {
        CloudWorkspaceBridge(controller: controller)
    }

    /// `<Application Support>/cmux-cloud-remote`, created 0700 on first use.
    private func stateDirectory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let directory = base.appendingPathComponent(Self.stateDirectoryName, isDirectory: true)
        try? fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }
}
#endif
