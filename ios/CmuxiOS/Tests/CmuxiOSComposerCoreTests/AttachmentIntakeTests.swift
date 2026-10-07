import CmuxiOSComposerCore
import CmuxiOSFeatureKit
import Foundation
import Testing

extension SessionTests {
    private func file(_ index: Int = 0, upload: String? = "up_verified", host: HostID = MockFixtures.studio) -> FileAttachment {
        FileAttachment(id: TransferID(rawValue: "transfer-\(index)"), hostID: host,
                       remotePath: "/inbox/file.txt", name: "file.txt", mime: "text/plain", byteCount: 12, uploadID: upload)
    }

    @Test func attachmentIntakeUsesTheOwnerReferenceAndPersistsIt() async throws {
        let defaults = defaults()
        let session = await session(ScriptedSink(), defaults: defaults)
        defer { session.stop() }
        let intake = try #require(session.attachmentSink())
        await intake.attach(file())
        #expect(session.draft?.attachments.first?.phase == .ready)
        #expect(session.draft?.taskDraft()?.uploads == ["up_verified"])
        let saved = ComposerDraftStore(defaults: defaults).latest
        #expect(saved?.attachments.first?.uploadID == "up_verified")
    }

    @Test func attachmentIntakeRejectsPathsMissingIDsAndForeignHosts() async throws {
        let session = await session(ScriptedSink())
        defer { session.stop() }
        let intake = try #require(session.attachmentSink())
        await intake.attach(file(upload: nil))
        await intake.attach(file(upload: "/inbox/file.txt"))
        await intake.attach(file(upload: "up_../file"))
        await intake.attach(file(host: HostID("another-mac")))
        #expect(session.draft?.attachments.isEmpty == true)
    }

    @Test func attachmentIntakeIsBoundedButRepeatedDeliveryDoesNotUseAnotherSlot() async throws {
        let session = await session(ScriptedSink())
        defer { session.stop() }
        let intake = try #require(session.attachmentSink())
        for index in 0..<40 { await intake.attach(file(index, upload: "up_id\(index)")) }
        #expect(session.draft?.attachments.count == 32)
        await intake.attach(file(0, upload: "up_updated"))
        #expect(session.draft?.attachments.count == 32)
        #expect(session.draft?.attachments.first?.uploadID == "up_updated")
    }

    @Test func aTargetSwitchInvalidatesTheOldIntakeEvenAfterReturning() async throws {
        let session = await session(ScriptedSink())
        defer { session.stop() }
        let target = try #require(session.draft?.target)
        let intake = try #require(session.attachmentSink())
        session.setTarget(ComposerTarget(hostID: target.hostID, workspaceID: "ws_studio1"))
        await intake.attach(file())
        #expect(session.draft?.attachments.isEmpty == true)
        session.setTarget(target)
        await intake.attach(file())
        #expect(session.draft?.attachments.isEmpty == true)
    }

    @Test func anUnknownSendOrSuccessfulSendCannotReceiveLateAttachments() async throws {
        let source = ScriptedSink()
        let session = await session(source)
        defer { session.stop() }
        let intake = try #require(session.attachmentSink())
        session.updatePrompt("go")
        source.script(.failure(.offline))
        await session.send()
        await intake.attach(file())
        #expect(session.draft?.attachments.isEmpty == true)
        await session.send()
        await intake.attach(file())
        #expect(session.draft?.attachments.isEmpty == true)
    }
}
