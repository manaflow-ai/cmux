import CmuxiOSFeatureKit
@testable import CmuxiOSFilesCore
import CmuxMobileFiles
import CmuxMobileWire
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@Suite("Files core")
struct FilesCoreTests {
    @Test func pathsAreQuotedAsOneShellToken() {
        #expect(ShellQuotedPath("/Users/me/Downloads/cmux-phone/a b.png").pasteText == "'/Users/me/Downloads/cmux-phone/a b.png' ")
        #expect(ShellQuotedPath("/x/it's.txt").token == "'/x/it'\\''s.txt'")
    }

    @Test func requestsMapOntoTheWire() {
        let upload = TransferRequest(hostID: HostID("h_mac1"), direction: .upload(localURL: URL(fileURLWithPath: "/tmp/p.jpg")),
                                     destination: .terminal(id: "term_t1"), mime: "image/jpeg")
        let mapped = LinkFileTransfer.request(upload)
        #expect(mapped.direction == .upload)
        #expect(mapped.dest == FilesUploadDestination(kind: .terminal, terminal: "term_t1"))
        #expect(mapped.name == "p.jpg")
        let directory = TransferRequest(hostID: HostID("h"), direction: .upload(localURL: URL(fileURLWithPath: "/tmp/a")),
                                        destination: .directory("~/src/proj"))
        #expect(LinkFileTransfer.request(directory).dest == FilesUploadDestination(kind: .path, path: "~/src/proj"))
        let download = TransferRequest(hostID: HostID("h"), direction: .download(localURL: URL(fileURLWithPath: "/tmp/b")),
                                       remotePath: "~/src/proj/b")
        #expect(LinkFileTransfer.request(download).dest == nil)
        #expect(LinkFileTransfer.state(.failed(code: "channel.closed", message: "", retryable: true)) == .paused)
        #expect(LinkFileTransfer.state(.failed(code: "files.forbidden", message: "", retryable: false)) == .failed(reason: "files.forbidden"))
    }

    @Test @MainActor func theListFoldsProgressAndNotifiesOnceOnFinish() async throws {
        let model = TransferListModel(transfer: MockFileTransfer())
        let finished = FinishedBox()
        model.onFinished = { finished.append($0.id) }
        let request = TransferRequest(hostID: MockFixtures.studio, direction: .upload(localURL: URL(fileURLWithPath: "/tmp/a.txt")),
                                      byteCount: 800)
        model.start(request)
        #expect(model.items.first?.isRunning == true)
        try await waitUntil { model.items.first?.progress.state == .finished }
        #expect(model.items.first?.progress.completedBytes == 800)
        #expect(model.items.first?.progress.remotePath == "/Users/mock/Downloads/cmux-phone/a.txt")
        #expect(finished.ids == [request.id])
        #expect(!model.hasRunning)
        model.remove(request.id)
        #expect(model.items.isEmpty)
    }

    @Test @MainActor func aFailedMockTransferResumes() async throws {
        let model = TransferListModel(transfer: MockFileTransfer(failAfterChunks: 3))
        let request = TransferRequest(hostID: MockFixtures.studio, direction: .download(localURL: URL(fileURLWithPath: "/tmp/b")),
                                      remotePath: "~/b", byteCount: 800)
        model.start(request)
        try await waitUntil { model.items.first?.canResume == true }
        #expect(model.items.first?.progress.completedBytes == 300)
        model.resume(request.id)
        try await waitUntil { model.items.first?.progress.state == .finished }
    }

    @Test @MainActor func cancellingAStoppedTransferMarksItAndDropsTheStagedCopy() async throws {
        let stager = FileStager(root: FileManager.default.temporaryDirectory.appendingPathComponent("c4c-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: stager.root) }
        let model = TransferListModel(transfer: MockFileTransfer(failAfterChunks: 2))
        let coordinator = FileSendCoordinator(model: model, paster: nil, attachments: nil, stager: stager)
        let file = try stager.stage(data: Data(repeating: 1, count: 800), name: "big.bin")
        let id = try #require(coordinator.send([file], to: .inbox, host: MockFixtures.studio).first)
        try await waitUntil { model.items.first?.canResume == true }
        model.cancel(id)
        try await waitUntil { model.items.first?.progress.state == .cancelled }
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
    }

    @Test @MainActor func sendingToATerminalPastesTheMacPathAndComposerGetsAnAttachment() async throws {
        let stager = FileStager(root: FileManager.default.temporaryDirectory.appendingPathComponent("c4s-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: stager.root) }
        let paster = RecordingPaster()
        let sink = RecordingSink()
        let model = TransferListModel(transfer: MockFileTransfer())
        let coordinator = FileSendCoordinator(model: model, paster: paster, attachments: sink, stager: stager)
        let file = try stager.stage(data: Data("hello".utf8), name: "note.txt")
        #expect(file.mime == "text/plain")
        coordinator.send([file], to: .terminal(id: "term_t1"), host: MockFixtures.studio)
        let pasted = try await waitFor { await paster.pastes.first }
        #expect(pasted.path == "/Users/mock/Downloads/cmux-phone/note.txt")
        #expect(pasted.terminal == "term_t1")
        #expect(!FileManager.default.fileExists(atPath: file.url.path), "the staged copy is discarded")
        let second = try stager.stage(data: Data("img".utf8), name: "shot.png")
        let ids = coordinator.send([second], to: .composer, host: MockFixtures.studio)
        let attachment = try await waitFor { await sink.attachments.first }
        #expect(attachment.id == ids.first)
        #expect(attachment.name == "shot.png")
        #expect(attachment.remotePath.hasSuffix("/shot.png"))
    }

    @Test func heicIsReencodedAsJPEGWhenAsked() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("c4h-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let heic = dir.appendingPathComponent("IMG_0001.HEIC")
        guard Self.writeImage(to: heic, type: .heic) else { return } // no HEIC encoder on this machine
        let stager = FileStager(root: dir.appendingPathComponent("staging"))
        let converted = try stager.stage(copying: heic, convertHEIC: true)
        #expect(converted.name == "IMG_0001.jpg")
        #expect(converted.mime == "image/jpeg")
        let kept = try stager.stage(copying: heic, convertHEIC: false)
        #expect(kept.name == "IMG_0001.HEIC")
    }

    static func writeImage(to url: URL, type: UTType) -> Bool {
        let width = 8, height = 8
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
}

final class FinishedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TransferID] = []
    func append(_ id: TransferID) { lock.withLock { values.append(id) } }
    var ids: [TransferID] { lock.withLock { values } }
}

actor RecordingPaster: TerminalPathPaster {
    private(set) var pastes: [(path: String, terminal: String?)] = []
    func paste(path: String, terminal: String?, host: HostID) async {
        pastes.append((path, terminal))
    }
}

actor RecordingSink: FileAttachmentSink {
    private(set) var attachments: [FileAttachment] = []
    func attach(_ attachment: FileAttachment) async {
        attachments.append(attachment)
    }
}

/// Waits up to 10 s for a condition checked on the main actor.
@MainActor
func waitUntil(_ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    Issue.record("condition not met")
    throw CancellationError()
}

func waitFor<T: Sendable>(_ value: @Sendable () async -> T?) async throws -> T {
    let deadline = ContinuousClock.now + .seconds(10)
    while ContinuousClock.now < deadline {
        if let found = await value() { return found }
        try await Task.sleep(for: .milliseconds(2))
    }
    Issue.record("value never arrived")
    throw CancellationError()
}
