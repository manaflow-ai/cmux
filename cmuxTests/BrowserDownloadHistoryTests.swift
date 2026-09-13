import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct BrowserDownloadHistoryTests {
    @Test func savedDownloadHistoryKeepsActualPathAndIsRepeatableAfterFileDeletion() throws {
        let panel = BrowserPanel(workspaceId: UUID(), renderInitialNavigation: false)
        defer { panel.close() }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-browser-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let resolvedURL = root.appendingPathComponent("report (1).csv")
        try Data(repeating: 7, count: 42).write(to: resolvedURL)

        panel.applyBrowserDownloadEvent(type: "started", downloadID: "download-1", filename: "report.csv", path: nil)
        panel.applyBrowserDownloadEvent(type: "saved", downloadID: "download-1", filename: "report.csv", path: resolvedURL.path)

        let firstSnapshot = panel.recentDownloads
        let secondSnapshot = panel.recentDownloads
        let record = try #require(firstSnapshot.first)
        #expect(firstSnapshot == secondSnapshot)
        #expect(record.id == "download-1")
        #expect(record.filename == "report.csv")
        #expect(record.fileURL?.path == resolvedURL.path)
        #expect(record.byteCount == 42)

        try FileManager.default.removeItem(at: resolvedURL)
        #expect(panel.recentDownloads.first?.fileURL?.path == resolvedURL.path)
        #expect(panel.recentDownloads.first?.byteCount == 42)
    }

    @Test func downloadHistoryStaysIsolatedPerBrowserPanelAndClearOnlyClearsThatPanel() {
        let first = BrowserPanel(workspaceId: UUID(), renderInitialNavigation: false)
        let second = BrowserPanel(workspaceId: UUID(), renderInitialNavigation: false)
        defer {
            first.close()
            second.close()
        }
        first.applyBrowserDownloadEvent(type: "failed", downloadID: "first", filename: "first.csv", path: nil)
        second.applyBrowserDownloadEvent(type: "saved", downloadID: "second", filename: "second.csv", path: "/tmp/second.csv")

        #expect(first.recentDownloads.map(\.id) == ["first"])
        #expect(second.recentDownloads.map(\.id) == ["second"])
        first.clearRecentDownloads()
        #expect(first.recentDownloads.isEmpty)
        #expect(second.recentDownloads.map(\.id) == ["second"])
    }
}
