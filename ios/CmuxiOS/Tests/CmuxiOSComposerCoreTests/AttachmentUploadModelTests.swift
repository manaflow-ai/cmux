import CmuxiOSComposerCore
import CmuxiOSFeatureKit
import Foundation
import Testing

private actor ScriptedComposerUploader: ComposerAttachmentUploading {
    private var continuations: [URL: AsyncStream<ComposerAttachment>.Continuation] = [:]
    private(set) var requestCount = 0

    func upload(localURL: URL, name: String, mime: String, to host: HostID)
        async -> AsyncStream<ComposerAttachment> {
        requestCount += 1
        return AsyncStream { continuation in
            continuations[localURL] = continuation
        }
    }

    func emit(_ item: ComposerPickedAttachment, _ update: ComposerAttachment, finish: Bool = false) {
        continuations[item.localURL]?.yield(update)
        if finish {
            continuations[item.localURL]?.finish()
            continuations[item.localURL] = nil
        }
    }

    func finish(_ item: ComposerPickedAttachment) {
        continuations[item.localURL]?.finish()
        continuations[item.localURL] = nil
    }
}

@MainActor
@Suite("composer attachment upload model")
struct AttachmentUploadModelTests {
    private let host = HostID("h_studio")

    private func item(_ id: String, bytes: Int64 = 4) -> ComposerPickedAttachment {
        ComposerPickedAttachment(id: TransferID(rawValue: id),
                                 localURL: URL(fileURLWithPath: "/tmp/\(id).bin"),
                                 name: "\(id).bin", mime: "application/octet-stream", byteCount: bytes)
    }

    private func waitForRequests(_ uploader: ScriptedComposerUploader, _ count: Int) async {
        for _ in 0..<1_000 {
            if await uploader.requestCount >= count { return }
            await Task.yield()
        }
    }

    private func waitFor(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
    }

    @Test func eachItemKeepsItsIDAndProgressCannotReplacePickerMetadata() async throws {
        let uploader = ScriptedComposerUploader()
        let model = ComposerAttachmentUploadModel(host: host, uploader: uploader,
                                                   limits: ComposerAttachmentUploadLimits(maximumCount: 4,
                                                                                          maximumBytesPerAttachment: 100,
                                                                                          maximumTotalBytes: 100))
        let picked = item("pick-1", bytes: 7)
        _ = try model.enqueue(picked)
        await waitForRequests(uploader, 1)

        let wrong = ComposerAttachment(id: TransferID(rawValue: "wrong"), name: "wrong", mime: "text/plain",
                                       byteCount: 999, uploadID: "up_good", phase: .ready)
        await uploader.emit(picked, wrong, finish: true)
        await waitFor { model.attachments.first?.phase == .ready }

        let attachment = try #require(model.attachments.first)
        #expect(attachment.id == picked.id)
        #expect(attachment.name == picked.name)
        #expect(attachment.mime == picked.mime)
        #expect(attachment.byteCount == picked.byteCount)
        #expect(attachment.uploadID == "up_good")
    }

    @Test func countPerFileAndAggregateLimitsAreCheckedBeforeStartingWork() async throws {
        let uploader = ScriptedComposerUploader()
        let limits = ComposerAttachmentUploadLimits(maximumCount: 2, maximumBytesPerAttachment: 5,
                                                     maximumTotalBytes: 6)
        let model = ComposerAttachmentUploadModel(host: host, uploader: uploader, limits: limits)

        #expect(throws: ComposerAttachmentAdmissionError.attachmentTooLarge(byteCount: 6, maximum: 5)) {
            try model.enqueue(item("too-large", bytes: 6))
        }
        #expect(model.attachments.isEmpty)
        #expect(await uploader.requestCount == 0)

