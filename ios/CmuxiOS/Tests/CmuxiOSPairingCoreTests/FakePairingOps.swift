import CmuxiOSFeatureKit
import CmuxiOSPairingCore
import CmuxMobileWire
import CmuxPairing
import CryptoKit
import Foundation

/// Owner calls recorded in order; each answer is scripted. Successful
/// intents commit to the mirror only through owner events (`mirror.apply`).
actor FakePairingOps: PairingOps {
    var calls: [String] = []
    var claimResult: PairingClaimResult?
    var claimError: (any Error)?
    var publishError: (any Error)?
    let connection: AsyncStream<SourceConnection>
    let connectionSink: AsyncStream<SourceConnection>.Continuation

    init() {
        (connection, connectionSink) = AsyncStream.makeStream(of: SourceConnection.self)
        connectionSink.yield(.live(path: nil))
    }

    func script(claim: PairingClaimResult?, error: (any Error)? = nil) {
        claimResult = claim
        claimError = error
    }

    func failPublish(_ error: any Error) { publishError = error }

    nonisolated func connectionStates() async -> AsyncStream<SourceConnection> { connection }
    func ensureDirectKeyPublished() async throws {
        calls.append("publish")
        if let publishError { throw publishError }
    }
    func claim(_ offer: PairingOffer) async throws -> PairingClaimResult {
        calls.append("claim:\(offer.host)")
        if let claimError { throw claimError }
        return claimResult!
    }
    func acceptRequest(offerID: String) async throws { calls.append("accept:\(offerID)") }
    func revokePairing(host: String, install: String) async throws { calls.append("revoke:\(host)/\(install)") }
    func revokeInstall(_ install: String) async throws { calls.append("revokeInstall:\(install)") }
    func renameInstall(_ install: String, to name: String) async throws { calls.append("rename:\(install)=\(name)") }
}

/// Presence pushed by the test.
final class FakePresence: HostPresenceSource, @unchecked Sendable {
    let stream: AsyncStream<[String: HostPresence]>
    let sink: AsyncStream<[String: HostPresence]>.Continuation
    private let lock = NSLock()
    private var _asked: [[String: String]] = []
    var asked: [[String: String]] { lock.withLock { _asked } }

    init() { (stream, sink) = AsyncStream.makeStream(of: [String: HostPresence].self) }

    func presence(of hosts: [String: String]) async -> AsyncStream<[String: HostPresence]> {
        lock.withLock { _asked.append(hosts) }
        return stream
    }
}
