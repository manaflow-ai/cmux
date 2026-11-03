import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `cmux browser download wait --path <file>` saves the surface's finished
/// download at that path. The downloads come from the browser panel's own
/// download delegate callbacks, so the path from WebKit's save to the socket
/// reply is the app's.
///
/// https://github.com/manaflow-ai/cmux/issues/25106
@Suite(.serialized)
@MainActor
struct BrowserDownloadWaitPathTests {
    @Test func downloadSavedBeforeTheWaitIsCopiedToThePath() async throws {
        try await withPanel { panel, params, root in
            let saved = try savedFile(in: root, named: "x.txt", contents: "hello")
            let delegate = try #require(panel.downloadDelegate)
            delegate.onDownloadStarted?("x.txt", "download-1")
            delegate.onDownloadSaved?("x.txt", saved, true, "download-1")

            let destination = root.appendingPathComponent("wanted/x.txt")
            var wait = params
            wait["path"] = destination.path
            wait["timeout_ms"] = 5_000
            let response = try await request("browser.download.wait", wait)
            #expect(response["ok"] as? Bool == true, "\(response)")
            let result = try #require(response["result"] as? [String: Any])
            #expect(result["path"] as? String == destination.path)
            #expect(result["downloaded"] as? Bool == true)
            #expect((result["download"] as? [String: Any])?["path"] as? String == saved.path)
            #expect(try String(contentsOf: destination, encoding: .utf8) == "hello")
            #expect(FileManager.default.fileExists(atPath: saved.path))

            // The download was consumed by this wait.
            var again = params
            again["timeout_ms"] = 50
            let second = try await request("browser.download.wait", again)
            #expect(second["ok"] as? Bool == false, "\(second)")
        }
    }

    /// The panel's progress event comes first; the wait takes the saved one
    /// and replaces the file already at the path.
    @Test func progressEventDoesNotEndThePathWait() async throws {
        try await withPanel { panel, params, root in
            let destination = root.appendingPathComponent("x.txt")
            try Data("old".utf8).write(to: destination)
            var wait = params
            wait["path"] = destination.path
            wait["timeout_ms"] = 10_000

            let saved = try savedFile(in: root, named: "download.txt", contents: "hello")
            let delegate = try #require(panel.downloadDelegate)
            delegate.onDownloadStarted?("x.txt", "download-2")
            delegate.onDownloadReadyToSave?("x.txt", "download-2")
            delegate.onDownloadSaved?("x.txt", saved, true, "download-2")

            let response = try await request("browser.download.wait", wait)
            #expect(response["ok"] as? Bool == true, "\(response)")
            #expect(try String(contentsOf: destination, encoding: .utf8) == "hello")
        }
    }

    @Test func existingFileAtThePathIsNotADownload() async throws {
        try await withPanel { _, params, root in
            let destination = root.appendingPathComponent("x.txt")
            try Data("old".utf8).write(to: destination)
            var wait = params
            wait["path"] = destination.path
            wait["timeout_ms"] = 50
            let response = try await request("browser.download.wait", wait)
            #expect(response["ok"] as? Bool == false, "\(response)")
            #expect((response["error"] as? [String: Any])?["code"] as? String == "timeout")
            #expect(try String(contentsOf: destination, encoding: .utf8) == "old")
        }
    }

    @Test func failedDownloadIsReportedAndWritesNothing() async throws {
        try await withPanel { panel, params, root in
            let delegate = try #require(panel.downloadDelegate)
            delegate.onDownloadStarted?("x.txt", "download-3")
            delegate.onDownloadFailed?(NSError(domain: "test", code: 1), true, "download-3")

            let destination = root.appendingPathComponent("x.txt")
            var wait = params
            wait["path"] = destination.path
            wait["timeout_ms"] = 5_000
            let response = try await request("browser.download.wait", wait)
            #expect(response["ok"] as? Bool == false, "\(response)")
            let error = try #require(response["error"] as? [String: Any])
            #expect(error["code"] as? String == "download_failed")
            #expect((error["data"] as? [String: Any])?["path"] as? String == destination.path)
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
    }

    @Test func cancelledDownloadIsReported() async throws {
        try await withPanel { panel, params, root in
            let delegate = try #require(panel.downloadDelegate)
            delegate.onDownloadStarted?("x.txt", "download-5")
            delegate.onDownloadCancelled?("x.txt", true, "download-5")

            var wait = params
            wait["path"] = root.appendingPathComponent("x.txt").path
            wait["timeout_ms"] = 5_000
            let response = try await request("browser.download.wait", wait)
            let error = try #require(response["error"] as? [String: Any], "\(response)")
            #expect(error["code"] as? String == "download_failed")
            #expect((error["data"] as? [String: Any]).flatMap { $0["download"] as? [String: Any] }?["type"] as? String == "cancelled")
        }
    }

    @Test func relativePathIsRejected() async throws {
        try await withPanel { _, params, _ in
            var wait = params
            wait["path"] = "x.txt"
            wait["timeout_ms"] = 5_000
            let response = try await request("browser.download.wait", wait)
            #expect((response["error"] as? [String: Any])?["code"] as? String == "invalid_params", "\(response)")
        }
    }

    @Test func directoryAtThePathIsRejectedWithoutTakingTheDownload() async throws {
        try await withPanel { panel, params, root in
            let saved = try savedFile(in: root, named: "x.txt", contents: "hello")
            let delegate = try #require(panel.downloadDelegate)
            delegate.onDownloadStarted?("x.txt", "download-4")
            delegate.onDownloadSaved?("x.txt", saved, true, "download-4")

            let folder = root.appendingPathComponent("folder", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var wait = params
            wait["path"] = folder.path
            wait["timeout_ms"] = 5_000
            let rejected = try await request("browser.download.wait", wait)
            #expect(rejected["ok"] as? Bool == false, "\(rejected)")
            #expect((rejected["error"] as? [String: Any])?["code"] as? String == "invalid_params")
            #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)

            // A plain wait still gets the download the rejected one left alone.
            var plain = params
            plain["timeout_ms"] = 5_000
            let response = try await request("browser.download.wait", plain)
            #expect(response["ok"] as? Bool == true, "\(response)")
            let result = try #require(response["result"] as? [String: Any])
            #expect((result["download"] as? [String: Any])?["download_id"] as? String == "download-4")
        }
    }

    private func withPanel(
        _ body: (BrowserPanel, [String: Any], URL) async throws -> Void
    ) async throws {
        let manager = TabManager()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-download-wait-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            manager.tabs.forEach { $0.teardownAllPanels() }
            TerminalController.shared.setActiveTabManager(nil)
            try? FileManager.default.removeItem(at: root)
        }
        let workspace = try #require(manager.selectedWorkspace)
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        let panel = try #require(workspace.newBrowserSurface(inPane: pane, focus: false, creationPolicy: .restoration))
        TerminalController.shared.setActiveTabManager(manager)
        try await body(
            panel,
            ["workspace_id": workspace.id.uuidString, "surface_id": panel.id.uuidString],
            root
        )
    }

    private func savedFile(in root: URL, named name: String, contents: String) throws -> URL {
        let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let url = downloads.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: ["id": 1, "method": method, "params": params])
        let line = String(decoding: data, as: UTF8.self)
        let controller = TerminalController.shared
        let response = await Task.detached {
            controller.handleSocketLine(line)
        }.value
        return try #require(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
    }
}
