import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers

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

    @Test func completedDownloadExportsFileURLForTerminalInsertion() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-browser-drag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("report (1).csv")
        try Data("report".utf8).write(to: fileURL)

        let record = BrowserDownloadRecord(
            id: "download-complete",
            filename: fileURL.lastPathComponent,
            fileURL: fileURL,
            state: .saved,
            byteCount: 6
        )

        #expect(BrowserDownloadDragSource.fileURL(for: record) == fileURL.standardizedFileURL)
        let provider = try #require(BrowserDownloadDragSource.provider(for: record))
        #expect(provider.registeredTypeIdentifiers.contains(UTType.fileURL.identifier))

        let plan = TerminalImageTransferPlanner.plan(
            fileURLs: [fileURL],
            target: .local,
            mode: .drop
        )
        #expect(plan == .insertText(TerminalImageTransferPlanner.escapeForShell(fileURL.path)))
    }

    @Test func incompleteOrMissingDownloadDoesNotExportAFileDrag() throws {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-browser-drag-missing-\(UUID().uuidString)")
        let records = [
            BrowserDownloadRecord(
                id: "download-incomplete",
                filename: "pending.csv",
                fileURL: nil,
                state: .downloading,
                byteCount: nil
            ),
            BrowserDownloadRecord(
                id: "download-failed",
                filename: "failed.csv",
                fileURL: nil,
                state: .failed,
                byteCount: nil
            ),
            BrowserDownloadRecord(
                id: "download-missing",
                filename: "missing.csv",
                fileURL: missingURL,
                state: .saved,
                byteCount: 12
            )
        ]

        for record in records {
            #expect(BrowserDownloadDragSource.fileURL(for: record) == nil)
            #expect(BrowserDownloadDragSource.provider(for: record) == nil)
        }
    }

    @Test func completedDownloadFilePayloadIsAcceptedBySplitTerminalTargets() {
        let fileURL = URL(fileURLWithPath: "/tmp/cmux-browser-download.csv")
        let pasteboardTypes: [NSPasteboard.PasteboardType] = [UTType.fileURL.identifier].map {
            NSPasteboard.PasteboardType($0)
        }

        for _ in 0..<2 {
            #expect(
                TerminalPaneDropTargetView.shouldCaptureHitTesting(
                    pasteboardTypes: pasteboardTypes,
                    eventType: .cursorUpdate
                )
            )
            let plan = TerminalImageTransferPlanner.plan(
                fileURLs: [fileURL],
                target: .local,
                mode: .drop
            )
            #expect(plan == .insertText(TerminalImageTransferPlanner.escapeForShell(fileURL.path)))
        }
    }
}
