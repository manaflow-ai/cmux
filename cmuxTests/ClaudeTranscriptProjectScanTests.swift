import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Counts the file checks and directory listings the restore index makes under
/// a Claude `projects/` folder, then answers from the real file system.
private final class ProjectsProbeCountingFileManager: FileManager {
    private let projectsMarker: String
    private(set) var probes = 0
    private(set) var listings = 0

    init(projectsMarker: String) {
        self.projectsMarker = projectsMarker
        super.init()
    }

    override func fileExists(atPath path: String) -> Bool {
        if path.contains(projectsMarker) { probes += 1 }
        return super.fileExists(atPath: path)
    }

    override func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
        if path.contains(projectsMarker) { probes += 1 }
        return super.fileExists(atPath: path, isDirectory: isDirectory)
    }

    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        if path.contains(projectsMarker) { probes += 1 }
        return try super.attributesOfItem(atPath: path)
    }

    override func contentsOfDirectory(atPath path: String) throws -> [String] {
        if path.contains(projectsMarker) { listings += 1 }
        return try super.contentsOfDirectory(atPath: path)
    }
}

/// #34664: a Claude hook record whose transcript was never written (a batch of
/// `claude -p` calls leaves hundreds) must not be checked against every folder
/// under `projects/`, or a restore costs records x folders.
struct ClaudeTranscriptProjectScanTests {
    private struct Fixture {
        let root: URL
        let configDir: URL
        let projectsDir: URL
        let projectsMarker: String
    }

