import AppKit
import Quartz
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Quick Look retirement")
struct FilePreviewQuickLookRetirementTests {
    private final class ReentrantResponderView: NSView {
        var onResign: (() -> Void)?

        override var acceptsFirstResponder: Bool {
            true
        }

        override func resignFirstResponder() -> Bool {
            onResign?()
            return super.resignFirstResponder()
        }
    }

    @Test
    func retirementInvalidatesCachedPreviewBeforeSynchronousResponderTeardown() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-10728-quicklook-\(UUID().uuidString)")
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: fileURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let panel = FilePreviewPanel(
            workspaceId: UUID(),
            filePath: fileURL.path,
            startFileWatcher: false,
            modeResolver: { _ in .quickLook }
        )
        defer { panel.close() }

        let session = FilePreviewQuickLookSession()
        let container = try #require(session.view(
            panel: panel,
            revision: panel.previewRevision,
            isVisibleInUI: true,
            backgroundColor: .clear,
            drawsBackground: false
        ) as? FilePreviewQuickLookContainerView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer {
            session.dismantle(container)
            window.close()
        }

        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        let previewView = try #require(container.livePreviewView())
        let responder = ReentrantResponderView(
            frame: NSRect(x: 0, y: 0, width: 20, height: 20)
        )
        previewView.addSubview(responder)
        #expect(window.makeFirstResponder(responder))
        #expect(window.firstResponder === responder)

        var resignCount = 0
        var previewDuringRetirement: QLPreviewView?
        responder.onResign = {
            resignCount += 1
            previewDuringRetirement = container.livePreviewView()
        }

        session.dismantle(container)
        responder.onResign = nil

        #expect(
            resignCount > 0,
            "The fixture must observe AppKit's synchronous responder teardown"
        )
        #expect(
            previewDuringRetirement == nil,
            "A retiring or dismantled container must not re-adopt its deactivated child"
        )
        #expect(container.livePreviewView() == nil)
    }
}
