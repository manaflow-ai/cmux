import CmuxiOSFeatureKit
public import Foundation
public import Observation

/// One terminal's composer (client view state): the draft, its attachment
/// chips, history walking and what Send produces. The draft is mirrored
/// into `TerminalComposeStore` on every edit and written by `flush()`.
@MainActor
@Observable
public final class TerminalComposerModel {
    public let key: TerminalDraftKey
    public private(set) var text: String
    public private(set) var uploads: [ComposerUpload] = []
    /// Where uploaded paths go: the caret's UTF-16 offset (the view sets it).
    @ObservationIgnored public var caret: @MainActor () -> Int = { Int.max }
    /// The model changed the text itself (path landed, history step): the
    /// view replaces its text and, when given, moves the caret there.
    @ObservationIgnored public var onTextReplaced: (@MainActor (String, Int?) -> Void)?
    @ObservationIgnored private let store: TerminalComposeStore
    @ObservationIgnored private let uploader: (any TerminalComposerUploading)?
    /// History position while walking (index into `store.history`).
    @ObservationIgnored private var historyIndex: Int?
    /// The text before walking started, restored past the newest entry.
    @ObservationIgnored private var historyStash = ""

    public init(key: TerminalDraftKey, store: TerminalComposeStore, uploader: (any TerminalComposerUploading)?) {
        self.key = key
        self.store = store
        self.uploader = uploader
        text = store.draft(for: key)
    }

    public var canAttach: Bool { uploader != nil }
    public var isUploading: Bool { uploads.contains { $0.phase == .uploading } }
    /// Something to send and no upload still running (its path is not in the text yet).
    public var canSend: Bool { !isUploading && ComposerSubmission(draft: text) != nil }
    public var history: [String] { store.history }

    /// The user edited the text.
    public func edit(_ newText: String) {
        guard newText != text else { return }
        text = newText
        historyIndex = nil
        store.setDraft(newText, for: key)
    }

    /// What Send (or Insert Without Sending) hands the terminal; nil while
    /// nothing can be sent.
    public func submission(submits: Bool = true) -> ComposerSubmission? {
        guard !isUploading else { return nil }
        return ComposerSubmission(draft: text, submits: submits)
    }

    /// The terminal took `submission`: record it, clear the draft, write.
    public func didSend(_ submission: ComposerSubmission) {
        store.recordSent(submission.text)
        store.clearDraft(for: key)
        store.flush()
        text = ""
        historyIndex = nil
        historyStash = ""
        uploads.removeAll { $0.phase == .failed }
        onTextReplaced?("", 0)
    }

    public func flush() { store.flush() }

    // MARK: History

    /// One step back in the sent prompts; false at the oldest.
    @discardableResult
    public func historyOlder() -> Bool {
        let entries = store.history
        guard !entries.isEmpty else { return false }
        let next: Int
        if let index = historyIndex {
            guard index > 0 else { return false }
            next = index - 1
        } else {
            historyStash = text
            next = entries.count - 1
        }
        historyIndex = next
        replace(with: entries[next])
        return true
    }

    /// One step forward; past the newest the text before walking returns.
    @discardableResult
    public func historyNewer() -> Bool {
        guard let index = historyIndex else { return false }
        let entries = store.history
        if index + 1 < entries.count {
            historyIndex = index + 1
            replace(with: entries[index + 1])
        } else {
            historyIndex = nil
            replace(with: historyStash)
        }
        return true
    }

    /// Picks an entry from the history menu.
    public func useHistory(_ entry: String) {
        historyIndex = nil
        replace(with: entry)
    }

    private func replace(with newText: String) {
        text = newText
        store.setDraft(newText, for: key)
        onTextReplaced?(newText, newText.utf16.count)
    }

    // MARK: Attachments

    /// Uploads each file; its quoted path is inserted at the caret when it lands.
    public func attach(_ files: [ComposerUploadFile]) {
        guard let uploader else { return }
        for file in files {
            let upload = ComposerUpload(name: file.name, isImage: file.isImage)
            uploads.append(upload)
            let host = key.host
            Task { [weak self] in
                let path = await uploader.upload(file, to: host)
                self?.finish(upload.id, path: path)
            }
        }
    }

    public func removeUpload(_ id: UUID) {
        uploads.removeAll { $0.id == id && $0.phase == .failed }
    }

    func finish(_ id: UUID, path: String?) {
        guard let index = uploads.firstIndex(where: { $0.id == id }) else { return }
        guard let path else {
            uploads[index].phase = .failed
            return
        }
        uploads.remove(at: index)
        let inserted = ComposerPathInsertion(path: path).inserting(into: text, atUTF16Offset: caret())
        text = inserted.text
        historyIndex = nil
        store.setDraft(inserted.text, for: key)
        onTextReplaced?(inserted.text, inserted.caret)
    }
}
