import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct GrokVaultAgentPersistenceTests {
    @Test func freshLaunchDiscoversSessionFromConfiguredDirectory() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }

        try fixture.writeSession(
            id: "019fbcbd-cdbe-74d2-9395-411d6f1dcdc1",
            createdAt: "2026-08-01T09:53:03.549632Z",
            updatedAt: "2026-08-01T09:53:16.673393Z",
            lastActiveAt: "2026-08-01T09:53:16.673393Z"
        )

        let detected = fixture.detectedEntry(arguments: ["/usr/local/bin/grok"])

        #expect(detected?.snapshot.sessionId == "019fbcbd-cdbe-74d2-9395-411d6f1dcdc1")
        #expect(detected?.sessionIDSource == .inferredLatestSessionFile)
    }

    @Test func latestSessionUsesContentActivityInsteadOfIncidentalModificationDates() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }

        try fixture.writeSession(
            id: "019f430d-7c57-70b2-a789-b643c0e148ee",
            createdAt: "2026-07-08T18:46:25.247868Z",
            updatedAt: "2026-07-20T02:23:23.521216Z",
            lastActiveAt: "2026-07-08T18:58:26.470913Z",
            summaryModifiedAt: Date(timeIntervalSince1970: 2_000_000_000),
            directoryModifiedAt: Date(timeIntervalSince1970: 2_000_000_000),
            lockModifiedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )
        try fixture.writeSession(
            id: "019ebaf3-8860-7f53-b31b-70e8b426016d",
            createdAt: "2026-06-12T08:29:43.018254Z",
            updatedAt: "2026-07-11T19:41:04.119069Z",
            lastActiveAt: "2026-07-11T19:41:04.109119Z",
            summaryModifiedAt: Date(timeIntervalSince1970: 1_000),
            directoryModifiedAt: Date(timeIntervalSince1970: 1_000),
            lockModifiedAt: Date(timeIntervalSince1970: 1_000)
        )

        let detected = fixture.detectedEntry(arguments: ["/usr/local/bin/grok"])

        #expect(detected?.snapshot.sessionId == "019ebaf3-8860-7f53-b31b-70e8b426016d")
    }

    @Test func updatedAtRanksSessionWhenLastActiveAtIsMissing() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }

        try fixture.writeSession(
            id: "updated-at-fallback",
            createdAt: "2026-07-01T00:00:00Z",
            updatedAt: "2026-07-10T00:00:00Z",
            summaryModifiedAt: Date(timeIntervalSince1970: 1_000),
            directoryModifiedAt: Date(timeIntervalSince1970: 1_000),
            lockModifiedAt: Date(timeIntervalSince1970: 1_000)
        )
        try fixture.writeSession(
            id: "older-last-active",
            createdAt: "2026-07-01T00:00:00Z",
            updatedAt: "2026-07-09T00:00:00Z",
            lastActiveAt: "2026-07-09T00:00:00Z",
            summaryModifiedAt: Date(timeIntervalSince1970: 2_000_000_000),
            directoryModifiedAt: Date(timeIntervalSince1970: 2_000_000_000),
            lockModifiedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )

        let detected = fixture.detectedEntry(arguments: ["/usr/local/bin/grok"])

        #expect(detected?.snapshot.sessionId == "updated-at-fallback")
    }

    @Test func createdAtRanksSessionWhenLaterActivityTimestampsAreMissing() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }

        try fixture.writeSession(
            id: "created-at-fallback",
            createdAt: "2026-07-10T00:00:00Z",
            summaryModifiedAt: Date(timeIntervalSince1970: 1_000),
            directoryModifiedAt: Date(timeIntervalSince1970: 1_000),
            lockModifiedAt: Date(timeIntervalSince1970: 1_000)
        )
        try fixture.writeSession(
            id: "older-last-active",
            createdAt: "2026-07-01T00:00:00Z",
            updatedAt: "2026-07-09T00:00:00Z",
            lastActiveAt: "2026-07-09T00:00:00Z",
            summaryModifiedAt: Date(timeIntervalSince1970: 2_000_000_000),
            directoryModifiedAt: Date(timeIntervalSince1970: 2_000_000_000),
            lockModifiedAt: Date(timeIntervalSince1970: 2_000_000_000)
        )

        let detected = fixture.detectedEntry(arguments: ["/usr/local/bin/grok"])

        #expect(detected?.snapshot.sessionId == "created-at-fallback")
    }

    @Test(arguments: ["-r", "--resume"])
    func explicitResumeArgumentTakesPriority(_ option: String) throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }

        try fixture.writeSession(
            id: "disk-session",
            createdAt: "2026-08-01T09:53:03.549632Z",
            updatedAt: "2026-08-01T09:53:16.673393Z",
            lastActiveAt: "2026-08-01T09:53:16.673393Z"
        )

        let detected = fixture.detectedEntry(
            arguments: ["/usr/local/bin/grok", option, "explicit-session"]
        )

        #expect(detected?.snapshot.sessionId == "explicit-session")
        #expect(detected?.sessionIDSource == .explicit)
    }

    @Test func cwdWithoutMatchingSessionDirectoryReturnsNil() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }
        let otherCWD = fixture.root.appendingPathComponent("other-repo", isDirectory: true)
        try fixture.fileManager.createDirectory(at: otherCWD, withIntermediateDirectories: true)
        try fixture.writeSession(
            id: "other-cwd-session",
            cwd: otherCWD,
            createdAt: "2026-08-01T09:53:03.549632Z",
            updatedAt: "2026-08-01T09:53:16.673393Z",
            lastActiveAt: "2026-08-01T09:53:16.673393Z"
        )

        #expect(fixture.detectedEntry(arguments: ["/usr/local/bin/grok"]) == nil)
    }

    @Test func summaryFileModificationDateIsLastResortWhenContentHasNoTimestamp() throws {
        let fixture = try Fixture.make()
        defer { fixture.cleanup() }

        try fixture.writeSession(
            id: "older-summary",
            summaryModifiedAt: Date(timeIntervalSince1970: 1_000),
            directoryModifiedAt: Date(timeIntervalSince1970: 3_000)
        )
        try fixture.writeSession(
            id: "newer-summary",
            summaryModifiedAt: Date(timeIntervalSince1970: 2_000),
            directoryModifiedAt: Date(timeIntervalSince1970: 500)
        )

        let detected = fixture.detectedEntry(arguments: ["/usr/local/bin/grok"])

        #expect(detected?.snapshot.sessionId == "newer-summary")
    }
}