    private func makeFixture(_ prefix: String) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        let configDir = root.appendingPathComponent("claude-config", isDirectory: true)
        let projectsDir = configDir.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(at: projectsDir, withIntermediateDirectories: true)
        return Fixture(
            root: root,
            configDir: configDir,
            projectsDir: projectsDir,
            projectsMarker: "\(root.lastPathComponent)/claude-config/projects"
        )
    }

    private func record(
        sessionId: String,
        workspaceId: UUID,
        panelId: UUID,
        cwd: String,
        configDir: URL
    ) -> [String: Any] {
        [
            "sessionId": sessionId,
            "workspaceId": workspaceId.uuidString,
            "surfaceId": panelId.uuidString,
            "cwd": cwd,
            "pid": NSNull(),
            "updatedAt": 10,
            "launchCommand": [
                "launcher": "claude",
                "executablePath": "/usr/local/bin/claude",
                "arguments": ["/usr/local/bin/claude"],
                "workingDirectory": cwd,
                "environment": ["CLAUDE_CONFIG_DIR": configDir.path],
                "capturedAt": 10,
                "source": "test",
            ],
        ]
    }

    private func writeHookStore(root: URL, sessions: [String: [String: Any]]) throws {
        let stateDir = root.appendingPathComponent(".cmuxterm", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: ["version": 1, "sessions": sessions],
            options: [.sortedKeys]
        )
        try data.write(to: stateDir.appendingPathComponent("claude-hook-sessions.json"), options: .atomic)
    }

    private func writeTranscript(sessionId: String, at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        {"type":"user","sessionId":"\(sessionId)","message":{"role":"user","content":"hello"}}

        """.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Folders that belong to other work, each with a transcript of its own.
    private func makeUnrelatedProjectFolders(_ count: Int, in projectsDir: URL) throws {
        for index in 0..<count {
            let folder = projectsDir.appendingPathComponent("-tmp-other-\(index)", isDirectory: true)
            try writeTranscript(
                sessionId: "other-\(index)",
                at: folder.appendingPathComponent("other-\(index).jsonl")
            )
        }
    }

    @Test
    func recordsWithoutATranscriptAreNotCheckedAgainstEveryProjectFolder() throws {
        let fixture = try makeFixture("cmux-claude-scan-stale")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let staleRecords = 20
        let projectFolders = 30
        try makeUnrelatedProjectFolders(projectFolders, in: fixture.projectsDir)

        var sessions: [String: [String: Any]] = [:]
        var panels: [(workspaceId: UUID, panelId: UUID)] = []
        for index in 0..<staleRecords {
            let sessionId = "stale-\(index)"
            let ids = (workspaceId: UUID(), panelId: UUID())
            panels.append(ids)
            sessions[sessionId] = record(
                sessionId: sessionId,
                workspaceId: ids.workspaceId,
                panelId: ids.panelId,
                cwd: fixture.root.appendingPathComponent("job-\(index)").path,
                configDir: fixture.configDir
            )
        }
        try writeHookStore(root: fixture.root, sessions: sessions)

        let fm = ProjectsProbeCountingFileManager(projectsMarker: fixture.projectsMarker)
        let index = RestorableAgentSessionIndex.load(homeDirectory: fixture.root.path, fileManager: fm)

        for ids in panels {
            #expect(index.snapshot(workspaceId: ids.workspaceId, panelId: ids.panelId) == nil)
        }
        // One pass over the folders plus a constant amount per record.
        #expect(
            fm.probes < staleRecords * projectFolders,
            "\(fm.probes) file checks under projects/ for \(staleRecords) records and \(projectFolders) folders"
        )
        #expect(
            fm.listings <= 2 * projectFolders,
            "\(fm.listings) directory listings under projects/ for \(projectFolders) folders"
        )
    }

    @Test
    func transcriptInAnotherProjectFolderStillRestoresTheSession() throws {
        let fixture = try makeFixture("cmux-claude-scan-drift")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try makeUnrelatedProjectFolders(5, in: fixture.projectsDir)

        // The session was started somewhere else, so its transcript is not in
        // the folder named after the recorded cwd.
        let sessionId = "cccccccc-cccc-cccc-cccc-cccccccccccc"
        let workspaceId = UUID()
        let panelId = UUID()
        try writeTranscript(
            sessionId: sessionId,
            at: fixture.projectsDir
                .appendingPathComponent("-tmp-started-here", isDirectory: true)
                .appendingPathComponent("\(sessionId).jsonl")
        )
        try writeHookStore(root: fixture.root, sessions: [
            sessionId: record(
                sessionId: sessionId,
                workspaceId: workspaceId,
                panelId: panelId,
                cwd: fixture.root.appendingPathComponent("moved-here").path,
                configDir: fixture.configDir
            ),
        ])

        let fm = ProjectsProbeCountingFileManager(projectsMarker: fixture.projectsMarker)
        let index = RestorableAgentSessionIndex.load(homeDirectory: fixture.root.path, fileManager: fm)

        #expect(index.snapshot(workspaceId: workspaceId, panelId: panelId)?.sessionId == sessionId)
    }

    @Test
    func nestedTranscriptInAnotherProjectFolderStillRestoresTheSession() throws {
        let fixture = try makeFixture("cmux-claude-scan-nested")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try makeUnrelatedProjectFolders(5, in: fixture.projectsDir)

        let sessionId = "dddddddd-dddd-dddd-dddd-dddddddddddd"
        let workspaceId = UUID()
        let panelId = UUID()
        try writeTranscript(
            sessionId: sessionId,
            at: fixture.projectsDir
                .appendingPathComponent("-tmp-started-here", isDirectory: true)
                .appendingPathComponent(sessionId, isDirectory: true)
                .appendingPathComponent("messages", isDirectory: true)
                .appendingPathComponent("\(sessionId).jsonl")
        )
        try writeHookStore(root: fixture.root, sessions: [
            sessionId: record(
                sessionId: sessionId,
                workspaceId: workspaceId,
                panelId: panelId,
                cwd: fixture.root.appendingPathComponent("moved-here").path,
                configDir: fixture.configDir
            ),
        ])

        let fm = ProjectsProbeCountingFileManager(projectsMarker: fixture.projectsMarker)
        let index = RestorableAgentSessionIndex.load(homeDirectory: fixture.root.path, fileManager: fm)

        #expect(index.snapshot(workspaceId: workspaceId, panelId: panelId)?.sessionId == sessionId)
    }

    @Test
    func transcriptInASymlinkedProjectFolderStillRestoresTheSession() throws {
        let fixture = try makeFixture("cmux-claude-scan-symlink")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let sessionId = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
        let workspaceId = UUID()
        let panelId = UUID()
        let realFolder = fixture.root.appendingPathComponent("elsewhere", isDirectory: true)
        try writeTranscript(sessionId: sessionId, at: realFolder.appendingPathComponent("\(sessionId).jsonl"))
        try FileManager.default.createSymbolicLink(
            at: fixture.projectsDir.appendingPathComponent("-tmp-linked"),
            withDestinationURL: realFolder
        )
        try writeHookStore(root: fixture.root, sessions: [
            sessionId: record(
                sessionId: sessionId,
                workspaceId: workspaceId,
                panelId: panelId,
                cwd: fixture.root.appendingPathComponent("moved-here").path,
                configDir: fixture.configDir
            ),
        ])

        let fm = ProjectsProbeCountingFileManager(projectsMarker: fixture.projectsMarker)
        let index = RestorableAgentSessionIndex.load(homeDirectory: fixture.root.path, fileManager: fm)

        #expect(index.snapshot(workspaceId: workspaceId, panelId: panelId)?.sessionId == sessionId)
    }

    /// A workflow session's folder is named after the session and has no
    /// transcript of its own. The session to resume is the one transcript
    /// beside it, also when both sit in a folder other than the cwd's.
    @Test
    func workflowFolderInAnotherProjectFolderStillResolvesToItsSiblingTranscript() throws {
        let fixture = try makeFixture("cmux-claude-scan-workflow")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try makeUnrelatedProjectFolders(5, in: fixture.projectsDir)

        let workflowSessionId = "aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa"
        let resumableSessionId = "bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb"
        let workspaceId = UUID()
        let panelId = UUID()
        let startedHere = fixture.projectsDir.appendingPathComponent("-tmp-started-here", isDirectory: true)
        let workflowFolder = startedHere.appendingPathComponent(workflowSessionId, isDirectory: true)
        try FileManager.default.createDirectory(
            at: workflowFolder.appendingPathComponent("subagents", isDirectory: true),
            withIntermediateDirectories: true
        )
        try writeTranscript(
            sessionId: resumableSessionId,
            at: startedHere.appendingPathComponent("\(resumableSessionId).jsonl")
        )
        var workflowRecord = record(
            sessionId: workflowSessionId,
            workspaceId: workspaceId,
            panelId: panelId,
            cwd: fixture.root.appendingPathComponent("moved-here").path,
            configDir: fixture.configDir
        )
        workflowRecord["transcriptPath"] = workflowFolder.path
        workflowRecord["isRestorable"] = true
        try writeHookStore(root: fixture.root, sessions: [workflowSessionId: workflowRecord])

        let fm = ProjectsProbeCountingFileManager(projectsMarker: fixture.projectsMarker)
        let index = RestorableAgentSessionIndex.load(homeDirectory: fixture.root.path, fileManager: fm)

        #expect(index.snapshot(workspaceId: workspaceId, panelId: panelId)?.sessionId == resumableSessionId)
    }

    /// The default file manager keeps its answers between loads, keyed by each
    /// folder's modification time. A transcript that shows up in another folder
    /// later must still be found.
    @Test
    func transcriptCreatedInAnotherProjectFolderIsFoundOnTheNextLoad() throws {
        let fixture = try makeFixture("cmux-claude-scan-later")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try makeUnrelatedProjectFolders(3, in: fixture.projectsDir)

        let sessionId = "ffffffff-ffff-ffff-ffff-ffffffffffff"
        let workspaceId = UUID()
        let panelId = UUID()
        let startedHere = fixture.projectsDir.appendingPathComponent("-tmp-started-here", isDirectory: true)
        try FileManager.default.createDirectory(at: startedHere, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000)],
            ofItemAtPath: startedHere.path
        )
        try writeHookStore(root: fixture.root, sessions: [
            sessionId: record(
                sessionId: sessionId,
                workspaceId: workspaceId,
                panelId: panelId,
                cwd: fixture.root.appendingPathComponent("moved-here").path,
                configDir: fixture.configDir
            ),
        ])

        let first = RestorableAgentSessionIndex.load(homeDirectory: fixture.root.path, fileManager: .default)
        #expect(first.snapshot(workspaceId: workspaceId, panelId: panelId) == nil)

        try writeTranscript(sessionId: sessionId, at: startedHere.appendingPathComponent("\(sessionId).jsonl"))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000)],
            ofItemAtPath: startedHere.path
        )
        let second = RestorableAgentSessionIndex.load(homeDirectory: fixture.root.path, fileManager: .default)
        #expect(second.snapshot(workspaceId: workspaceId, panelId: panelId)?.sessionId == sessionId)
    }
}
