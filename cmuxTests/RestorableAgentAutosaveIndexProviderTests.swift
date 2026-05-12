import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class RestorableAgentAutosaveIndexProviderTests: XCTestCase {
    func testAutosaveIndexUsesCachedProcessDetectedSnapshotsUntilExplicitRefresh() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-autosave-agent-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let workspaceId = UUID()
        let panelId = UUID()
        let detector = RestorableAgentProcessDetectorSpy(workspaceId: workspaceId, panelId: panelId)
        let provider = RestorableAgentSessionIndexProvider(
            homeDirectory: home.path,
            processDetector: detector.detect
        )

        let initialIndex = await provider.indexForAutosave()
        XCTAssertNil(initialIndex.snapshot(workspaceId: workspaceId, panelId: panelId))
        XCTAssertEqual(detector.scanCount, 0)

        await provider.refreshProcessDetectedSnapshots(reason: "surface.ports_kick")
        XCTAssertEqual(detector.scanCount, 1)
        let refreshedIndex = await provider.indexForAutosave()
        XCTAssertEqual(
            refreshedIndex.snapshot(workspaceId: workspaceId, panelId: panelId)?.sessionId,
            "detected-session-1"
        )

        _ = await provider.indexForAutosave()
        _ = await provider.indexForAutosave()
        XCTAssertEqual(
            detector.scanCount,
            1,
            "Idle autosave index reads must not rescan the global process table"
        )

        await provider.refreshProcessDetectedSnapshots(reason: "surface.report_tty")
        XCTAssertEqual(detector.scanCount, 2)
        let secondRefreshIndex = await provider.indexForAutosave()
        XCTAssertEqual(
            secondRefreshIndex.snapshot(workspaceId: workspaceId, panelId: panelId)?.sessionId,
            "detected-session-2"
        )
    }
}

private final class RestorableAgentProcessDetectorSpy: @unchecked Sendable {
    private let lock = NSLock()
    private let workspaceId: UUID
    private let panelId: UUID
    private var scans = 0

    var scanCount: Int {
        lock.withLock { scans }
    }

    init(workspaceId: UUID, panelId: UUID) {
        self.workspaceId = workspaceId
        self.panelId = panelId
    }

    func detect(
        registry: CmuxVaultAgentRegistry,
        fileManager: FileManager
    ) -> RestorableAgentSessionIndex.DetectedSnapshots {
        let scanNumber = lock.withLock {
            scans += 1
            return scans
        }
        let registration = CmuxVaultAgentRegistration(
            id: "acme-agent",
            name: "Acme Agent",
            detect: CmuxVaultAgentDetectRule(processName: "acme-agent"),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "acme-agent --session {{sessionId}}",
            cwd: .preserve
        )
        let snapshot = SessionRestorableAgentSnapshot(
            kind: .custom(registration.id),
            sessionId: "detected-session-\(scanNumber)",
            workingDirectory: "/tmp/acme",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: registration.id,
                executablePath: "/usr/local/bin/acme-agent",
                arguments: ["/usr/local/bin/acme-agent", "--session", "detected-session-\(scanNumber)"],
                workingDirectory: "/tmp/acme",
                environment: ["PWD": "/tmp/acme"],
                capturedAt: TimeInterval(scanNumber),
                source: "process"
            ),
            registration: registration
        )
        return [
            RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId): (
                snapshot: snapshot,
                updatedAt: TimeInterval(scanNumber)
            ),
        ]
    }
}
