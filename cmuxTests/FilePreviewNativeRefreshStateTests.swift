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
    }

    @Test("Quick Look refresh keeps its item and display state")
    func quickLookRefreshKeepsDisplayState() async throws {
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
        let displayState = NSObject()
        previewView.displayState = displayState

        try Data([0x02, 0x03]).write(to: fileURL)
        await panel.reloadFromDisk().value
        session.update(
            view,
            panel: panel,
            revision: panel.previewRevision,
            isVisibleInUI: true,
            backgroundColor: .textBackgroundColor,
            drawsBackground: true
        )

        let refreshedItem = try #require(previewView.previewItem as AnyObject?)
        #expect(refreshedItem === originalItem)
        #expect(previewView.displayState as AnyObject? === displayState)
    }
}
