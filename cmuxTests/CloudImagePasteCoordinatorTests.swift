import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Cloud image transfer behavior", .timeLimit(.minutes(1))) @MainActor
struct CloudImagePasteCoordinatorTests {
    private let png = Data([0x89, 0x50, 0x4e, 0x47, 13, 10, 26, 10])

    @Test
    func reconnectDuringFilePreparationCannotRetargetTheImage() async throws {
        let peer = CloudImagePasteTestPeer()
        peer.bind()
        let generation = try peer.coordinator.beginPreparation()
        defer { peer.coordinator.endPreparation() }
        peer.bind()
        await #expect(throws: CloudImagePasteError.unavailable) {
            try await peer.coordinator.paste(CloudClipboardImage(data: png), generation: generation)
        }
        #expect(peer.sent.isEmpty)
    }

    @Test
    func chunksAreAcknowledgedBeforeRemotePaste() async throws {
        let peer = CloudImagePasteTestPeer()
        peer.bind()
        let data = png + Data(repeating: 1, count: CloudImagePasteCoordinator.chunkBytes + 2)
        let task = Task { try await peer.coordinator.paste(CloudClipboardImage(data: data)) }
        var commands = peer.commands.makeAsyncIterator()
        let begin = try #require(await commands.next())
        #expect(begin.operation == "begin")
        #expect(begin.terminalID == "term_test")
        #expect(begin.surfaceID == 17)
        #expect(begin.lease == "lease-test")
        #expect(peer.sent.count == 1)
        peer.acknowledge(begin)
        let firstChunk = try #require(await commands.next())
        #expect(firstChunk.operation == "chunk")
        #expect(firstChunk.offset == 0)
        #expect(firstChunk.bytes.count == CloudImagePasteCoordinator.chunkBytes)
        peer.acknowledge(firstChunk)
        let secondChunk = try #require(await commands.next())
        #expect(secondChunk.offset == firstChunk.bytes.count)
        #expect(firstChunk.bytes + secondChunk.bytes == data)
        #expect(peer.sent.allSatisfy { $0.operation != "commit" })
        peer.acknowledge(secondChunk)
        let commit = try #require(await commands.next())
        #expect(commit.operation == "commit")
        #expect(commit.uploadID == begin.uploadID)
        #expect(peer.sent.allSatisfy { !$0.hasPath })
        peer.acknowledge(commit)
        try await task.value
        #expect(peer.coordinator.transferredBytes == data.count)
    }

    @Test
    func missingAndOldLinksSendNoClipboardBytes() async throws {
        let peer = CloudImagePasteTestPeer()
        let image = try CloudClipboardImage(data: png)
        await #expect(throws: CloudImagePasteError.unavailable) {
            try await peer.coordinator.paste(image)
        }
        peer.bind(capabilities: [])
        await #expect(throws: CloudImagePasteError.unsupported) {
            try await peer.coordinator.paste(image)
        }
        peer.bind(capabilities: [], lease: nil)
        await #expect(throws: CloudImagePasteError.unsupported) {
            try await peer.coordinator.paste(image)
        }
        #expect(peer.sent.isEmpty)
    }

    @Test
    func cancellationAbortsAndDoesNotCommitLateSuccess() async throws {
        let peer = CloudImagePasteTestPeer()
        peer.bind()
        var commands = peer.commands.makeAsyncIterator()
        let task = Task { try await peer.coordinator.paste(CloudClipboardImage(data: png)) }
        let begin = try #require(await commands.next())
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(peer.sent.map(\.operation) == ["begin", "cancel"])
        #expect(!peer.coordinator.receive(requestID: begin.requestID, ok: true, error: nil))
    }

    @Test
    func disconnectBeforeCommitFailsWithoutReplayToReplacement() async throws {
        let peer = CloudImagePasteTestPeer()
        peer.bind()
        var commands = peer.commands.makeAsyncIterator()
        let task = Task { try await peer.coordinator.paste(CloudClipboardImage(data: png)) }
        _ = try #require(await commands.next())
        peer.coordinator.disconnect()
        peer.bind()
        await #expect(throws: CloudImagePasteError.unavailable) { try await task.value }
        #expect(!peer.sent.contains { $0.operation == "commit" || $0.operation == "chunk" })
    }

    @Test
    func lostCommitAcknowledgementIsReportedAsUncertainAndNeverRetried() async throws {
        let peer = CloudImagePasteTestPeer()
        peer.bind()
        var commands = peer.commands.makeAsyncIterator()
        let task = Task { try await peer.coordinator.paste(CloudClipboardImage(data: png)) }
        for operation in ["begin", "chunk"] {
            let command = try #require(await commands.next())
            #expect(command.operation == operation)
            peer.acknowledge(command)
        }
        let commit = try #require(await commands.next())
        #expect(commit.operation == "commit")
        peer.coordinator.disconnect()
        await #expect(throws: CloudImagePasteError.deliveryUncertain) { try await task.value }
        #expect(peer.sent.map(\.operation) == ["begin", "chunk", "commit"])
    }

    @Test
    func refusedUploadsAbortWithAnActionableError() async throws {
        let peer = CloudImagePasteTestPeer()
        peer.bind()
        var commands = peer.commands.makeAsyncIterator()
        let task = Task { try await peer.coordinator.paste(CloudClipboardImage(data: png)) }
        let begin = try #require(await commands.next())
        _ = peer.coordinator.receive(requestID: begin.requestID, ok: false, error: "image-capacity-limit")
        await #expect(throws: CloudImagePasteError.capacity) { try await task.value }
        #expect(peer.sent.map(\.operation) == ["begin", "cancel"])
    }

    @Test
    func deadlineCancelsAnUnresponsivePeer() async throws {
        let peer = CloudImagePasteTestPeer(coordinator: CloudImagePasteCoordinator(deadline: .zero))
        peer.bind()
        await #expect(throws: CloudImagePasteError.timedOut) {
            try await peer.coordinator.paste(CloudClipboardImage(data: png))
        }
        #expect(peer.sent.map(\.operation) == ["begin", "cancel"])
    }

    @Test
    func imageReadRejectsBadTypesOversizeAndSymlinksWithoutDeletingUserFiles() async throws {
        #expect(throws: CloudImagePasteError.unsupportedType) {
            try CloudClipboardImage(data: Data("<svg/>".utf8))
        }
        #expect(throws: CloudImagePasteError.sizeLimit) {
            try CloudClipboardImage(data: Data(repeating: 0, count: CloudClipboardImage.maximumBytes + 1))
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("user-image.png")
        try png.write(to: file)
        let reader = CloudClipboardImageReader()
        #expect(try await reader.read(file).data == png)
        #expect(try Data(contentsOf: file) == png)
        let link = directory.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        await #expect(throws: CloudImagePasteError.storage) { try await reader.read(link) }
        #expect(try Data(contentsOf: file) == png)
    }
}
