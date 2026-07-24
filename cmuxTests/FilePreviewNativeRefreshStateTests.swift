import AppKit
import AVKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct FilePreviewNativeRefreshStateTests {
    @Test("Media refresh keeps the player and its user settings")
    func mediaRefreshKeepsPlayerState() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "cmux-file-preview-media-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try Data().write(to: fileURL)

        let panel = FilePreviewPanel(
            workspaceId: UUID(),
            filePath: fileURL.path,
            startFileWatcher: false
        )
        defer { panel.close() }
        #expect(panel.previewMode == .media)

        let session = panel.nativeViewSessions.media
        let view = session.view(
            panel: panel,
            revision: panel.previewRevision,
            isVisibleInUI: true,
            backgroundColor: .textBackgroundColor,
            drawsBackground: true
        )
        let player = try #require(view.player)
        let originalItem = try #require(player.currentItem)
        player.volume = 0.25
        player.isMuted = true
        player.appliesMediaSelectionCriteriaAutomatically = false

        session.update(
            view,
            panel: panel,
            revision: panel.previewRevision + 1,
            isVisibleInUI: true,
            backgroundColor: .textBackgroundColor,
            drawsBackground: true
        )

        #expect(view.player === player)
        #expect(player.currentItem !== originalItem)
        #expect(player.volume == 0.25)
        #expect(player.isMuted)
        #expect(!player.appliesMediaSelectionCriteriaAutomatically)

        let refreshedItem = try #require(player.currentItem)
        session.update(
            view,
            panel: panel,
            revision: panel.previewRevision + 2,
            isVisibleInUI: true,
            backgroundColor: .textBackgroundColor,
            drawsBackground: true
        )
        #expect(view.player === player)
        #expect(player.currentItem !== refreshedItem)
    }

    @Test("Quick Look refresh keeps its preview item")
    func quickLookRefreshKeepsPreviewItem() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "cmux-file-preview-quick-look-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try Data([0x00, 0x01]).write(to: fileURL)

        let panel = FilePreviewPanel(
            workspaceId: UUID(),
            filePath: fileURL.path,
            startFileWatcher: false
        )
        defer { panel.close() }
        #expect(panel.previewMode == .quickLook)

        let session = panel.nativeViewSessions.quickLook
        let view = session.view(
            panel: panel,
            revision: panel.previewRevision,
            isVisibleInUI: true,
            backgroundColor: .textBackgroundColor,
            drawsBackground: true
        )
        let container = try #require(view as? FilePreviewQuickLookContainerView)
        let previewView = try #require(container.livePreviewView())
        let originalItem = try #require(previewView.previewItem as AnyObject?)

        try Data([0x00, 0x02, 0x03]).write(to: fileURL)
        session.update(
            view,
            panel: panel,
            revision: panel.previewRevision + 1,
            isVisibleInUI: true,
            backgroundColor: .textBackgroundColor,
            drawsBackground: true
        )

        let refreshedItem = try #require(previewView.previewItem as AnyObject?)
        #expect(refreshedItem === originalItem)
    }

    @Test("Quick Look refresh restores its opaque display state")
    func quickLookRefreshRestoresDisplayState() {
        let displayState = NSObject()
        let preview = ResettingQuickLookPreview(displayState: displayState)

        FilePreviewQuickLookSession.refreshPreservingDisplayState(preview)

        #expect(preview.refreshCount == 1)
        #expect(preview.displayState as AnyObject? === displayState)
    }
}

@MainActor
private final class ResettingQuickLookPreview: FilePreviewQuickLookRefreshing {
    var displayState: Any!
    private(set) var refreshCount = 0

    init(displayState: Any) {
        self.displayState = displayState
    }

    func refreshPreviewItem() {
        refreshCount += 1
        displayState = nil
    }
}
