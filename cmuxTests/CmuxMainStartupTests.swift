import Foundation
import CmuxWorkspaces
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct CmuxMainStartupTests {

    @Test
    func startupPreparationPreservesRestoreOrderingAndCleansCheckpoints() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CmuxMainStartupTests.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SessionSnapshotRepository<AppSessionSnapshot>(
            schemaVersion: SessionSnapshotSchema.currentVersion,
            bundleIdentifier: "com.cmuxterm.app.test",
            appSupportDirectory: directory
        )
        let panelID = UUID()
        let snapshot = AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion, createdAt: 1,
            windows: [SessionWindowSnapshot(
                tabManager: SessionTabManagerSnapshot(
                    selectedWorkspaceIndex: 0,
                    workspaces: [SessionWorkspaceSnapshot(
                        processTitle: "Terminal",
                        customTitle: nil,
                        customColor: nil,
                        isPinned: false,
                        currentDirectory: directory.path,
                        focusedPanelId: panelID,
                        layout: .pane(SessionPaneLayoutSnapshot(
                            panelIds: [panelID],
                            selectedPanelId: panelID
                        )),
                        panels: [SessionPanelSnapshot(
                            id: panelID,
                            type: .terminal,
                            title: "Terminal",
                            customTitle: nil,
                            directory: directory.path,
                            isPinned: false,
                            isManuallyUnread: false,
                            listeningPorts: [],
                            ttyName: nil,
                            terminal: SessionTerminalPanelSnapshot(
                                workingDirectory: directory.path
                            ),
                            browser: nil,
                            markdown: nil,
                            filePreview: nil,
                            rightSidebarTool: nil
                        )],
                        statusEntries: [],
                        logEntries: [],
                        progress: nil,
                        gitBranch: nil
                    )]
                ),
                sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: nil)
            )]
        )
        #expect(store.save(snapshot, fileURL: nil))
        let primaryURL = try #require(store.defaultSnapshotFileURL())
        let checkpoints = SessionScrollbackCheckpointStore(primarySnapshotURL: primaryURL)
        try FileManager.default.createDirectory(at: checkpoints.directoryURL, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: checkpoints.fileURL(panelId: UUID()))
        let preparation = StartupSessionSnapshotPreparation(
            store: store, previousLaunchWasUnclean: false,
            crashOnlyPrimarySnapshotRemovalMarker: false, shouldAttemptRestore: true,
            didHandleExplicitOpenIntent: false, shouldInstallOverwriteGuard: false, environment: [:]
        )
        let result = await preparation.run()
        #expect(result.startupSnapshot?.windows.count == 1)
        #expect(!FileManager.default.fileExists(atPath: checkpoints.directoryURL.path))
    }

    /// Verifies the policy helper defaults to fatal while preserving overrides.
    @Test
    func exceptionCrashPolicyDefaultsToFatalAndPreservesExplicitOverrides() throws {
        let suiteName = "CmuxMainStartupTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        CmuxMain.installCrashOnExceptionsPolicy(defaults: defaults)
        #expect(defaults.bool(forKey: "NSApplicationCrashOnExceptions"))

        defaults.set(false, forKey: "NSApplicationCrashOnExceptions")
        CmuxMain.installCrashOnExceptionsPolicy(defaults: defaults)
        #expect(!defaults.bool(forKey: "NSApplicationCrashOnExceptions"))
    }

    /// Verifies production startup observes the fatal policy before workers or the app.
    @Test
    func productionStartupInstallsPolicyBeforeWorkerAndApp() throws {
        let suiteName = "CmuxMainStartupTests.\(UUID().uuidString)"
        let defaults = try #require(RecordingCrashPolicyDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var observations: [String] = []
        CmuxMain.runStartup(
            defaults: defaults,
            raiseFileDescriptorLimit: {},
            writeAppHostReceipt: {},
            routeWorkers: {
                #expect(defaults.didRegisterFatalPolicy)
                #expect(defaults.bool(forKey: "NSApplicationCrashOnExceptions"))
                observations.append("worker")
            },
            preloadSigningSecret: {},
            launchApp: {
                #expect(defaults.didRegisterFatalPolicy)
                #expect(defaults.bool(forKey: "NSApplicationCrashOnExceptions"))
                observations.append("app")
            }
        )

        #expect(observations == ["worker", "app"])
    }
}

private final class RecordingCrashPolicyDefaults: UserDefaults {
    private(set) var didRegisterFatalPolicy = false

    /// Records this invocation's policy registration independently of Foundation's global registration domain.
    override func register(defaults registrationDictionary: [String: Any]) {
        if registrationDictionary["NSApplicationCrashOnExceptions"] as? Bool == true {
            didRegisterFatalPolicy = true
        }
        super.register(defaults: registrationDictionary)
    }
}
