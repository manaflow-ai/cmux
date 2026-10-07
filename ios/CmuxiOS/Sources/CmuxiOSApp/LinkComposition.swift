import CmuxControlPlane
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
        // Macs authorize the Noise key through its published cert (B4/B5).
        try? await runtime.ops.ensureDirectKeyPublished()
        let direct = try DirectIdentity(
            privateKeyRepresentation: KeychainDirectKeyStore(bundleID: bundleID, environment: account.environment).privateKey())
        let installKey = try InstallKeyLinkIdentity(
            install: account.install, signer: SecureEnclaveInstallSigner(bundleID: bundleID, environment: account.environment))
        let credentials = MobileDeviceCredentials(
            signer: installKey, client: HelloClient(install: account.install, platform: "ios", appVersion: appVersion),
            direct: direct, webrtc: installKey,
            // V2 needs a published `wg` cert, which B6 does not publish from the phone yet.
            wireGuard: nil)
        let pairing = self.pairing
        return AccountLinkBootstrap(
            credentials: credentials, mirror: runtime.mirror,
            lookup: TrustStoreKeyLookup(mirror: runtime.mirror, environment: account.environment, user: account.user),
            options: MobileConnectOptions(wireGuardOverWebRTC: dev.wireGuardOverWebRTC),
            signaling: { host in
                let client = pairing.controlClient(path: "/v1/wire/host/\(host)", install: account.install)
                Task { await client.start() }
                let relay = ControlPlaneSignaling(client: client)
                return MobileHostSignaling(router: SignalRouter(channel: relay), iceServers: relay, close: { await client.stop() })
            })
    }
}
