import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite @MainActor struct DiffViewerFinalReviewRegressionTests {
    @Test func diffViewerSnapshotDeadlineReturnsWithoutWaitingForStalledRefresh() async {
        let stalled = Task<Int, Never> {
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {}
            return 7
        }
        let clock = ContinuousClock()
        let started = clock.now

        let result = await AppDelegate.valueBeforeDiffViewerDeadline(
            from: stalled,
            timeout: .milliseconds(20)
        )

        if case .value = result {
            Issue.record("stalled snapshot unexpectedly beat the deadline")
        }
        #expect(clock.now - started < .seconds(1))
        #expect(stalled.isCancelled)
    }

    @Test func sidecarReadinessTimeoutDoesNotWaitForOpenPipeWriter() async {
        let readiness = Pipe()
        let clock = ContinuousClock()
        let started = clock.now

        do {
            try await DiffSidecarProcessSupervisor.waitForProcessGroupReady(
                from: readiness.fileHandleForReading,
                timeout: .milliseconds(20)
            )
            Issue.record("readiness wait unexpectedly succeeded")
        } catch {
            #expect(clock.now - started < .seconds(1))
        }

        try? readiness.fileHandleForWriting.close()
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
