import CmuxiOSFeatureKit
import CmuxiOSFilesCore
import CmuxLink
import CmuxLinkTesting
import CmuxMobileFiles
import CmuxMobileHost
import CmuxMobileLink
import CmuxMobileWire
import CryptoKit
import Foundation
import Testing

/// The real seam end to end: `LinkFileTransfer` + `FileSendCoordinator`
/// against a `MobileHost` with the C4 handlers over a loopback link.
@Suite("LinkFileTransfer over a loopback Mac")
struct LinkFileTransferTests {
    @Test @MainActor func composerReceivesTheVerifiedUploadReferenceAndHistoryPreservesIt() async throws {
        let mac = try await LoopbackMac()
        defer { Task { await mac.stop() } }
        let journal = mac.base.appendingPathComponent("journal.json")
        let transfer = LinkFileTransfer(connector: mac, journalURL: journal)
        let sink = RecordingSink()
        let model = TransferListModel(transfer: transfer)
        let stager = FileStager(root: mac.base.appendingPathComponent("staging"))
        let coordinator = FileSendCoordinator(model: model, paster: nil, attachments: sink, stager: stager)
        let file = try stager.stage(data: Data("task context".utf8), name: "context.txt")
        coordinator.send([file], to: .composer, host: HostID(LoopbackMac.hostID))
        let attachment = try await waitFor { await sink.attachments.first }
        let uploadID = try #require(attachment.uploadID)
        #expect(uploadID.hasPrefix("up_"))
        #expect(uploadID != attachment.remotePath)
        #expect(attachment.byteCount == 12)
        let relaunched = LinkFileTransfer(connector: mac, journalURL: journal)
        #expect(await relaunched.history().first?.progress.uploadID == uploadID)
    }

    @Test @MainActor func sendToTerminalUploadsToTheInboxAndPastesThePath() async throws {
        let mac = try await LoopbackMac()
        defer { Task { await mac.stop() } }
        let journal = mac.base.appendingPathComponent("journal.json")
        let transfer = LinkFileTransfer(connector: mac, journalURL: journal)
        let paster = RecordingPaster()
        let model = TransferListModel(transfer: transfer)
        let stager = FileStager(root: mac.base.appendingPathComponent("staging"))
        let coordinator = FileSendCoordinator(model: model, paster: paster, attachments: nil, stager: stager)
        let data = Data((0..<90_000).map { UInt8(truncatingIfNeeded: $0) })
        let file = try stager.stage(data: data, name: "it's a photo.jpg")
        coordinator.send([file], to: .terminal(id: "term_t1"), host: HostID(LoopbackMac.hostID))
        let pasted = try await waitFor { await paster.pastes.first }
        #expect(pasted.path.hasSuffix("/Downloads/cmux-phone/it's a photo.jpg"))
        #expect(try Data(contentsOf: URL(fileURLWithPath: pasted.path)) == data)
        #expect(ShellQuotedPath(pasted.path).pasteText.hasSuffix("'\\''s a photo.jpg' "))
        // The journal outlives the transfer object: a relaunch lists it as finished.
        let relaunched = LinkFileTransfer(connector: mac, journalURL: journal)
        let history = await relaunched.history()
        #expect(history.first?.progress.state == .finished)
        #expect(history.first?.progress.remotePath == pasted.path)
    }
}

/// A Mac on a loopback network and the connector that dials it.
final class LoopbackMac: FileHostConnector {
    static let hostID = "h_mac1"
    let base: URL
    let network = LoopbackNetwork()
    let host: MobileHost
    let key = P256.Signing.PrivateKey()
    let config = LinkConfiguration(handshakeTimeout: .seconds(2), backoff: Backoff(initial: .milliseconds(2), maximum: .milliseconds(20)),
                                   maxConnectAttempts: 100, resumeWindow: .seconds(30))

    init() async throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("c4l-\(UUID().uuidString)", isDirectory: true)
        let home = base.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let store = StaticTrustStore(devices: [PairedDevice(install: "in_phone", userID: "u1", keyID: "k1",
                                                            publicKey: key.publicKey.x963Representation)])
        let files = MobileFiles(configuration: MobileFilesConfiguration(homeDirectory: home, freeSpaceMarginBytes: 0))
        host = MobileHost(configuration: MobileHostConfiguration(hostID: Self.hostID, accountUserID: "u1"),
                          acceptor: network.acceptor, daemon: EmptyDaemon(),
                          authorizer: TrustStoreAuthorizer(hostID: Self.hostID, accountUserID: "u1", store: store),
                          handlers: files.registering(), linkConfiguration: config)
        linkClient = Self.makeClient(network: network, key: key, config: config)
        await host.start()
    }

    let linkClient: MobileLinkClient

    static func makeClient(network: LoopbackNetwork, key: P256.Signing.PrivateKey, config: LinkConfiguration) -> MobileLinkClient {
        let carrier = network.carrier(kind: .direct, path: .direct)
        return MobileLinkClient(
            hostID: Self.hostID, signer: SoftwareSigner(key: key),
            client: HelloClient(install: "in_phone", platform: "ios", appVersion: "1.0"),
            makeSession: {
                LinkSession(peer: LinkPeer(hostID: LoopbackMac.hostID),
                            selector: PathSelector(carriers: [carrier],
                                                   policy: PathPolicy(preferenceWindow: .milliseconds(5), upgradeRetry: nil)),
                            configuration: config)
            })
    }

    func client(for host: HostID) async throws -> MobileLinkClient {
        linkClient
    }

    func stop() async {
        await host.stop()
        try? FileManager.default.removeItem(at: base)
    }
}

struct SoftwareSigner: MobileDeviceSigner {
    let key: P256.Signing.PrivateKey
    var install: String { "in_phone" }
    var keyID: String { "k1" }

    func sign(_ message: Data) throws -> Data {
        try key.signature(for: message).rawRepresentation
    }
}

struct EmptyDaemon: MobileDaemon {
    func workspaceState() async throws -> MobileWorkspaceState { MobileWorkspaceState(host: LoopbackMac.hostID, workspaces: []) }
    func workspaceChanges() async -> AsyncStream<Void> { AsyncStream { _ in } }
    func perform(_ op: MobileDaemonOp, context: MobileOpContext) async throws -> MobileDaemonOpResult {
        throw MobileDaemonError(code: "proto.unsupported", message: "")
    }
    func attachTerminal(_ request: MobileTerminalAttachRequest) async throws -> any MobileTerminalAttachment {
        throw MobileDaemonError(code: "terminal.not_found", message: "")
    }
}
