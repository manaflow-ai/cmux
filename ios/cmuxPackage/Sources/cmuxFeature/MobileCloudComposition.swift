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

    /// The Keychain service base for the system VPN's configuration item.
    static let systemVPNKeychainServiceBase = "com.cmuxterm.cloud.system-vpn.v1"
    /// The Info.plist key naming the packet tunnel extension's bundle id.
    static let systemVPNProviderInfoKey = "CMUXCloudVPNProviderBundleIdentifier"

    @MainActor
    func makeController() -> CloudSessionController? {
        guard let service = makeService(), let identityStore = makeIdentityStore() else { return nil }
        return CloudSessionController(
            service: service,
            identityStore: identityStore,
            tunnelStarter: CmuxTerminalClientCloudTunnelStarter(),
            connector: CmuxTerminalClientCloudConnector(),
            stateDirectory: stateDirectory(),
            deviceName: UIDevice.current.name
        )
    }

    /// Builds the optional system VPN, or nil when this build does not embed
    /// the packet tunnel extension, which hides its switch.
    @MainActor
    func makeSystemVPNController(bundle: Bundle = .main) -> CloudSystemVPNController? {
        guard let service = makeService(),
              let identityStore = makeIdentityStore(),
              let appNamespace = auth.appNamespace,
              let providerID = bundle.object(forInfoDictionaryKey: Self.systemVPNProviderInfoKey) as? String,
              let plugIns = bundle.builtInPlugInsURL,
              let provider = Bundle(url: plugIns.appendingPathComponent("CloudVPN.appex")),
              provider.bundleIdentifier == providerID else { return nil }
        let coordinator = auth.coordinator
        return CloudSystemVPNController(
            service: service,
            identityStore: identityStore,
            manager: CloudSystemVPNPreferences(
                providerBundleIdentifier: providerID,
                keychainService: appNamespace.keychainService(base: Self.systemVPNKeychainServiceBase),
                keychainAccessGroup: auth.keychainAccessGroup
            ),
            deviceName: UIDevice.current.name,
            credentials: {
                try? await coordinator.coherentTokenPair()
            },
            pendingRevocationStore: UserDefaultsCloudSystemVPNPendingRevocationStore(
                defaults: .standard
            )
        )
    }

    /// Builds the bridge that publishes a controller's machines into the
    /// workspace experience, so their terminals open in the Workspaces tab
    /// through the same views a paired Mac's do.
    @MainActor
    func makeWorkspaceBridge(controller: CloudSessionController) -> CloudWorkspaceBridge {
        CloudWorkspaceBridge(links: controller, visibility: controller)
    }

    /// The `/api/vm` client, or nil when the build has no API origin.
    private func makeService() -> CloudVMService? {
        let baseURL = MobileAuthComposition.cloudAPIBaseURL(
            authEnvironment: auth.authEnvironment,
            configuredBaseURL: auth.config.apiBaseURL
        )
        guard !baseURL.isEmpty else { return nil }
        let coordinator = auth.coordinator
        // The app injects the active Iroh installation's identity reader.
        // Unavailable protected storage defers enrollment without minting a new ID.
        return CloudVMService(
            baseURL: baseURL,
            tokens: CloudAPITokenSource(
                coherentTokenPair: {
                    // Only a rejected session is a sign-out. Anything else (a
                    // refresh or sign-in step still in flight, no network) is
                    // transient, and throwing lets the list retry it.
                    do {
                        return try await coordinator.coherentTokenPair()
                    } catch AuthError.unauthorized {
                        return nil
                    }
                },
                teamID: { await coordinator.resolvedTeamID }
            ),
            deviceID: deviceID
        )
    }

    /// The device identity store both Cloud controllers read, so the terminal
    /// tunnel and the system VPN are filed under one device.
    private func makeIdentityStore() -> (any CloudDeviceIdentityStoring)? {
        guard let appNamespace = auth.appNamespace else { return nil }
        // Unsigned simulator apps cannot use the data-protection Keychain (no
        // application-identifier entitlement), mirroring DeviceIdentityStore's
        // simulator split. Physical devices always use the Keychain.
        #if targetEnvironment(simulator)
        _ = appNamespace
        return UserDefaultsCloudDeviceIdentityStore(defaults: .standard)
        #else
        return KeychainCloudDeviceIdentityStore(
            service: appNamespace.keychainService(base: Self.keychainServiceBase),
            accessGroup: auth.keychainAccessGroup
        )
        #endif
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