        try model.enqueue(item("first", bytes: 4))
        #expect(throws: ComposerAttachmentAdmissionError.totalSizeLimit(total: 7, maximum: 6)) {
            try model.enqueue(item("aggregate", bytes: 3))
        }
        try model.enqueue(item("second", bytes: 2))
        #expect(throws: ComposerAttachmentAdmissionError.attachmentCountLimit(maximum: 2)) {
            try model.enqueue(item("third", bytes: 0))
        }
        #expect(model.attachments.map(\.id) == [TransferID(rawValue: "first"), TransferID(rawValue: "second")])
        model.attachments.forEach { model.cancel($0.id) }
    }

    @Test func malformedLimitsClampInsteadOfCrashingTheComposer() {
        let limits = ComposerAttachmentUploadLimits(maximumCount: 0, maximumBytesPerAttachment: -1,
                                                     maximumTotalBytes: -1)
        #expect(limits.maximumCount == 1)
        #expect(limits.maximumBytesPerAttachment == 0)
        #expect(limits.maximumTotalBytes == 0)
    }

    @Test func pickerBatchesAreAtomicAndDuplicateIDsAreRejected() async throws {
        let uploader = ScriptedComposerUploader()
        let model = ComposerAttachmentUploadModel(host: host, uploader: uploader,
                                                   limits: ComposerAttachmentUploadLimits(maximumCount: 4,
                                                                                          maximumBytesPerAttachment: 10,
                                                                                          maximumTotalBytes: 10))
        #expect(throws: ComposerAttachmentAdmissionError.totalSizeLimit(total: 11, maximum: 10)) {
            try model.enqueue([item("a", bytes: 6), item("b", bytes: 5)])
        }
        #expect(model.attachments.isEmpty)
        #expect(await uploader.requestCount == 0)

        try model.enqueue(item("a", bytes: 2))
        #expect(throws: ComposerAttachmentAdmissionError.duplicateID(TransferID(rawValue: "a"))) {
            try model.enqueue(item("a", bytes: 2))
        }
        model.cancel(TransferID(rawValue: "a"))
    }

    @Test func cancellationRemovesTheRowAndIgnoresLateProgress() async throws {
        let uploader = ScriptedComposerUploader()
        let model = ComposerAttachmentUploadModel(host: host, uploader: uploader)
        let picked = item("cancel-me")
        try model.enqueue(picked)
        await waitForRequests(uploader, 1)
        model.cancel(picked.id)

        await uploader.emit(picked, ComposerAttachment(id: picked.id, name: picked.name, mime: picked.mime,
                                                        byteCount: picked.byteCount, uploadID: "up_late",
                                                        phase: .ready), finish: true)
        await Task.yield()
        #expect(model.attachments.isEmpty)
        #expect(model.retry(picked.id) == false)
    }

    @Test func failedUploadCanRetryWithTheSameIDAndBecomeReady() async throws {
        let uploader = ScriptedComposerUploader()
        let model = ComposerAttachmentUploadModel(host: host, uploader: uploader)
        let picked = item("retry-me")
        try model.enqueue(picked)
        await waitForRequests(uploader, 1)
        await uploader.emit(picked, ComposerAttachment(id: TransferID(rawValue: "other"), name: "x", mime: "x",
                                                        byteCount: 1, phase: .failed), finish: true)
        await waitFor { model.attachments.first?.phase == .failed }
        #expect(model.hasPendingUploads == false)
        #expect(model.retry(picked.id))
        await waitForRequests(uploader, 2)
        #expect(model.hasPendingUploads)
        await uploader.emit(picked, ComposerAttachment(id: TransferID(rawValue: "other"), name: "x", mime: "x",
                                                        byteCount: 1, uploadID: "up_retry", phase: .ready), finish: true)
        await waitFor { model.attachments.first?.phase == .ready }

        let result = try #require(model.attachments.first)
        #expect(result.id == picked.id)
        #expect(result.uploadID == "up_retry")
        #expect(model.retry(picked.id) == false)
    }

    @Test func malformedOwnerIDAndAbruptStreamEndFailClosed() async throws {
        let uploader = ScriptedComposerUploader()
        let model = ComposerAttachmentUploadModel(host: host, uploader: uploader)
        let picked = item("bad-id")
        try model.enqueue(picked)
        await waitForRequests(uploader, 1)
        await uploader.emit(picked, ComposerAttachment(id: picked.id, name: picked.name, mime: picked.mime,
                                                        byteCount: picked.byteCount, uploadID: "/tmp/path",
                                                        phase: .ready), finish: true)
        await waitFor { model.attachments.first?.phase == .failed }
        #expect(model.attachments.first?.uploadID == nil)

        let abrupt = item("abrupt")
        try model.enqueue(abrupt)
        await waitForRequests(uploader, 2)
        await uploader.finish(abrupt)
        await waitFor { model.attachments.first(where: { $0.id == abrupt.id })?.phase == .failed }
    }

    @Test func discardedModelDoesNotStayAliveForAnUnfinishedStream() async throws {
        let uploader = ScriptedComposerUploader()
        weak var weakModel: ComposerAttachmentUploadModel?
        do {
            let model = ComposerAttachmentUploadModel(host: host, uploader: uploader)
            weakModel = model
            try model.enqueue(item("dismissed"))
            await waitForRequests(uploader, 1)
            model.cancelAll()
        }
        for _ in 0..<20 {
            if weakModel == nil { return }
            await Task.yield()
        }
        #expect(weakModel == nil)
    }
}
