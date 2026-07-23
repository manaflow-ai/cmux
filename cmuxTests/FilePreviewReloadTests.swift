import AppKit
import Combine
import Foundation
import PDFKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("File preview reloads")
struct FilePreviewReloadTests {
    @Test("A text preview reloads after its file changes on disk")
    func textPreviewReloadsAfterFileChange() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appending(path: "cmux-file-preview-reload-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let fileURL = directoryURL.appending(path: "live.txt")
        let originalContent = "before\n"
        let updatedContent = "after\n"
        try originalContent.write(to: fileURL, atomically: true, encoding: .utf8)

        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: fileURL.path)
        defer { panel.close() }
        await panel.loadTextContent().value
        #expect(panel.textContent == originalContent)

        let (contentChanges, continuation) = AsyncStream.makeStream(of: String.self)
        let observation = panel.$textContent.sink { continuation.yield($0) }
        defer {
            observation.cancel()
            continuation.finish()
        }

        try updatedContent.write(to: fileURL, atomically: true, encoding: .utf8)

        #expect(await firstMatch(updatedContent, in: contentChanges))
        #expect(panel.textContent == updatedContent)
        #expect(!panel.isDirty)
    }

    @Test("Observed sibling changes do not reload a file preview")
    func observedSiblingChangeDoesNotReloadPreview() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appending(path: "cmux-file-preview-state-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let fileURL = directoryURL.appending(path: "preview.bin")
        let siblingURL = directoryURL.appending(path: "sibling.bin")
        try Data([0x00]).write(to: fileURL)
        let panel = FilePreviewPanel(
            workspaceId: UUID(),
            filePath: fileURL.path,
            startFileWatcher: false
        )
        defer { panel.close() }
        let initialRevision = panel.previewRevision

        try Data([0x01]).write(to: siblingURL)
        #expect(panel.handleObservedFileChange() == nil)
        #expect(panel.previewRevision == initialRevision)

        try Data([0x02, 0x03]).write(to: fileURL)
        let reloadTask = try #require(panel.handleObservedFileChange())
        await reloadTask.value
        #expect(panel.previewRevision == initialRevision + 1)
    }

    @Test("The manual refresh path reloads a text preview")
    func manualRefreshReloadsTextPreview() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "cmux-file-preview-manual-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try "before\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let panel = FilePreviewPanel(
            workspaceId: UUID(),
            filePath: fileURL.path,
            startFileWatcher: false
        )
        defer { panel.close() }
        await panel.loadTextContent().value

        try "after\n".write(to: fileURL, atomically: true, encoding: .utf8)
        await panel.reloadFromDisk().value

        #expect(panel.textContent == "after\n")
        #expect(!panel.isDirty)
    }

    @Test("Refreshing a dirty text preview preserves unsaved edits")
    func manualRefreshPreservesDirtyText() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "cmux-file-preview-dirty-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try "on disk\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let panel = FilePreviewPanel(
            workspaceId: UUID(),
            filePath: fileURL.path,
            startFileWatcher: false
        )
        defer { panel.close() }
        await panel.loadTextContent().value
        panel.updateTextContent("unsaved edits\n")

        try "changed on disk\n".write(to: fileURL, atomically: true, encoding: .utf8)
        await panel.reloadFromDisk().value

        #expect(panel.textContent == "unsaved edits\n")
        #expect(panel.isDirty)
    }

    @Test("Rapid text reloads run only the active and latest request")
    func rapidTextReloadsConflatePendingWork() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "cmux-file-preview-conflated-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try "placeholder\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let loader = ControlledFilePreviewTextLoader()
        let panel = FilePreviewPanel(
            workspaceId: UUID(),
            filePath: fileURL.path,
            startFileWatcher: false,
            textLoader: { _ in await loader.load() }
        )
        defer { panel.close() }
        await loader.waitForFirstStart()

        let superseded = panel.loadTextContent()
        let latest = panel.loadTextContent()
        await loader.releaseAll()
        await superseded.value
        await latest.value

        #expect(await loader.count == 2)
        #expect(panel.textContent == "load 2")
    }

    @Test("Saving a text preview does not route its own write through file-change reload")
    func saveUpdatesObservedFileState() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "cmux-file-preview-save-state-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try "before\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let panel = FilePreviewPanel(
            workspaceId: UUID(),
            filePath: fileURL.path,
            startFileWatcher: false
        )
        defer { panel.close() }
        await panel.loadTextContent().value
        panel.updateTextContent("after with a different size\n")

        let save = try #require(panel.saveTextContent())
        await save.value

        #expect(panel.handleObservedFileChange() == nil)
    }

    @Test("The manual refresh path replaces a cached Quick Look item")
    func manualRefreshReplacesQuickLookItem() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "cmux-file-preview-manual-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try Data([0x00, 0x01]).write(to: fileURL)

        let panel = FilePreviewPanel(
            workspaceId: UUID(),
            filePath: fileURL.path,
            startFileWatcher: false
        )
        defer { panel.close() }
        #expect(panel.previewMode == .quickLook)

        let view = panel.nativeViewSessions.quickLook.view(
            panel: panel,
            isVisibleInUI: true,
            backgroundColor: .textBackgroundColor,
            drawsBackground: true
        )
        let container = try #require(view as? FilePreviewQuickLookContainerView)
        let firstItem = try #require(container.livePreviewView()?.previewItem as AnyObject?)

        try Data([0x02, 0x03]).write(to: fileURL)
        await panel.reloadFromDisk().value
        panel.nativeViewSessions.quickLook.update(
            view,
            panel: panel,
            isVisibleInUI: true,
            backgroundColor: .textBackgroundColor,
            drawsBackground: true
        )

        let refreshedItem = try #require(container.livePreviewView()?.previewItem as AnyObject?)
        #expect(refreshedItem !== firstItem)
    }

    @Test("Markdown manual refresh rereads the file")
    func markdownManualRefreshRereadsFile() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "cmux-markdown-manual-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try "# Before\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let panel = MarkdownPanel(workspaceId: UUID(), filePath: fileURL.path)
        defer { panel.close() }
        try "# After\n".write(to: fileURL, atomically: true, encoding: .utf8)

        panel.reloadFromDisk()

        #expect(panel.content == "# After\n")
        #expect(!panel.isDirty)
    }

    @Test("A PDF reload preserves user-applied page rotation")
    func pdfReloadPreservesUserRotations() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "cmux-file-preview-pdf-rotation-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let sourceDocument = PDFDocument()
        let sourcePage = try #require(PDFPage(image: NSImage(size: NSSize(width: 100, height: 100))))
        sourceDocument.insert(sourcePage, at: 0)
        #expect(sourceDocument.write(to: fileURL))

        let panel = FilePreviewPanel(
            workspaceId: UUID(),
            filePath: fileURL.path,
            startFileWatcher: false
        )
        defer { panel.close() }
        let container = FilePreviewPDFContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        defer { container.close() }
        container.setPanel(panel)
        let pdfView = try #require(Mirror(reflecting: container).descendant("pdfView") as? PDFView)

        await waitForPDFDocumentReplacement(in: pdfView, replacing: nil) {
            container.setURL(fileURL, revision: 0)
        }
        let originalDocument = try #require(pdfView.document)
        let originalPage = try #require(originalDocument.page(at: 0))
        let rotateRight = NSSelectorFromString("rotateRight")
        #expect(container.responds(to: rotateRight))
        _ = container.perform(rotateRight)
        #expect(originalPage.rotation == 90)
        let manualScale: CGFloat = 1.75
        pdfView.autoScales = false
        pdfView.scaleFactor = manualScale

        await waitForPDFDocumentReplacement(in: pdfView, replacing: originalDocument) {
            container.setURL(fileURL, revision: 1)
        }

        #expect(pdfView.document?.page(at: 0)?.rotation == 90)
        #expect(!pdfView.autoScales)
        #expect(abs(pdfView.scaleFactor - manualScale) < 0.001)
    }

    @Test("Latest preview load state keeps one active and one latest pending request")
    func latestPreviewLoadStateConflatesPendingRequests() throws {
        var state = FilePreviewLatestRequestState<String>()
        let active = try #require(state.submit("active").start)

        #expect(state.submit("superseded").start == nil)
        let replacement = state.submit("latest")
        #expect(replacement.start == nil)
        #expect(replacement.superseded?.request == "superseded")
        let activeCompletion = state.complete(id: active.id)

        #expect(!activeCompletion.shouldDeliver)
        let pending = try #require(activeCompletion.next)
        #expect(pending.request == "latest")
        let latestCompletion = state.complete(id: pending.id)
        #expect(latestCompletion.shouldDeliver)
        #expect(latestCompletion.next == nil)
    }

    @Test("Canceling preview load state drops pending work and suppresses active delivery")
    func latestPreviewLoadStateCancelsPendingRequests() throws {
        var state = FilePreviewLatestRequestState<String>()
        let active = try #require(state.submit("active").start)
        #expect(state.submit("pending").start == nil)

        let cancellation = state.cancel()
        #expect(cancellation.active?.request == "active")
        #expect(cancellation.pending?.request == "pending")
        let completion = state.complete(id: active.id)

        #expect(!completion.shouldDeliver)
        #expect(completion.next == nil)
    }

    private func waitForPDFDocumentReplacement(
        in pdfView: PDFView,
        replacing previousDocument: PDFDocument?,
        perform action: () -> Void
    ) async {
        let notifications = NotificationCenter.default.notifications(
            named: Notification.Name.PDFViewDocumentChanged,
            object: pdfView
        )
        action()
        if let document = pdfView.document, document !== previousDocument { return }
        for await _ in notifications {
            if let document = pdfView.document, document !== previousDocument { return }
        }
    }

    private func firstMatch(_ expected: String, in changes: AsyncStream<String>) async -> Bool {
        for await content in changes where content == expected {
            return true
        }
        return false
    }
}

private actor ControlledFilePreviewTextLoader {
    private(set) var count = 0
    private var isReleased = false
    private var firstStartContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

    func load() async -> FilePreviewTextLoader.Result {
        count += 1
        let invocation = count
        if invocation == 1 {
            firstStartContinuation?.resume()
            firstStartContinuation = nil
        }
        if !isReleased {
            await withCheckedContinuation { continuation in
                releaseContinuations.append(continuation)
            }
        }
        return .loaded(content: "load \(invocation)", encoding: .utf8)
    }

    func waitForFirstStart() async {
        guard count == 0 else { return }
        await withCheckedContinuation { continuation in
            firstStartContinuation = continuation
        }
    }

    func releaseAll() {
        isReleased = true
        let continuations = releaseContinuations
        releaseContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}