private extension GrokVaultAgentPersistenceTests {
    struct Fixture {
        let fileManager: FileManager
        let root: URL
        let cwd: URL
        let sessionsRoot: URL
        let workspaceID: UUID
        let panelID: UUID

        static func make() throws -> Self {
            let fileManager = FileManager.default
            let root = fileManager.temporaryDirectory
                .appendingPathComponent("cmux-grok-process-discovery-\(UUID().uuidString)", isDirectory: true)
            let cwd = root.appendingPathComponent("repo with spaces", isDirectory: true)
            let sessionsRoot = root.appendingPathComponent("sessions", isDirectory: true)
            try fileManager.createDirectory(at: cwd, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
            return Self(
                fileManager: fileManager,
                root: root,
                cwd: cwd,
                sessionsRoot: sessionsRoot,
                workspaceID: UUID(),
                panelID: UUID()
            )
        }

        func cleanup() {
            try? fileManager.removeItem(at: root)
        }

        func detectedEntry(
            arguments: [String],
            cwd detectedCWD: URL? = nil
        ) -> RestorableAgentSessionIndex.ProcessDetectedSnapshotEntry? {
            let processID = 9_377
            let process = CmuxTopProcessInfo(
                pid: processID,
                parentPID: 1,
                name: "grok",
                path: "/usr/local/bin/grok",
                ttyDevice: nil,
                cmuxWorkspaceID: workspaceID,
                cmuxSurfaceID: panelID,
                cmuxAttributionReason: "cmux-test",
                processGroupID: nil,
                terminalProcessGroupID: nil,
                cpuPercent: 0,
                residentBytes: 0,
                virtualBytes: 0,
                threadCount: 1
            )
            let processSnapshot = CmuxTopProcessSnapshot(
                processes: [process],
                sampledAt: Date(timeIntervalSince1970: 0),
                includesProcessDetails: true
            )
            var registration = CmuxVaultAgentRegistration.builtInGrok
            registration.sessionDirectory = sessionsRoot.path
            let key = RestorableAgentSessionIndex.PanelKey(
                workspaceId: workspaceID,
                panelId: panelID
            )

            return RestorableAgentSessionIndex.processDetectedSnapshots(
                registry: CmuxVaultAgentRegistry(registrations: [registration]),
                fileManager: fileManager,
                processSnapshot: processSnapshot,
                capturedAt: 42,
                processArgumentsProvider: { requestedProcessID in
                    guard requestedProcessID == processID else { return nil }
                    return CmuxTopProcessArguments(
                        arguments: arguments,
                        environment: [
                            "HOME": root.path,
                            "PWD": (detectedCWD ?? cwd).path,
                        ]
                    )
                }
            )[key]
        }

        func writeSession(
            id: String,
            cwd sessionCWD: URL? = nil,
            createdAt: String? = nil,
            updatedAt: String? = nil,
            lastActiveAt: String? = nil,
            summaryModifiedAt: Date? = nil,
            directoryModifiedAt: Date? = nil,
            lockModifiedAt: Date? = nil
        ) throws {
            let projectDirectory = sessionsRoot.appendingPathComponent(
                GrokSessionLocator.encodedSessionCWD((sessionCWD ?? cwd).path),
                isDirectory: true
            )
            let sessionDirectory = projectDirectory.appendingPathComponent(id, isDirectory: true)
            try fileManager.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)

            var summary: [String: String] = [:]
            summary["created_at"] = createdAt
            summary["updated_at"] = updatedAt
            summary["last_active_at"] = lastActiveAt
            let summaryURL = sessionDirectory.appendingPathComponent("summary.json", isDirectory: false)
            let summaryData = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
            try summaryData.write(to: summaryURL)
            if let summaryModifiedAt {
                try fileManager.setAttributes(
                    [.modificationDate: summaryModifiedAt],
                    ofItemAtPath: summaryURL.path
                )
            }

            if let lockModifiedAt {
                let lockURL = sessionDirectory.appendingPathComponent("summary.json.lock", isDirectory: false)
                try Data().write(to: lockURL)
                try fileManager.setAttributes(
                    [.modificationDate: lockModifiedAt],
                    ofItemAtPath: lockURL.path
                )
            }
            if let directoryModifiedAt {
                try fileManager.setAttributes(
                    [.modificationDate: directoryModifiedAt],
                    ofItemAtPath: sessionDirectory.path
                )
            }
        }
    }
}
