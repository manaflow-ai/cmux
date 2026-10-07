import CmuxiOSFeatureKit
import CmuxiOSTerminalComposeCore
import Foundation
import Testing

@MainActor
@Suite struct TerminalComposerModelTests {
    let key = TerminalDraftKey(host: HostID("host_mac"), terminal: "term_1")

    /// Answers each upload when the test resolves it.
    @MainActor
    final class ScriptedUploader: TerminalComposerUploading {
        var requests: [(ComposerUploadFile, HostID, CheckedContinuation<String?, Never>)] = []
        var onRequest: (() -> Void)?

        func upload(_ file: ComposerUploadFile, to host: HostID) async -> String? {
            await withCheckedContinuation { continuation in
                requests.append((file, host, continuation))
                onRequest?()
            }
        }

        func waitForRequests(_ count: Int) async {
            while requests.count < count {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    onRequest = { continuation.resume() }
                }
                onRequest = nil
            }
        }
    }

    func file(_ name: String, mime: String = "image/png") -> ComposerUploadFile {
        ComposerUploadFile(url: URL(fileURLWithPath: "/tmp/\(name)"), name: name, mime: mime, byteCount: 10)
    }

    @Test func restoresDraftAndMirrorsEdits() {
        let store = TerminalComposeStore(persistence: MemoryTerminalComposePersistence())
        store.setDraft("half typed", for: key)
        let model = TerminalComposerModel(key: key, store: store, uploader: nil)
        #expect(model.text == "half typed")
        model.edit("half typed prompt")
        #expect(store.draft(for: key) == "half typed prompt")
        #expect(!model.canAttach)
    }

    @Test func sendClearsDraftAndRecordsHistory() throws {
        let persistence = MemoryTerminalComposePersistence()
        let store = TerminalComposeStore(persistence: persistence)
        let model = TerminalComposerModel(key: key, store: store, uploader: nil)
        var replaced: [String] = []
        model.onTextReplaced = { text, _ in replaced.append(text) }
        model.edit("fix the build\r\n")
        #expect(model.canSend)
        let submission = try #require(model.submission())
        #expect(submission.text == "fix the build")
        model.didSend(submission)
        #expect(model.text == "")
        #expect(store.draft(for: key) == "")
        #expect(store.history == ["fix the build"])
        #expect(replaced == [""])
        // The send was flushed: a new store reads the history, not the draft.
        let reloaded = TerminalComposeStore(persistence: persistence)
        #expect(reloaded.history == ["fix the build"])
        #expect(reloaded.draft(for: key) == "")
    }

    @Test func emptyDraftCannotSend() {
        let model = TerminalComposerModel(key: key, store: TerminalComposeStore(persistence: MemoryTerminalComposePersistence()),
                                          uploader: nil)
        model.edit("   ")
        #expect(!model.canSend)
        #expect(model.submission() == nil)
    }

    @Test func historyWalkKeepsTheTextInProgress() {
        let store = TerminalComposeStore(persistence: MemoryTerminalComposePersistence())
        store.recordSent("first")
        store.recordSent("second")
        let model = TerminalComposerModel(key: key, store: store, uploader: nil)
        model.edit("typing")
        #expect(model.historyOlder())
        #expect(model.text == "second")
        #expect(model.historyOlder())
        #expect(model.text == "first")
        #expect(!model.historyOlder())
        #expect(model.historyNewer())
        #expect(model.text == "second")
        #expect(model.historyNewer())
        #expect(model.text == "typing")
        #expect(!model.historyNewer())
    }

    @Test func uploadedPathLandsAtTheCaretAndBlocksSendMeanwhile() async throws {
        let store = TerminalComposeStore(persistence: MemoryTerminalComposePersistence())
        let uploader = ScriptedUploader()
        let model = TerminalComposerModel(key: key, store: store, uploader: uploader)
        model.edit("look at this")
        model.caret = { 4 }
        var caretAfter: Int?
        model.onTextReplaced = { _, caret in caretAfter = caret }
        model.attach([file("shot 1.png")])
        #expect(model.uploads.count == 1)
        #expect(model.isUploading)
        #expect(!model.canSend)
        await uploader.waitForRequests(1)
        #expect(uploader.requests[0].1 == key.host)
        uploader.requests[0].2.resume(returning: "/Users/me/Downloads/cmux-phone/shot 1.png")
        while model.isUploading { await Task.yield() }
        #expect(model.uploads.isEmpty)
        #expect(model.text == "look '/Users/me/Downloads/cmux-phone/shot 1.png' at this")
        #expect(store.draft(for: key) == model.text)
        #expect(caretAfter == 49)
        #expect(model.canSend)
    }

    @Test func failedUploadLeavesARemovableChip() async {
        let uploader = ScriptedUploader()
        let model = TerminalComposerModel(key: key, store: TerminalComposeStore(persistence: MemoryTerminalComposePersistence()),
                                          uploader: uploader)
        model.attach([file("notes.txt", mime: "text/plain")])
        await uploader.waitForRequests(1)
        uploader.requests[0].2.resume(returning: nil)
        while model.isUploading { await Task.yield() }
        #expect(model.uploads.count == 1)
        #expect(model.uploads[0].phase == .failed)
        #expect(!model.uploads[0].isImage)
        #expect(model.text == "")
        model.removeUpload(model.uploads[0].id)
        #expect(model.uploads.isEmpty)
    }
}
