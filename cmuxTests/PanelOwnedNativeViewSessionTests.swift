import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private extension FilePreviewQuickLookContainerView {
    /// Reproduces the AppKit state where the stable host stays mounted while
    /// QuickLook loses its inner preview without recording a window detach.
    func replaceLivePreviewWithUnattachedPreview() -> QLPreviewView? {
        let item = previewView?.previewItem
        previewView?.previewItem = nil
        previewView?.removeFromSuperview()

        guard let unattached = TrackedQLPreviewView(frame: bounds, style: .normal) else {
            return nil
        }
        unattached.previewItem = item
        previewView = unattached
        return unattached
    }
}

@MainActor
@Suite("Panel-owned native view sessions")
struct PanelOwnedNativeViewSessionTests {
    private final class ProbeView: NSView {
        var isClosed = false
        var configureCount = 0
    }

    @Test
    func updateAfterCloseDoesNotReAdoptClosedNativeView() {
        var makeCount = 0
        let session = PanelOwnedNativeViewSession<ProbeView>(
            makeView: {
                makeCount += 1
                return ProbeView(frame: .zero)
            },
            closeView: { view in
                view.isClosed = true
                view.removeFromSuperview()
            }
        )

        let initialView = session.view { view in
            #expect(!view.isClosed)
            view.configureCount += 1
        }

        #expect(makeCount == 1)
        #expect(initialView.configureCount == 1)

        session.close()

        #expect(initialView.isClosed)

        session.update(initialView) { view in
            Issue.record("Closed native views must not be re-adopted or configured after the panel session closes")
            view.configureCount += 1
        }

        #expect(initialView.configureCount == 1)

        let replacementView = session.view { view in
            #expect(!view.isClosed)
            view.configureCount += 1
        }

        #expect(replacementView !== initialView)
        #expect(replacementView.configureCount == 1)
        #expect(makeCount == 2)
    }

    @Test
    func quickLookSessionCreatesFreshViewForEachRepresentableMount() throws {
        let fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cmux-4455-quicklook-\(UUID().uuidString).bin")
        try Data([0, 1, 2, 3]).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let panel = FilePreviewPanel(workspaceId: UUID(), filePath: fileURL.path)
        let session = FilePreviewQuickLookSession()

        let firstView = session.view(
            panel: panel,
            revision: panel.previewRevision,
            isVisibleInUI: true,
            backgroundColor: .clear,
            drawsBackground: false
        )
        let remountedView = session.view(
            panel: panel,
            revision: panel.previewRevision,
            isVisibleInUI: true,
            backgroundColor: .clear,
            drawsBackground: false
        )

        #expect(
            firstView !== remountedView,
            "QuickLook views must be owned by the SwiftUI representable mount, because AppKit can deactivate a QLPreviewView when that mount is removed"
        )

