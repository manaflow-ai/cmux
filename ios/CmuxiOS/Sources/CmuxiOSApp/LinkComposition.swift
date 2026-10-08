import CmuxControlPlane
import CmuxiOSFeatureKit
import CmuxiOSIdentity
import CmuxiOSPairingCore
import CmuxiOSTerminalLink
import CmuxLinkDirect
import CmuxLinkSignaling
import CmuxLinkWebRTC
import CmuxMobileConnect
import CmuxMobileWire
import CmuxPairing
import Foundation

/// Builds what the account's link directory needs (d1-terminal-ux.md
/// section 2): the shared B6 runtime (trust store mirror), this install's
/// keys (Secure Enclave install key for hello and WebRTC, Keychain X25519
/// `direct` key, published so Macs accept it), and one HostDO signaling
/// socket per Mac (B1) for B2/B3.
struct LinkComposition {
    let pairing: PairingComposition
    let bundleID: String
    let appVersion: String
    let dev: LinkDevOptions

    func bootstrap() async throws -> AccountLinkBootstrap {
        let runtime = try await pairing.sharedRuntime()
        let account = runtime.account
        // Macs authorize the Noise key (B4/B5) and the WireGuard key (B3) only
        // through their published certs.
        Self.publishWhenLive(runtime.ops, wireGuard: dev.wireGuardOverWebRTC)
        let direct = try DirectIdentity(
            privateKeyRepresentation: KeychainDirectKeyStore(bundleID: bundleID, environment: account.environment).privateKey())
        let installKey = try InstallKeyLinkIdentity(
            install: account.install, signer: SecureEnclaveInstallSigner(bundleID: bundleID, environment: account.environment))
        var credentials = MobileDeviceCredentials(
            signer: installKey, client: HelloClient(install: account.install, platform: "ios", appVersion: appVersion),
            direct: direct, webrtc: installKey)
        if dev.wireGuardOverWebRTC {
            // V2 (DEV switch): the key the published `wg` cert names.
            try? credentials.useWireGuardKey(rawRepresentation: KeychainDirectKeyStore(
                bundleID: bundleID, environment: account.environment, purpose: .wg).privateKey())
        }
        let pairing = self.pairing
        return AccountLinkBootstrap(
            credentials: credentials, mirror: runtime.mirror,
            lookup: TrustStoreKeyLookup(mirror: runtime.mirror, environment: account.environment, user: account.user),
            options: MobileConnectOptions(transport: dev.transport,
                                           wireGuardOverWebRTC: dev.wireGuardOverWebRTC),
            signaling: { route in
                // A lease on the Mac's shared host socket (D1b), with `team=` for another account's Mac.
                let session = pairing.hostSockets.deferredSession(host: route.hostID, team: route.team)
                Task { await session.start() }
                let relay = ControlPlaneSignaling(client: session)
                return MobileHostSignaling(router: SignalRouter(channel: relay), iceServers: relay, close: { await session.stop() })
            })
    }

    /// Publishes this install's link certs once the account socket is live
    /// (ops need a negotiated socket and nothing queues), retrying on the next
    /// live connection after a failure.
    private static func publishWhenLive(_ ops: any PairingOps, wireGuard: Bool) {
        Task {
            for await connection in await ops.connectionStates() where connection.isLive {
                do {
                    try await ops.ensureDirectKeyPublished()
                    if wireGuard { try await ops.ensureWireGuardKeyPublished() }
                    return
                } catch {
                    continue
                }
            }
        }
    }
}
