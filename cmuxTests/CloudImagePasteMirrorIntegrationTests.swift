import CmuxCloudImagePaste
import CmuxCloudTui
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Exercises upload acknowledgements through the real mirror connection and decoder.
@Suite("Cloud image paste through the mirror socket", .timeLimit(.minutes(1)))
@MainActor
struct CloudImagePasteMirrorIntegrationTests {
    private let terminalID = "term_0123456789abcdef0123456789abcdef"
    private let lease = "image-mirror-test-lease"

    @Test(arguments: [true, false])
    func socketResponsesAdvanceTheUploadAndConfirmCommit(accepted: Bool) async throws {
        let fixture = try CloudManualMirrorSocketFixture()
        defer { fixture.close() }
        let session = makeSession()
        defer { session.stop() }
        try await attach(session, to: fixture)
        let data = Data([0x89, 0x50, 0x4e, 0x47, 13, 10, 26, 10])
            + Data(repeating: 7, count: CloudImagePasteCoordinator.chunkBytes + 5)
        let image = try CloudClipboardImage(data: data)
        let upload = Task { try await session.imagePaste.paste(image) }
        defer { upload.cancel() }

        let begin = try await nextImageCommand(from: fixture)
        #expect(begin.imageOperation == "begin")
        acknowledge(begin, through: fixture)
        var received = Data()
        while received.count < data.count {
            let chunk = try await nextImageCommand(from: fixture)
            #expect(chunk.imageOperation == "chunk")
            #expect(chunk.uploadID == begin.uploadID)
            #expect(chunk.offset == received.count)
            let bytes = try #require(chunk.imageBytes)
            try #require(!bytes.isEmpty)
            #expect(bytes.count <= CloudImagePasteCoordinator.chunkBytes)
            received.append(bytes)
            acknowledge(chunk, through: fixture)
        }
        let commit = try await nextImageCommand(from: fixture)
        #expect(commit.imageOperation == "commit")
        #expect(commit.uploadID == begin.uploadID)
        #expect(received == data)
        acknowledge(commit, through: fixture, accepted: accepted)
        if accepted {
            try await upload.value
        } else {
            await #expect(throws: CloudImagePasteError.deliveryUncertain) { try await upload.value }
        }
        #expect(session.phase == .attached)
    }

    @Test
    func socketRejectionCancelsTheUploadWithoutCommitting() async throws {
        let fixture = try CloudManualMirrorSocketFixture()
        defer { fixture.close() }
        let session = makeSession()
        defer { session.stop() }
        try await attach(session, to: fixture)
        let image = try CloudClipboardImage(data: Data([0x89, 0x50, 0x4e, 0x47, 13, 10, 26, 10]))
        let upload = Task { try await session.imagePaste.paste(image) }
        defer { upload.cancel() }
        let begin = try await nextImageCommand(from: fixture)
        fixture.send(["id": begin.id, "ok": false, "error": "image-capacity-limit"])
        let cancel = try await nextImageCommand(from: fixture)
        #expect(cancel.imageOperation == "cancel")
        #expect(cancel.uploadID == begin.uploadID)
        await #expect(throws: CloudImagePasteError.capacity) { try await upload.value }
    }

    private func makeSession() -> CloudTuiManualMirrorSession {
        CloudTuiManualMirrorSession(
            machineID: "image-mirror-test-machine",
            terminalID: terminalID,
            remoteSurfaceID: 17,
            deadlines: CloudTuiManualMirrorDeadlines(
                handshake: .seconds(10), livenessInterval: .milliseconds(50), livenessAnswer: .seconds(10)
            ),
            onNeedsReconnect: {}
        )
    }

    private func attach(_ session: CloudTuiManualMirrorSession, to fixture: CloudManualMirrorSocketFixture) async throws {
        session.reconnect(socketPath: fixture.socketPath)
        let identify = try #require(await fixture.nextCommand(timeout: .seconds(5)))
        #expect(identify.cmd == "identify")
        fixture.send(["id": identify.id, "ok": true, "data": [
            "protocol": 12, "capabilities": ["view-attachment-lease-v1", CloudImagePasteCoordinator.capability]
        ]])
        let clientInfo = try #require(await fixture.nextCommand(timeout: .seconds(5)))
        #expect(clientInfo.cmd == "set-client-info")
        fixture.send(["id": clientInfo.id, "ok": true, "data": [:]])
        let attach = try #require(await fixture.nextCommand(timeout: .seconds(5)))
        #expect(attach.cmd == "attach-surface")
        fixture.send(["id": attach.id, "ok": true, "data": ["lease": lease]])
        // A real liveness probe can only be sent after the attach response was
        // handled. It provides an observable barrier without calling private hooks.
        let ping = try #require(await fixture.nextCommand(timeout: .seconds(5)))
        #expect(ping.cmd == "ping")
        fixture.send(["id": ping.id, "ok": true, "data": [:]])
        try session.imagePaste.requireAvailable()
    }

    private func nextImageCommand(from fixture: CloudManualMirrorSocketFixture) async throws -> CloudManualMirrorFixtureCommand {
        let deadline = ContinuousClock.now + .seconds(5)
        while true {
            let remaining = ContinuousClock.now.duration(to: deadline)
            try #require(remaining > .zero, "No image command arrived before the deadline")
            let command = try #require(await fixture.nextCommand(timeout: remaining))
            if command.cmd == "ping" {
                fixture.send(["id": command.id, "ok": true, "data": [:]])
                continue
            }
            #expect(command.cmd == "paste-image")
            #expect(command.terminalID == terminalID)
            #expect(command.surface == 17)
            #expect(command.lease == lease)
            #expect(!command.hasDestinationPath)
            return command
        }
    }

    private func acknowledge(_ command: CloudManualMirrorFixtureCommand, through fixture: CloudManualMirrorSocketFixture, accepted: Bool = true) {
        fixture.send(["id": command.id, "ok": true, "data": ["accepted": accepted]])
    }
}
