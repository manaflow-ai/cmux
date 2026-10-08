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
    private final class ReentrantWindowView: NSView {
        var onWindowTransition: (() -> Void)?

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil {
                onWindowTransition?()
            }
            super.viewWillMove(toWindow: newWindow)
        }
    }

    @Test
    func retirementInvalidatesCachedPreviewBeforeSynchronousWindowTeardown() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-2vc3-quicklook-\(UUID().uuidString)")
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
        let nextWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        nextWindow.isReleasedWhenClosed = false
        defer {
            session.dismantle(container)
            window.close()
            nextWindow.close()
        }

        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        let previewView = try #require(container.livePreviewView())
        let reentrantView = ReentrantWindowView(
            frame: NSRect(x: 0, y: 0, width: 20, height: 20)
        )
        previewView.addSubview(reentrantView)

        var transitionCount = 0
        var previewDuringRetirement: QLPreviewView?
        reentrantView.onWindowTransition = {
            transitionCount += 1
            previewDuringRetirement = container.livePreviewView()
        }

        // Keep the root registered while moving it between windows. The
        // window-transition path must invalidate the child before AppKit's
        // synchronous descendant callbacks can ask for it again.
        window.contentView = nil
        nextWindow.contentView = container
        nextWindow.makeKeyAndOrderFront(nil)
        let replacementPreview = try #require(container.livePreviewView())
        #expect(replacementPreview !== previewView)

        session.dismantle(container)
        reentrantView.onWindowTransition = nil

        #expect(
            transitionCount > 0,
            "The fixture must observe AppKit's synchronous window teardown"
        )
        #expect(
            previewDuringRetirement == nil,
            "A retiring or dismantled container must not re-adopt its deactivated child"
        )
        #expect(container.livePreviewView() == nil)
    }
}
