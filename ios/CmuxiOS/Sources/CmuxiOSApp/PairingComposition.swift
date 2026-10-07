import CmuxControlPlane
import CmuxiOSFeatureKit
import CmuxiOSIdentity
import CmuxiOSPairingCore
import CmuxMobileWire
import CmuxPairing
import Foundation

/// Builds lane B6's real `DeviceRegistry` (plans/cmux-next/ios-next/b6-pairing.md):
/// the account's `/v1/wire/user` socket for the trust store and pairing ops,
/// and one HostDO socket per Mac for presence, all as this install.
struct PairingComposition {
    let base: URL
    let identity: InstallIdentity
    let bundleID: String
    let appVersion: String

    func registry() -> any DeviceRegistry {
        let composition = self
        return ControlPlaneDeviceRegistry { try await composition.runtime() }
    }

    private func runtime() async throws -> PairingRuntime {
        let owner = try await identity.ownerInstall()
        let account = PairingAccount(user: owner.user, install: owner.install, environment: owner.environment)
        let user = client(path: "/v1/wire/user", query: nil, install: owner.install)
        await user.start()
        let mirror = TrustStoreMirror()
        await mirror.start(client: user, user: owner.user)
        let ops = ControlPlanePairingOps(client: user, mirror: mirror, account: account, signer: IdentityLinkSigner(identity: identity),
                                         keys: KeychainDirectKeyStore(bundleID: bundleID, environment: owner.environment))
        let presence = ControlPlaneHostPresence { host, team in
            client(path: "/v1/wire/host/\(host)", query: team.isEmpty ? nil : "team=\(team)", install: owner.install)
        }
        return PairingRuntime(account: account, mirror: mirror, ops: ops, presence: presence) {
            await mirror.stop()
            await user.stop()
        }
    }

    private func client(path: String, query: String?, install: String) -> ControlPlaneClient {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.path = path
        components.query = query
        let identity = self.identity
        let configuration = ControlPlaneConfiguration(url: components.url!, client: HelloClient(install: install, platform: "ios", appVersion: appVersion))
        return ControlPlaneClient(configuration: configuration, transport: URLSessionControlPlaneTransport()) {
            try await identity.token(for: nil)
        }
    }
}
