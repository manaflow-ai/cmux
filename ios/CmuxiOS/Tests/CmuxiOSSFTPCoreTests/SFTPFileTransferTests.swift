import CmuxiOSFeatureKit
@testable import CmuxiOSSFTPCore
import Foundation
import Testing

struct SFTPFileTransferTests {
    let host = HostID("ssh-box")

    private func setUp() async -> (FakeSFTPFileSystem, FakeSFTPOpener, SFTPHostDirectory, SFTPFileTransfer) {
        let system = FakeSFTPFileSystem()
        let opener = FakeSFTPOpener(system: system)
        let directory = SFTPHostDirectory()
        await directory.register(opener, for: host)
        return (system, opener, directory, SFTPFileTransfer(directory: directory))
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("sftp-core-\(UUID().uuidString)")
    }

    private func last(_ stream: AsyncStream<TransferProgress>) async -> TransferProgress? {
        var last: TransferProgress?
        for await progress in stream { last = progress }
        return last
    }

    @Test func downloadFinishesWithTheFile() async throws {
        let (system, _, _, transfer) = await setUp()
        system.put("/home/me/notes.txt", Data("hello".utf8))
        let local = temporaryURL()
        defer { try? FileManager.default.removeItem(at: local) }
        let request = TransferRequest(hostID: host, direction: .download(localURL: local), remotePath: "/home/me/notes.txt")
        let final = await last(try await transfer.start(request))
        #expect(final?.state == .finished)
        #expect(final?.completedBytes == 5)
        #expect(try Data(contentsOf: local) == Data("hello".utf8))
    }

    @Test func uploadGoesToTheDestinationFolder() async throws {
        let (system, _, _, transfer) = await setUp()
        system.addDirectory("/srv/drop")
        let local = temporaryURL()
        try Data("payload".utf8).write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }
        let request = TransferRequest(hostID: host, direction: .upload(localURL: local), destination: .directory("/srv/drop"),
                                      name: "photo.jpg")
        let final = await last(try await transfer.start(request))
        #expect(final?.state == .finished)
        #expect(final?.remotePath == "/srv/drop/photo.jpg")
        #expect(system.file("/srv/drop/photo.jpg") == Data("payload".utf8))
    }

    @Test func uploadWithoutAFolderLandsInTheLoginDirectory() async throws {
        let (system, _, _, transfer) = await setUp()
        let local = temporaryURL()
        try Data("x".utf8).write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }
        let request = TransferRequest(hostID: host, direction: .upload(localURL: local), destination: .composer, name: "x.txt")
        #expect(await last(try await transfer.start(request))?.remotePath == "/home/me/x.txt")
        #expect(system.file("/home/me/x.txt") != nil)
    }

    @Test func droppedSessionPausesAndResumeContinuesFromLocalBytes() async throws {
        let (system, opener, _, transfer) = await setUp()
        let data = Data((0..<1000).map { UInt8($0 % 251) })
        system.put("/home/me/big", data)
        system.dropNextTransfer(after: 400)
        let local = temporaryURL()
        defer { try? FileManager.default.removeItem(at: local) }
        let request = TransferRequest(hostID: host, direction: .download(localURL: local), remotePath: "/home/me/big")
        let paused = await last(try await transfer.start(request))
        #expect(paused?.state == .paused)
        #expect(paused?.completedBytes == 400)
        #expect(await opener.resets == 1)
        let resumed = await last(try await transfer.resume(request.id))
        #expect(resumed?.state == .finished)
        #expect(system.offsets == [0, 400])
        #expect(try Data(contentsOf: local) == data)
    }

    @Test func droppedUploadResumesFromTheRemoteSize() async throws {
        let (system, _, _, transfer) = await setUp()
        let data = Data((0..<900).map { UInt8($0 % 13) })
        let local = temporaryURL()
        try data.write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }
        system.dropNextTransfer(after: 300)
        let request = TransferRequest(hostID: host, direction: .upload(localURL: local), destination: .directory("/home/me"), name: "u")
        #expect(await last(try await transfer.start(request))?.state == .paused)
        #expect(await last(try await transfer.resume(request.id))?.state == .finished)
        #expect(system.offsets == [0, 300])
        #expect(system.file("/home/me/u") == data)
    }

    @Test func missingFileFailsWithANotFoundReason() async throws {
        let (_, _, _, transfer) = await setUp()
        let request = TransferRequest(hostID: host, direction: .download(localURL: temporaryURL()), remotePath: "/nope")
        #expect(await last(try await transfer.start(request))?.state == .failed(reason: "files.not_found"))
    }

    @Test func unregisteredHostFails() async throws {
        let transfer = SFTPFileTransfer(directory: SFTPHostDirectory())
        let request = TransferRequest(hostID: host, direction: .download(localURL: temporaryURL()), remotePath: "/a")
        #expect(await last(try await transfer.start(request))?.state == .failed(reason: "files.unavailable"))
    }

    @Test func historyIsNewestFirstAndFinishedTransfersDoNotResume() async throws {
        let (system, _, _, transfer) = await setUp()
        system.put("/a", Data("a".utf8))
        system.put("/b", Data("b".utf8))
        let first = TransferRequest(hostID: host, direction: .download(localURL: temporaryURL()), remotePath: "/a")
        let second = TransferRequest(hostID: host, direction: .download(localURL: temporaryURL()), remotePath: "/b")
        _ = await last(try await transfer.start(first))
        _ = await last(try await transfer.start(second))
        #expect(await transfer.history().map(\.request.id) == [second.id, first.id])
        await #expect(throws: FeatureSourceError.self) { try await transfer.resume(first.id) }
    }

    @Test func cancellingAPausedTransferEndsIt() async throws {
        let (system, _, _, transfer) = await setUp()
        system.put("/c", Data(count: 100))
        system.dropNextTransfer(after: 10)
        let request = TransferRequest(hostID: host, direction: .download(localURL: temporaryURL()), remotePath: "/c")
        _ = await last(try await transfer.start(request))
        await transfer.cancel(request.id)
        #expect(await transfer.history().first?.progress.state == .cancelled)
    }
}
