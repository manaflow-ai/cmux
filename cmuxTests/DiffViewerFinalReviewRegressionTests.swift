import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite @MainActor struct DiffViewerFinalReviewRegressionTests {
    @Test func agentSnapshotDeadlineFailsClosedWhenRefreshStalls() async {
        let stalledRefresh = AsyncStream<String>.makeStream()
        let race = DiffViewerAgentSnapshotDeadline<String>()

        let value = await race.value(
            operation: {
                for await value in stalledRefresh.stream {
                    return value
                }
                return "cancelled"
            },
            waitForDeadline: {}
        )

        #expect(value == nil)
        stalledRefresh.continuation.finish()
    }

    @Test func agentSnapshotDeadlineReturnsFreshValueBeforeDeadline() async {
        let stalledDeadline = AsyncStream<Void>.makeStream()
        let race = DiffViewerAgentSnapshotDeadline<String>()

        let value = await race.value(
            operation: { "fresh" },
            waitForDeadline: {
                for await _ in stalledDeadline.stream {}
            }
        )

        #expect(value == "fresh")
        stalledDeadline.continuation.finish()
    }

    @Test func loadingOwnershipRejectsSupersededOperation() {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: DiffViewerLoadingPage.url,
            renderInitialNavigation: false
        )
        defer { panel.close() }
        let firstOperationID = panel.beginDiffViewerLoadingOperation()
        let secondOperationID = panel.beginDiffViewerLoadingOperation()

        #expect(!panel.isShowingDiffViewerLoadingState(
            expectedURL: DiffViewerLoadingPage.url.absoluteString,
            operationID: firstOperationID
        ))
        #expect(panel.isShowingDiffViewerLoadingState(
            expectedURL: DiffViewerLoadingPage.url.absoluteString,
            operationID: secondOperationID
        ))
    }

    @Test func browserNavigationOwnershipCanBeValidatedBeforeSessionRegistration() {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: DiffViewerLoadingPage.url,
            renderInitialNavigation: false
        )
        defer { panel.close() }
        let operationID = panel.beginDiffViewerLoadingOperation()

        #expect(panel.canAcceptCLINavigation(
            expectedURL: DiffViewerLoadingPage.url.absoluteString,
            expectedOperationID: operationID
        ))
        #expect(!panel.canAcceptCLINavigation(
            expectedURL: DiffViewerLoadingPage.url.absoluteString,
            expectedOperationID: UUID()
        ))
    }

    @Test func browserNavigationOwnershipAcceptsOwnedOpeningURLBeforeWebKitObservesIt() throws {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: DiffViewerLoadingPage.url,
            renderInitialNavigation: false
        )
        defer { panel.close() }
        let operationID = panel.beginDiffViewerLoadingOperation()
        let openingURL = try #require(CmuxDiffViewerURLSchemeHandler.diffViewerURL(
            token: UUID().uuidString.lowercased(),
            requestPath: "/diff-fast-opening.html"
        ))
        panel.diffViewerLoadingOwnedOpeningURL = openingURL.absoluteString

        #expect(panel.canAcceptCLINavigation(
            expectedURL: openingURL.absoluteString,
            expectedOperationID: operationID
        ))
    }

    @Test func commandPaletteFingerprintChangesWithKeyboardShortcutRevision() {
        let first = ContentView.commandPaletteCommandsFingerprint(
            snapshotFingerprint: 11,
            configRevision: 22,
            keyboardShortcutRevision: 33
        )
        let second = ContentView.commandPaletteCommandsFingerprint(
            snapshotFingerprint: 11,
            configRevision: 22,
            keyboardShortcutRevision: 34
        )

        #expect(first != second)
    }

    @Test func internalPreloadNeverFallsBackToTheExternalBrowser() {
        #expect(!Workspace.BrowserPanelCreationPolicy.automationPreload.opensURLExternallyWhenDisabled)
        #expect(!Workspace.BrowserPanelCreationPolicy.restoration.opensURLExternallyWhenDisabled)
        #expect(Workspace.BrowserPanelCreationPolicy.userInitiated.opensURLExternallyWhenDisabled)
    }

    @Test func assetPruningPreservesReferencedAndNewestVersions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-diff-assets-\(UUID().uuidString)", isDirectory: true)
        let assets = root.appendingPathComponent("assets", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var directories: [URL] = []
        for index in 0..<18 {
            let directory = assets.appendingPathComponent("version-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(-Double(index + 2) * 24 * 60 * 60)],
                ofItemAtPath: directory.path
            )
            directories.append(directory)
        }
        let referenced = directories[17]
        let manifest: [String: Any] = [
            "token": "0123456789abcdef",
            "files": [[
                "request_path": "/assets/version-17/main.mjs",
                "file_path": referenced.appendingPathComponent("main.mjs").path,
            ]],
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(
            to: root.appendingPathComponent(".manifest-0123456789abcdef.json"),
            options: .atomic
        )

        CMUXCLI(args: []).pruneDiffViewerAssetDirectories(in: root, now: now)

        for directory in directories.prefix(4) {
            #expect(FileManager.default.fileExists(atPath: directory.path))
        }
        #expect(FileManager.default.fileExists(atPath: referenced.path))
        #expect(!FileManager.default.fileExists(atPath: directories[4].path))
        let remaining = try FileManager.default.contentsOfDirectory(atPath: assets.path)
        #expect(remaining.count == 5)
    }
}
