import CmuxControlPlane
import CmuxiOSFeatureKit
import CmuxiOSIdentity
import CmuxiOSPairingCore
import CmuxMobileWire
import CmuxPairing
import Foundation

/// Builds lane B6's real `DeviceRegistry` (plans/cmux-next/ios-next/b6-pairing.md):
/// the account's `/v1/wire/user` socket for the trust store and pairing ops,
/// and one HostDO socket per Mac, all as this install.
///
/// One runtime per account, shared: the device registry (rebuilt whenever
/// the feature seams are) and the link directory (D1) read the same trust
/// store mirror. `cache` owns its lifetime; the account change resets it.
///
/// `hostSockets` is the one HostDO socket per Mac (D1b) that presence (B6),
/// workspaces (C5), tasks (C8) and WebRTC signaling (D1) lease; HostDO keeps
/// one socket per install and closed the others when each opened its own.
struct PairingComposition {
    let base: URL
    let identity: InstallIdentity
    let bundleID: String
    let appVersion: String
    let cache = PairingRuntimeCache()
    let hostSockets: HostSocketPool

    init(base: URL, identity: InstallIdentity, bundleID: String, appVersion: String) {
        self.base = base
        self.identity = identity
        self.bundleID = bundleID
        self.appVersion = appVersion
        hostSockets = HostSocketPool { host, team in
            let install = try await identity.ownerInstall().install
            return Self.client(base: base, identity: identity, appVersion: appVersion,
                               path: "/v1/wire/host/\(host)", query: team.map { "team=\($0)" }, install: install)
        }
    }

    func registry() -> any DeviceRegistry {
        let composition = self
        return ControlPlaneDeviceRegistry {
            var runtime = try await composition.sharedRuntime()
            // The cache stops it on sign-out; a rebuilt registry must not.
            runtime.stop = {}
            return runtime
        }
    }

    /// The account's runtime, made once per account.
    func sharedRuntime() async throws -> PairingRuntime {
        let composition = self
        return try await cache.runtime { try await composition.runtime() }
    }

    /// A lease on `host`'s shared socket; `team` for another account's Mac.
    func hostSession(host: String, team: String?) async -> any ControlPlaneSession {
        await hostSockets.session(host: host, team: team)
    }

    private func runtime() async throws -> PairingRuntime {
        let owner = try await identity.ownerInstall()
        let account = PairingAccount(user: owner.user, install: owner.install, environment: owner.environment)
        let user = client(path: "/v1/wire/user", query: nil, install: owner.install)
        await user.start()
        let mirror = TrustStoreMirror()
        await mirror.start(client: user, user: owner.user)
        let ops = ControlPlanePairingOps(client: user, mirror: mirror, account: account, signer: IdentityLinkSigner(identity: identity),
                                         keys: KeychainDirectKeyStore(bundleID: bundleID, environment: owner.environment),
                                         wireGuardKeys: KeychainDirectKeyStore(bundleID: bundleID, environment: owner.environment,
                                                                               purpose: .wg))
        let sockets = hostSockets
        let presence = ControlPlaneHostPresence { host, team in
            await sockets.session(host: host, team: team.isEmpty ? nil : team)
        }
        return PairingRuntime(account: account, mirror: mirror, ops: ops, presence: presence) {
            await mirror.stop()
            await user.stop()
        }
    }

    private func client(path: String, query: String?, install: String) -> ControlPlaneClient {
        Self.client(base: base, identity: identity, appVersion: appVersion, path: path, query: query, install: install)
    }

    private static func client(base: URL, identity: InstallIdentity, appVersion: String, path: String, query: String?,
                               install: String) -> ControlPlaneClient {
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        components.path = path
        components.query = query
        let configuration = ControlPlaneConfiguration(url: components.url!, client: HelloClient(install: install, platform: "ios", appVersion: appVersion))
        return ControlPlaneClient(configuration: configuration, transport: URLSessionControlPlaneTransport()) {
            try await identity.token(for: nil)
        }
    }
}