        session.dismantle(firstView)
        session.dismantle(remountedView)
        panel.close()
    }

    @Test
    func quickLookUpdateRetiresPreviewDeactivatedByWindowLoss() throws {
        let firstURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cmux-7311-detach-a-\(UUID().uuidString).txt")
        let secondURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cmux-7311-detach-b-\(UUID().uuidString).txt")
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }
        try "first".write(to: firstURL, atomically: true, encoding: .utf8)
        try "second".write(to: secondURL, atomically: true, encoding: .utf8)

        let firstPanel = FilePreviewPanel(workspaceId: UUID(), filePath: firstURL.path)
        let secondPanel = FilePreviewPanel(workspaceId: UUID(), filePath: secondURL.path)
        defer {
            firstPanel.close()
            secondPanel.close()
        }
        let session = FilePreviewQuickLookSession()
        let container = try #require(session.view(
            panel: firstPanel,
            revision: firstPanel.previewRevision,
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
        let stalePreviewView = try #require(
            container.livePreviewView() as? TrackedQLPreviewView
        )
        #expect(stalePreviewView.previewItem != nil)
        #expect(!stalePreviewView.didDetachFromWindow)

        window.contentView = nil
        #expect(stalePreviewView.window == nil)
        #expect(stalePreviewView.didDetachFromWindow)

        session.update(
            container,
            panel: secondPanel,
            revision: secondPanel.previewRevision,
            isVisibleInUI: true,
            backgroundColor: .clear,
            drawsBackground: false
        )

        let freshPreviewView = try #require(container.livePreviewView())
        let freshPreviewItem = try #require(freshPreviewView.previewItem)
        #expect(freshPreviewView !== stalePreviewView)
        #expect(freshPreviewItem.previewItemURL == secondURL)
        #expect(stalePreviewView.previewItem == nil)
    }

    @Test
    func quickLookUpdateRetiresInnerPreviewMissingFromMountedContainer() throws {
        let firstURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cmux-7311-quicklook-a-\(UUID().uuidString).txt")
        let secondURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cmux-7311-quicklook-b-\(UUID().uuidString).txt")
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }
        try "first".write(to: firstURL, atomically: true, encoding: .utf8)
        try "second".write(to: secondURL, atomically: true, encoding: .utf8)

        let firstPanel = FilePreviewPanel(workspaceId: UUID(), filePath: firstURL.path)
        let secondPanel = FilePreviewPanel(workspaceId: UUID(), filePath: secondURL.path)
        defer {
            firstPanel.close()
            secondPanel.close()
        }
        let session = FilePreviewQuickLookSession()
        let container = try #require(session.view(
            panel: firstPanel,
            revision: firstPanel.previewRevision,
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
        _ = try #require(container.livePreviewView())
        let stalePreviewView = try #require(
            container.replaceLivePreviewWithUnattachedPreview()
        )
        #expect(container.window != nil)
        #expect(stalePreviewView.window == nil)
        let trackedStalePreviewView = try #require(stalePreviewView as? TrackedQLPreviewView)
        #expect(!trackedStalePreviewView.didDetachFromWindow)
        #expect(stalePreviewView.previewItem != nil)

        session.update(
            container,
            panel: secondPanel,
            revision: secondPanel.previewRevision,
            isVisibleInUI: true,
            backgroundColor: .clear,
            drawsBackground: false
        )

        let freshPreviewView = try #require(container.livePreviewView())
        let freshPreviewItem = try #require(freshPreviewView.previewItem)
        #expect(freshPreviewView !== stalePreviewView)
        #expect(freshPreviewItem.previewItemURL == secondURL)
        #expect(stalePreviewView.previewItem == nil)
    }

    @Test
    func quickLookUpdateRetiresOrphanedPreviewAfterContainerDetaches() throws {
        let firstURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cmux-7311-off-window-a-\(UUID().uuidString).txt")
        let secondURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cmux-7311-off-window-b-\(UUID().uuidString).txt")
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }
        try "first".write(to: firstURL, atomically: true, encoding: .utf8)
        try "second".write(to: secondURL, atomically: true, encoding: .utf8)

        let firstPanel = FilePreviewPanel(workspaceId: UUID(), filePath: firstURL.path)
        let secondPanel = FilePreviewPanel(workspaceId: UUID(), filePath: secondURL.path)
        defer {
            firstPanel.close()
            secondPanel.close()
        }
        let session = FilePreviewQuickLookSession()
        let container = try #require(session.view(
            panel: firstPanel,
            revision: firstPanel.previewRevision,
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
        _ = try #require(container.livePreviewView())
        let stalePreviewView = try #require(
            container.replaceLivePreviewWithUnattachedPreview()
        )
        let trackedStalePreviewView = try #require(stalePreviewView as? TrackedQLPreviewView)
        #expect(stalePreviewView.superview == nil)
        #expect(!trackedStalePreviewView.didDetachFromWindow)

        window.contentView = nil
        #expect(container.window == nil)
        #expect(stalePreviewView.window == nil)

        session.update(
            container,
            panel: secondPanel,
            revision: secondPanel.previewRevision,
            isVisibleInUI: true,
            backgroundColor: .clear,
            drawsBackground: false
        )

        let freshPreviewView = try #require(container.livePreviewView())
        let freshPreviewItem = try #require(freshPreviewView.previewItem)
        #expect(freshPreviewView !== stalePreviewView)
        #expect(freshPreviewView.superview === container)
        #expect(freshPreviewItem.previewItemURL == secondURL)
        #expect(stalePreviewView.previewItem == nil)
    }

    @Test
    func quickLookReusePolicyRequiresStructuralAndWindowOwnership() {
        #expect(FilePreviewQuickLookContainerView.shouldRetire(
            didDetachFromWindow: false,
            isChildOfContainer: false,
            sharesContainerWindow: false
        ))
        #expect(FilePreviewQuickLookContainerView.shouldRetire(
            didDetachFromWindow: false,
            isChildOfContainer: true,
            sharesContainerWindow: false
        ))
        #expect(!FilePreviewQuickLookContainerView.shouldRetire(
            didDetachFromWindow: false,
            isChildOfContainer: true,
            sharesContainerWindow: true
        ))
    }
}
