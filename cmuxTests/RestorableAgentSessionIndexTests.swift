import CMUXAgentLaunch
import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class RestorableAgentSessionIndexTests: XCTestCase {
    func testClaudeHookSnapshotRequiresTranscriptFile() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-claude-restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let configDir = root.appendingPathComponent("claude-config", isDirectory: true)
        let projectsDir = configDir.appendingPathComponent("projects", isDirectory: true)
        let cwd = root.appendingPathComponent("repo", isDirectory: true)
        try fm.createDirectory(at: cwd, withIntermediateDirectories: true)
        try fm.createDirectory(
            at: projectsDir.appendingPathComponent(
                RestorableAgentSessionIndex.encodeClaudeProjectDir(cwd.path),
                isDirectory: true
            ),
            withIntermediateDirectories: true
        )

        let validSessionId = "11111111-1111-1111-1111-111111111111"
        let missingSessionId = "22222222-2222-2222-2222-222222222222"
        let startupOnlyWithTranscriptSessionId = "33333333-3333-3333-3333-333333333333"
        let startupOnlyMissingSessionId = "44444444-4444-4444-4444-444444444444"
        let explicitTranscriptSessionId = "55555555-5555-5555-5555-555555555555"
        let validWorkspaceId = UUID()
        let validPanelId = UUID()
        let missingWorkspaceId = UUID()
        let missingPanelId = UUID()
        let startupOnlyWithTranscriptWorkspaceId = UUID()
        let startupOnlyWithTranscriptPanelId = UUID()
        let startupOnlyMissingWorkspaceId = UUID()
        let startupOnlyMissingPanelId = UUID()
        let explicitTranscriptWorkspaceId = UUID()
        let explicitTranscriptPanelId = UUID()

        try writeClaudeTranscript(sessionId: validSessionId, cwd: cwd, projectsDir: projectsDir)
        try writeClaudeTranscript(sessionId: startupOnlyWithTranscriptSessionId, cwd: cwd, projectsDir: projectsDir)
        let explicitTranscriptURL = root
            .appendingPathComponent("other-transcripts", isDirectory: true)
            .appendingPathComponent("\(explicitTranscriptSessionId).jsonl", isDirectory: false)
        try fm.createDirectory(
            at: explicitTranscriptURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeClaudeTranscript(sessionId: explicitTranscriptSessionId, transcriptURL: explicitTranscriptURL, cwd: cwd)

        try writeClaudeHookStore(
            root: root,
            sessions: [
                validSessionId: hookRecord(
                    sessionId: validSessionId,
                    workspaceId: validWorkspaceId,
                    panelId: validPanelId,
                    cwd: cwd.path,
                    configDir: configDir.path,
                    updatedAt: 20
                ),
                missingSessionId: hookRecord(
                    sessionId: missingSessionId,
                    workspaceId: missingWorkspaceId,
                    panelId: missingPanelId,
                    cwd: cwd.path,
                    configDir: configDir.path,
                    updatedAt: 30
                ),
                startupOnlyWithTranscriptSessionId: hookRecord(
                    sessionId: startupOnlyWithTranscriptSessionId,
                    workspaceId: startupOnlyWithTranscriptWorkspaceId,
                    panelId: startupOnlyWithTranscriptPanelId,
                    cwd: cwd.path,
                    configDir: configDir.path,
                    isRestorable: false,
                    updatedAt: 40
                ),
                startupOnlyMissingSessionId: hookRecord(
                    sessionId: startupOnlyMissingSessionId,
                    workspaceId: startupOnlyMissingWorkspaceId,
                    panelId: startupOnlyMissingPanelId,
                    cwd: cwd.path,
                    configDir: configDir.path,
                    isRestorable: false,
                    updatedAt: 50
                ),
                explicitTranscriptSessionId: hookRecord(
                    sessionId: explicitTranscriptSessionId,
                    workspaceId: explicitTranscriptWorkspaceId,
                    panelId: explicitTranscriptPanelId,
                    cwd: root.appendingPathComponent("different-cwd", isDirectory: true).path,
                    configDir: root.appendingPathComponent("different-config", isDirectory: true).path,
                    transcriptPath: explicitTranscriptURL.path,
                    isRestorable: false,
                    updatedAt: 60
                ),
            ]
        )

        let index = RestorableAgentSessionIndex.load(
            homeDirectory: root.path,
            fileManager: fm
        )

        XCTAssertEqual(
            index.snapshot(workspaceId: validWorkspaceId, panelId: validPanelId)?.sessionId,
            validSessionId
        )
        XCTAssertNil(
            index.snapshot(workspaceId: missingWorkspaceId, panelId: missingPanelId),
            "A Claude SessionStart without a transcript file must not be auto-restored because Claude cannot resume it."
        )
        XCTAssertEqual(
            index.snapshot(
                workspaceId: startupOnlyWithTranscriptWorkspaceId,
                panelId: startupOnlyWithTranscriptPanelId
            )?.sessionId,
            startupOnlyWithTranscriptSessionId,
            "A transcript-backed Claude session remains restorable even before a new turn is observed in this process."
        )
        XCTAssertNil(
            index.snapshot(workspaceId: startupOnlyMissingWorkspaceId, panelId: startupOnlyMissingPanelId),
            "A startup-only Claude hook record without a transcript must stay non-restorable."
        )
        XCTAssertEqual(
            index.snapshot(workspaceId: explicitTranscriptWorkspaceId, panelId: explicitTranscriptPanelId)?.sessionId,
            explicitTranscriptSessionId,
            "When Claude provides transcript_path, restore eligibility should use that exact file before reconstructing from cwd."
        )
    }

    func testClaudeTranscriptCreatedAfterAbsentLoadInvalidatesSharedLookup() throws {
        let fm = FileManager.default
        let sessionId = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        let fixture = try makeClaudeTranscriptCacheFixture(
            prefix: "cmux-claude-cache-create",
            sessionId: sessionId
        )
        defer { try? fm.removeItem(at: fixture.root) }

        try setDirectoryModificationDate(Date(timeIntervalSince1970: 1_000), for: fixture.projectDir)
        let firstIndex = RestorableAgentSessionIndex.load(homeDirectory: fixture.root.path, fileManager: fm)
        XCTAssertNil(
            firstIndex.snapshot(workspaceId: fixture.workspaceId, panelId: fixture.panelId),
            "The first load should cache the missing transcript as absent."
        )

        try writeClaudeTranscript(sessionId: sessionId, transcriptURL: fixture.transcriptURL, cwd: fixture.cwd)
        try setDirectoryModificationDate(Date(timeIntervalSince1970: 2_000), for: fixture.projectDir)
        let secondIndex = RestorableAgentSessionIndex.load(homeDirectory: fixture.root.path, fileManager: fm)

        XCTAssertEqual(
            secondIndex.snapshot(workspaceId: fixture.workspaceId, panelId: fixture.panelId)?.sessionId,
            sessionId,
            "Changing the project directory mtime must invalidate the shared negative lookup."
        )
    }

    func testClaudeTranscriptDeletedBetweenLoadsInvalidatesSharedLookup() throws {
        let fm = FileManager.default
        let sessionId = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        let fixture = try makeClaudeTranscriptCacheFixture(
            prefix: "cmux-claude-cache-delete",
            sessionId: sessionId
        )
        defer { try? fm.removeItem(at: fixture.root) }

        try writeClaudeTranscript(sessionId: sessionId, transcriptURL: fixture.transcriptURL, cwd: fixture.cwd)
        try setDirectoryModificationDate(Date(timeIntervalSince1970: 3_000), for: fixture.projectDir)
        let firstIndex = RestorableAgentSessionIndex.load(homeDirectory: fixture.root.path, fileManager: fm)
        XCTAssertEqual(firstIndex.snapshot(workspaceId: fixture.workspaceId, panelId: fixture.panelId)?.sessionId, sessionId)

        try fm.removeItem(at: fixture.transcriptURL)
        try setDirectoryModificationDate(Date(timeIntervalSince1970: 4_000), for: fixture.projectDir)
        let secondIndex = RestorableAgentSessionIndex.load(homeDirectory: fixture.root.path, fileManager: fm)

        XCTAssertNil(
            secondIndex.snapshot(workspaceId: fixture.workspaceId, panelId: fixture.panelId),
            "Changing the project directory mtime must invalidate the shared positive lookup."
        )
    }

    func testClaudeTranscriptLookupIsStableAcrossUnchangedLoads() throws {
        let fm = FileManager.default
        let sessionId = "cccccccc-cccc-cccc-cccc-cccccccccccc"
        let fixture = try makeClaudeTranscriptCacheFixture(
            prefix: "cmux-claude-cache-stable",
            sessionId: sessionId
        )
        defer { try? fm.removeItem(at: fixture.root) }

        try writeClaudeTranscript(sessionId: sessionId, transcriptURL: fixture.transcriptURL, cwd: fixture.cwd)
        try setDirectoryModificationDate(Date(timeIntervalSince1970: 5_000), for: fixture.projectDir)

        let firstSnapshot = try XCTUnwrap(
            RestorableAgentSessionIndex.load(homeDirectory: fixture.root.path, fileManager: fm)
                .snapshot(workspaceId: fixture.workspaceId, panelId: fixture.panelId)
        )
        let secondSnapshot = try XCTUnwrap(
            RestorableAgentSessionIndex.load(homeDirectory: fixture.root.path, fileManager: fm)
                .snapshot(workspaceId: fixture.workspaceId, panelId: fixture.panelId)
        )

        XCTAssertEqual(secondSnapshot.kind, firstSnapshot.kind)
        XCTAssertEqual(secondSnapshot.sessionId, firstSnapshot.sessionId)
        XCTAssertEqual(secondSnapshot.workingDirectory, firstSnapshot.workingDirectory)
        XCTAssertEqual(secondSnapshot.resumeCommand, firstSnapshot.resumeCommand)
    }

    func testClaudeZeroByteTranscriptIsRecheckedOnNextLoad() throws {
        let fm = FileManager.default
        let sessionId = "dddddddd-dddd-dddd-dddd-dddddddddddd"
        let fixture = try makeClaudeTranscriptCacheFixture(
            prefix: "cmux-claude-cache-empty-file",
            sessionId: sessionId
        )
        defer { try? fm.removeItem(at: fixture.root) }

        XCTAssertTrue(fm.createFile(atPath: fixture.transcriptURL.path, contents: Data()))
        let unchangedDirectoryDate = Date(timeIntervalSince1970: 6_000)
        try setDirectoryModificationDate(unchangedDirectoryDate, for: fixture.projectDir)
        let firstIndex = RestorableAgentSessionIndex.load(homeDirectory: fixture.root.path, fileManager: fm)
        XCTAssertNil(
            firstIndex.snapshot(workspaceId: fixture.workspaceId, panelId: fixture.panelId),
            "A zero-byte transcript should not make the Claude session restorable."
        )

        try writeClaudeTranscript(sessionId: sessionId, transcriptURL: fixture.transcriptURL, cwd: fixture.cwd)
        try setDirectoryModificationDate(unchangedDirectoryDate, for: fixture.projectDir)
        let secondIndex = RestorableAgentSessionIndex.load(homeDirectory: fixture.root.path, fileManager: fm)

        XCTAssertEqual(
            secondIndex.snapshot(workspaceId: fixture.workspaceId, panelId: fixture.panelId)?.sessionId,
            sessionId,
            "Zero-byte negatives must be rechecked even when the directory mtime is unchanged."
        )
    }

    func testClaudeNestedTranscriptCreatedWithoutProjectRootMtimeChangeIsFound() throws {
        let fm = FileManager.default
        let sessionId = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
        let fixture = try makeClaudeTranscriptCacheFixture(
            prefix: "cmux-claude-cache-nested-create",
            sessionId: sessionId
        )
        defer { try? fm.removeItem(at: fixture.root) }

        // Pre-create the nested `<sessionId>/messages/` layout so writing the transcript
        // later only bumps the inner directory's mtime, never the project root's.
        let messagesDir = fixture.projectDir
            .appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
        try fm.createDirectory(at: messagesDir, withIntermediateDirectories: true)
        let nestedTranscriptURL = messagesDir.appendingPathComponent("\(sessionId).jsonl", isDirectory: false)

        let pinnedDirectoryDate = Date(timeIntervalSince1970: 7_000)
        try setDirectoryModificationDate(pinnedDirectoryDate, for: fixture.projectDir)
        let firstIndex = RestorableAgentSessionIndex.load(homeDirectory: fixture.root.path, fileManager: fm)
        XCTAssertNil(
            firstIndex.snapshot(workspaceId: fixture.workspaceId, panelId: fixture.panelId),
            "The first load should see no transcript for the session."
        )

        try writeClaudeTranscript(sessionId: sessionId, transcriptURL: nestedTranscriptURL, cwd: fixture.cwd)
        try setDirectoryModificationDate(pinnedDirectoryDate, for: fixture.projectDir)
        let secondIndex = RestorableAgentSessionIndex.load(homeDirectory: fixture.root.path, fileManager: fm)

        XCTAssertEqual(
            secondIndex.snapshot(workspaceId: fixture.workspaceId, panelId: fixture.panelId)?.sessionId,
            sessionId,
            "A nested messages/ transcript must be found even when the project root mtime is unchanged."
        )
    }

    func testClaudeNestedTranscriptDeletedWithoutProjectRootMtimeChangeStopsResolving() throws {
        let fm = FileManager.default
        let sessionId = "ffffffff-ffff-ffff-ffff-ffffffffffff"
        let fixture = try makeClaudeTranscriptCacheFixture(
            prefix: "cmux-claude-cache-nested-delete",
            sessionId: sessionId
        )
        defer { try? fm.removeItem(at: fixture.root) }

        let messagesDir = fixture.projectDir
            .appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent("messages", isDirectory: true)
        try fm.createDirectory(at: messagesDir, withIntermediateDirectories: true)
        let nestedTranscriptURL = messagesDir.appendingPathComponent("\(sessionId).jsonl", isDirectory: false)
        try writeClaudeTranscript(sessionId: sessionId, transcriptURL: nestedTranscriptURL, cwd: fixture.cwd)

        let pinnedDirectoryDate = Date(timeIntervalSince1970: 8_000)
        try setDirectoryModificationDate(pinnedDirectoryDate, for: fixture.projectDir)
        let firstIndex = RestorableAgentSessionIndex.load(homeDirectory: fixture.root.path, fileManager: fm)
        XCTAssertEqual(
            firstIndex.snapshot(workspaceId: fixture.workspaceId, panelId: fixture.panelId)?.sessionId,
            sessionId
        )

        try fm.removeItem(at: nestedTranscriptURL)
        try setDirectoryModificationDate(pinnedDirectoryDate, for: fixture.projectDir)
        let secondIndex = RestorableAgentSessionIndex.load(homeDirectory: fixture.root.path, fileManager: fm)

        XCTAssertNil(
            secondIndex.snapshot(workspaceId: fixture.workspaceId, panelId: fixture.panelId),
            "Deleting a nested messages/ transcript must stop resolving even when the project root mtime is unchanged."
        )
    }

    func testPanelFallbackUsesLatestHookRecord() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-claude-panel-fallback-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let configDir = root.appendingPathComponent("claude-config", isDirectory: true)
        let projectsDir = configDir.appendingPathComponent("projects", isDirectory: true)
        let cwd = root.appendingPathComponent("repo", isDirectory: true)
        try fm.createDirectory(at: cwd, withIntermediateDirectories: true)
        try fm.createDirectory(
            at: projectsDir.appendingPathComponent(
                RestorableAgentSessionIndex.encodeClaudeProjectDir(cwd.path),
                isDirectory: true
            ),
            withIntermediateDirectories: true
        )

        let panelId = UUID()
        let oldWorkspaceId = UUID()
        let latestWorkspaceId = UUID()
        let movedWorkspaceId = UUID()
        let oldSessionId = "11111111-1111-1111-1111-111111111111"
        let latestSessionId = "22222222-2222-2222-2222-222222222222"
        try writeClaudeTranscript(sessionId: oldSessionId, cwd: cwd, projectsDir: projectsDir)
        try writeClaudeTranscript(sessionId: latestSessionId, cwd: cwd, projectsDir: projectsDir)

        try writeClaudeHookStore(
            root: root,
            sessions: [
                oldSessionId: hookRecord(
                    sessionId: oldSessionId,
                    workspaceId: oldWorkspaceId,
                    panelId: panelId,
                    cwd: cwd.path,
                    configDir: configDir.path,
                    updatedAt: 10
                ),
                latestSessionId: hookRecord(
                    sessionId: latestSessionId,
                    workspaceId: latestWorkspaceId,
                    panelId: panelId,
                    cwd: cwd.path,
                    configDir: configDir.path,
                    updatedAt: 20
                ),
            ]
        )

        let index = RestorableAgentSessionIndex.load(
            homeDirectory: root.path,
            fileManager: fm
        )

        XCTAssertEqual(
            index.snapshot(workspaceId: oldWorkspaceId, panelId: panelId)?.sessionId,
            oldSessionId
        )
        XCTAssertEqual(
            index.snapshot(workspaceId: movedWorkspaceId, panelId: panelId)?.sessionId,
            latestSessionId
        )
    }

    // A Claude session can start in one directory and `cd` into another (e.g. a repo root then a
    // worktree); the hook-reported `cwd` drifts to the latter, but Claude keeps the transcript in
    // the start directory's project folder. Fork/resume must cd into the directory that actually
    // holds the transcript, otherwise `claude --resume` fails with "No conversation found".
    //
    // The launch path contains a "." so this also exercises encodeClaudeProjectDir's "." -> "-"
    // contract, and the on-disk fixture is placed using a project-dir name computed independently of
    // the production helper so a regression in that helper fails the test instead of being masked.
    func testClaudeForkResolvesDriftedCwdViaTranscriptPath() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-claude-fork-drift-path-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let configDir = root.appendingPathComponent("claude-config", isDirectory: true)
        let projectsDir = configDir.appendingPathComponent("projects", isDirectory: true)
        let launchCwd = root.appendingPathComponent("repo.main", isDirectory: true)
        let driftedCwd = root.appendingPathComponent("worktree", isDirectory: true)
        try fm.createDirectory(at: launchCwd, withIntermediateDirectories: true)
        try fm.createDirectory(at: driftedCwd, withIntermediateDirectories: true)
        let projectDir = projectsDir.appendingPathComponent(
            expectedClaudeProjectDirName(launchCwd.path),
            isDirectory: true
        )
        try fm.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let sessionId = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        let workspaceId = UUID()
        let panelId = UUID()
        let transcriptURL = projectDir.appendingPathComponent("\(sessionId).jsonl", isDirectory: false)
        try writeClaudeTranscript(sessionId: sessionId, transcriptURL: transcriptURL, cwd: launchCwd)

        try writeClaudeHookStore(
            root: root,
            sessions: [
                sessionId: driftedHookRecord(
                    sessionId: sessionId,
                    workspaceId: workspaceId,
                    panelId: panelId,
                    recordedCwd: driftedCwd.path,
                    launchCwd: launchCwd.path,
                    configDir: configDir.path,
                    transcriptPath: transcriptURL.path,
                    updatedAt: 10
                ),
            ]
        )

        let index = RestorableAgentSessionIndex.load(homeDirectory: root.path, fileManager: fm)
        let snapshot = try XCTUnwrap(index.snapshot(workspaceId: workspaceId, panelId: panelId))

        XCTAssertEqual(snapshot.workingDirectory, launchCwd.path)
        let forkCommand = try XCTUnwrap(snapshot.forkCommand)
        XCTAssertTrue(
            forkCommand.contains("cd -- '\(launchCwd.path)'"),
            "fork should cd into the transcript's directory; got: \(forkCommand)"
        )
        XCTAssertFalse(
            forkCommand.contains(driftedCwd.path),
            "fork must not cd into the drifted cwd; got: \(forkCommand)"
        )
    }

    // Same drift, but the record carries no explicit transcriptPath: resolution must still find the
    // correct directory by probing the Claude config directory on disk.
    func testClaudeForkResolvesDriftedCwdViaConfigScanWhenTranscriptPathMissing() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-claude-fork-drift-scan-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let configDir = root.appendingPathComponent("claude-config", isDirectory: true)
        let projectsDir = configDir.appendingPathComponent("projects", isDirectory: true)
        let launchCwd = root.appendingPathComponent("repo.main", isDirectory: true)
        let driftedCwd = root.appendingPathComponent("worktree", isDirectory: true)
        try fm.createDirectory(at: launchCwd, withIntermediateDirectories: true)
        try fm.createDirectory(at: driftedCwd, withIntermediateDirectories: true)
        let projectDir = projectsDir.appendingPathComponent(
            expectedClaudeProjectDirName(launchCwd.path),
            isDirectory: true
        )
        try fm.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let sessionId = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
        let workspaceId = UUID()
        let panelId = UUID()
        let transcriptURL = projectDir.appendingPathComponent("\(sessionId).jsonl", isDirectory: false)
        try writeClaudeTranscript(sessionId: sessionId, transcriptURL: transcriptURL, cwd: launchCwd)

        try writeClaudeHookStore(
            root: root,
            sessions: [
                sessionId: driftedHookRecord(
                    sessionId: sessionId,
                    workspaceId: workspaceId,
                    panelId: panelId,
                    recordedCwd: driftedCwd.path,
                    launchCwd: launchCwd.path,
                    configDir: configDir.path,
                    transcriptPath: nil,
                    updatedAt: 10
                ),
            ]
        )

        let index = RestorableAgentSessionIndex.load(homeDirectory: root.path, fileManager: fm)
        let snapshot = try XCTUnwrap(index.snapshot(workspaceId: workspaceId, panelId: panelId))

        XCTAssertEqual(snapshot.workingDirectory, launchCwd.path)
    }

    // The transcript exists but its project directory encodes to neither the launch cwd nor the
    // drifted cwd (an out-of-tree transcript_path), and the config dir holds no matching project
    // folder, so neither verifier can confirm a candidate. Resolution must still prefer the launch
    // cwd (the session namespace) over the drift-prone recorded cwd, instead of falling back to the
    // drift. This is the exact shape that made a build *with* the #5154 fix still fail to resume.
    func testClaudeResumePrefersLaunchCwdWhenTranscriptUnverifiable() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-claude-fallback-prefers-launch-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let configDir = root.appendingPathComponent("claude-config", isDirectory: true)
        try fm.createDirectory(
            at: configDir.appendingPathComponent("projects", isDirectory: true),
            withIntermediateDirectories: true
        )
        let launchCwd = root.appendingPathComponent("repo-main", isDirectory: true)
        let driftedCwd = root.appendingPathComponent("worktree", isDirectory: true)
        try fm.createDirectory(at: launchCwd, withIntermediateDirectories: true)
        try fm.createDirectory(at: driftedCwd, withIntermediateDirectories: true)

        // A real transcript whose parent directory name encodes to neither candidate.
        let sessionId = "cccccccc-cccc-cccc-cccc-cccccccccccc"
        let outOfTreeDir = root.appendingPathComponent("elsewhere", isDirectory: true)
        try fm.createDirectory(at: outOfTreeDir, withIntermediateDirectories: true)
        let transcriptURL = outOfTreeDir.appendingPathComponent("\(sessionId).jsonl", isDirectory: false)
        try writeClaudeTranscript(sessionId: sessionId, transcriptURL: transcriptURL, cwd: launchCwd)

        let workspaceId = UUID()
        let panelId = UUID()
        try writeClaudeHookStore(
            root: root,
            sessions: [
                sessionId: driftedHookRecord(
                    sessionId: sessionId,
                    workspaceId: workspaceId,
                    panelId: panelId,
                    recordedCwd: driftedCwd.path,
                    launchCwd: launchCwd.path,
                    configDir: configDir.path,
                    transcriptPath: transcriptURL.path,
                    updatedAt: 10
                ),
            ]
        )

        let index = RestorableAgentSessionIndex.load(homeDirectory: root.path, fileManager: fm)
        let snapshot = try XCTUnwrap(index.snapshot(workspaceId: workspaceId, panelId: panelId))

        XCTAssertEqual(snapshot.workingDirectory, launchCwd.path)
        let resumeCommand = try XCTUnwrap(snapshot.resumeCommand)
        XCTAssertTrue(
            resumeCommand.contains("cd -- '\(launchCwd.path)'"),
            "resume must cd into the launch cwd; got: \(resumeCommand)"
        )
        XCTAssertFalse(
            resumeCommand.contains(driftedCwd.path),
            "resume must not cd into the drifted cwd; got: \(resumeCommand)"
        )
    }

    // A directory-namespaced non-Claude agent (Gemini files its session under the launch cwd) whose
    // hook-reported cwd drifted into a subdirectory must still resume from the launch cwd. Before
    // the fix the resolver short-circuited every non-Claude kind straight to the drifted recorded
    // cwd via `guard kind == .claude else { return recordedCwd }`.
    func testDirectoryNamespacedNonClaudeAgentResolvesDriftToLaunchCwd() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-gemini-drift-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let launchCwd = root.appendingPathComponent("repo-main", isDirectory: true)
        let driftedCwd = root.appendingPathComponent("worktree", isDirectory: true)
        try fm.createDirectory(at: launchCwd, withIntermediateDirectories: true)
        try fm.createDirectory(at: driftedCwd, withIntermediateDirectories: true)

        let sessionId = "dddddddd-dddd-dddd-dddd-dddddddddddd"
        let workspaceId = UUID()
        let panelId = UUID()
        try writeHookStore(
            root: root,
            storeFilename: "gemini-hook-sessions.json",
            sessions: [
                sessionId: driftedAgentHookRecord(
                    launcher: "gemini",
                    sessionId: sessionId,
                    workspaceId: workspaceId,
                    panelId: panelId,
                    recordedCwd: driftedCwd.path,
                    launchCwd: launchCwd.path,
                    updatedAt: 10
                ),
            ]
        )

        let index = RestorableAgentSessionIndex.load(homeDirectory: root.path, fileManager: fm)
        let snapshot = try XCTUnwrap(index.snapshot(workspaceId: workspaceId, panelId: panelId))

        XCTAssertEqual(snapshot.kind, .gemini)
        XCTAssertEqual(snapshot.workingDirectory, launchCwd.path)
        let resumeCommand = try XCTUnwrap(snapshot.resumeCommand)
        XCTAssertTrue(
            resumeCommand.contains("cd -- '\(launchCwd.path)'"),
            "resume must cd into the launch cwd; got: \(resumeCommand)"
        )
        XCTAssertFalse(
            resumeCommand.contains(driftedCwd.path),
            "resume must not cd into the drifted cwd; got: \(resumeCommand)"
        )
    }

    func testPiDetectedLatestSessionDoesNotCollapseExactHookRecordsAcrossPanels() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-pi-restore-collapse-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let cwd = root.appendingPathComponent("repo", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("pi-sessions", isDirectory: true)
        let projectDirectory = try XCTUnwrap(PiSessionLocator.projectDirectoryName(for: cwd.path))
        let projectSessions = sessionsRoot.appendingPathComponent(projectDirectory, isDirectory: true)
        try fm.createDirectory(at: cwd, withIntermediateDirectories: true)
        try fm.createDirectory(at: projectSessions, withIntermediateDirectories: true)

        var registration = CmuxVaultAgentRegistration.builtInPi
        registration.sessionDirectory = sessionsRoot.path
        let registry = CmuxVaultAgentRegistry(registrations: [registration])
        let workspaceId = UUID()
        let panels = [UUID(), UUID(), UUID()]
        let sessionIds = ["pi-session-a", "pi-session-b", "pi-session-c"]
        var hookSessions: [String: [String: Any]] = [:]
        for (index, sessionId) in sessionIds.enumerated() {
            let sessionFile = projectSessions.appendingPathComponent("\(sessionId).jsonl", isDirectory: false)
            try "{}\n".write(to: sessionFile, atomically: true, encoding: .utf8)
            try fm.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: TimeInterval(1_000 + index))],
                ofItemAtPath: sessionFile.path
            )
            hookSessions[sessionId] = driftedAgentHookRecord(
                launcher: "pi",
                sessionId: sessionId,
                workspaceId: workspaceId,
                panelId: panels[index],
                recordedCwd: cwd.path,
                launchCwd: cwd.path,
                updatedAt: TimeInterval(10 + index)
            )
        }
        try writeHookStore(root: root, storeFilename: "pi-hook-sessions.json", sessions: hookSessions)

        let processes = panels.enumerated().map { index, panelId in
            CmuxTopProcessInfo(
                pid: 4_200 + index,
                parentPID: 1,
                name: "pi",
                path: "/usr/local/bin/pi",
                ttyDevice: nil,
                cmuxWorkspaceID: workspaceId,
                cmuxSurfaceID: panelId,
                cmuxAttributionReason: "cmux-test",
                processGroupID: nil,
                terminalProcessGroupID: nil,
                cpuPercent: 0,
                residentBytes: 0,
                virtualBytes: 0,
                threadCount: 1
            )
        }
        let processSnapshot = CmuxTopProcessSnapshot(
            processes: processes,
            sampledAt: Date(timeIntervalSince1970: 0),
            includesProcessDetails: true
        )
        let detectedSnapshots = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: registry,
            fileManager: fm,
            processSnapshot: processSnapshot,
            capturedAt: 42,
            processArgumentsProvider: { processId in
                guard processes.contains(where: { $0.pid == processId }) else { return nil }
                return CmuxTopProcessArguments(
                    arguments: ["/usr/local/bin/pi"],
                    environment: [
                        "PWD": cwd.path,
                        "PI_CODING_AGENT_SESSION_DIR": sessionsRoot.path,
                    ]
                )
            }
        )

        let detectedSessionIds = Set(detectedSnapshots.values.map { $0.snapshot.sessionId })
        XCTAssertEqual(detectedSessionIds.count, 1, "Pi latest-file detection is ambiguous for same-cwd panels")

        let index = RestorableAgentSessionIndex.load(
            homeDirectory: root.path,
            fileManager: fm,
            registry: registry,
            detectedSnapshots: detectedSnapshots,
            processArgumentsProvider: { _ in nil }
        )
        let restoredSessionIds = try panels.map { panelId in
            try XCTUnwrap(index.snapshot(workspaceId: workspaceId, panelId: panelId)).sessionId
        }

        XCTAssertEqual(restoredSessionIds, sessionIds)
    }

    func testPiDetectedLatestSessionDoesNotCollapseExactHookRecordsAfterWorkspaceIdRotation() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-pi-restore-workspace-rotation-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let cwd = root.appendingPathComponent("repo", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("pi-sessions", isDirectory: true)
        let projectDirectory = try XCTUnwrap(PiSessionLocator.projectDirectoryName(for: cwd.path))
        let projectSessions = sessionsRoot.appendingPathComponent(projectDirectory, isDirectory: true)
        try fm.createDirectory(at: cwd, withIntermediateDirectories: true)
        try fm.createDirectory(at: projectSessions, withIntermediateDirectories: true)

        var registration = CmuxVaultAgentRegistration.builtInPi
        registration.sessionDirectory = sessionsRoot.path
        let registry = CmuxVaultAgentRegistry(registrations: [registration])
        let oldWorkspaceIds = [UUID(), UUID(), UUID()]
        let restoredWorkspaceIds = [UUID(), UUID(), UUID()]
        let panels = [UUID(), UUID(), UUID()]
        let sessionIds = ["pi-session-a", "pi-session-b", "pi-session-c"]
        var hookSessions: [String: [String: Any]] = [:]
        for (index, sessionId) in sessionIds.enumerated() {
            let sessionFile = projectSessions.appendingPathComponent("\(sessionId).jsonl", isDirectory: false)
            try "{}\n".write(to: sessionFile, atomically: true, encoding: .utf8)
            try fm.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: TimeInterval(1_000 + index))],
                ofItemAtPath: sessionFile.path
            )
            hookSessions[sessionId] = driftedAgentHookRecord(
                launcher: "pi",
                sessionId: sessionId,
                workspaceId: oldWorkspaceIds[index],
                panelId: panels[index],
                recordedCwd: cwd.path,
                launchCwd: cwd.path,
                updatedAt: TimeInterval(10 + index)
            )
        }
        try writeHookStore(root: root, storeFilename: "pi-hook-sessions.json", sessions: hookSessions)

        let processes = panels.enumerated().map { index, panelId in
            CmuxTopProcessInfo(
                pid: 4_300 + index,
                parentPID: 1,
                name: "pi",
                path: "/usr/local/bin/pi",
                ttyDevice: nil,
                cmuxWorkspaceID: restoredWorkspaceIds[index],
                cmuxSurfaceID: panelId,
                cmuxAttributionReason: "cmux-test",
                processGroupID: nil,
                terminalProcessGroupID: nil,
                cpuPercent: 0,
                residentBytes: 0,
                virtualBytes: 0,
                threadCount: 1
            )
        }
        let processSnapshot = CmuxTopProcessSnapshot(
            processes: processes,
            sampledAt: Date(timeIntervalSince1970: 0),
            includesProcessDetails: true
        )
        let detectedSnapshots = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: registry,
            fileManager: fm,
            processSnapshot: processSnapshot,
            capturedAt: 42,
            processArgumentsProvider: { processId in
                guard processes.contains(where: { $0.pid == processId }) else { return nil }
                return CmuxTopProcessArguments(
                    arguments: ["/usr/local/bin/pi"],
                    environment: [
                        "PWD": cwd.path,
                        "PI_CODING_AGENT_SESSION_DIR": sessionsRoot.path,
                    ]
                )
            }
        )

        let expectedDetectedKeys = Set(zip(restoredWorkspaceIds, panels).map { workspaceId, panelId in
            RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)
        })
        XCTAssertEqual(Set(detectedSnapshots.keys), expectedDetectedKeys)
        let detectedSessionIds = Set(detectedSnapshots.values.map { $0.snapshot.sessionId })
        XCTAssertEqual(detectedSessionIds.count, 1, "Pi latest-file detection is ambiguous for same-cwd workspaces")

        let index = RestorableAgentSessionIndex.load(
            homeDirectory: root.path,
            fileManager: fm,
            registry: registry,
            detectedSnapshots: detectedSnapshots,
            processArgumentsProvider: { _ in nil }
        )
        let restoredSessionIds = try zip(restoredWorkspaceIds, panels).map { workspaceId, panelId in
            try XCTUnwrap(index.snapshot(workspaceId: workspaceId, panelId: panelId)).sessionId
        }

        XCTAssertEqual(restoredSessionIds, sessionIds)
    }

    func testPiDetectedLatestSessionDoesNotUsePanelOnlyFallbackWhenPanelIdIsAmbiguous() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-pi-restore-panel-id-ambiguous-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let cwd = root.appendingPathComponent("repo", isDirectory: true)
        let sessionsRoot = root.appendingPathComponent("pi-sessions", isDirectory: true)
        let projectDirectory = try XCTUnwrap(PiSessionLocator.projectDirectoryName(for: cwd.path))
        let projectSessions = sessionsRoot.appendingPathComponent(projectDirectory, isDirectory: true)
        try fm.createDirectory(at: cwd, withIntermediateDirectories: true)
        try fm.createDirectory(at: projectSessions, withIntermediateDirectories: true)

        var registration = CmuxVaultAgentRegistration.builtInPi
        registration.sessionDirectory = sessionsRoot.path
        let registry = CmuxVaultAgentRegistry(registrations: [registration])
        let oldWorkspaceId = UUID()
        let otherOldWorkspaceId = UUID()
        let restoredWorkspaceId = UUID()
        let panelId = UUID()
        let hookRecords = [
            (sessionId: "pi-old-workspace-a", workspaceId: oldWorkspaceId),
            (sessionId: "pi-old-workspace-b", workspaceId: oldWorkspaceId),
            (sessionId: "pi-other-old-workspace", workspaceId: otherOldWorkspaceId),
        ]
        let detectedLatestSessionId = "pi-detected-newest"
        var hookSessions: [String: [String: Any]] = [:]
        for (index, hookRecord) in hookRecords.enumerated() {
            let sessionFile = projectSessions.appendingPathComponent("\(hookRecord.sessionId).jsonl", isDirectory: false)
            try "{}\n".write(to: sessionFile, atomically: true, encoding: .utf8)
            try fm.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: TimeInterval(1_000 + index))],
                ofItemAtPath: sessionFile.path
            )
            hookSessions[hookRecord.sessionId] = driftedAgentHookRecord(
                launcher: "pi",
                sessionId: hookRecord.sessionId,
                workspaceId: hookRecord.workspaceId,
                panelId: panelId,
                recordedCwd: cwd.path,
                launchCwd: cwd.path,
                updatedAt: TimeInterval(10 + index)
            )
        }
        let detectedLatestFile = projectSessions.appendingPathComponent("\(detectedLatestSessionId).jsonl", isDirectory: false)
        try "{}\n".write(to: detectedLatestFile, atomically: true, encoding: .utf8)
        try fm.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000)],
            ofItemAtPath: detectedLatestFile.path
        )
        try writeHookStore(root: root, storeFilename: "pi-hook-sessions.json", sessions: hookSessions)

        let process = CmuxTopProcessInfo(
            pid: 4_400,
            parentPID: 1,
            name: "pi",
            path: "/usr/local/bin/pi",
            ttyDevice: nil,
            cmuxWorkspaceID: restoredWorkspaceId,
            cmuxSurfaceID: panelId,
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
        let detectedSnapshots = RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: registry,
            fileManager: fm,
            processSnapshot: processSnapshot,
            capturedAt: 42,
            processArgumentsProvider: { processId in
                guard processId == process.pid else { return nil }
                return CmuxTopProcessArguments(
                    arguments: ["/usr/local/bin/pi"],
                    environment: [
                        "PWD": cwd.path,
                        "PI_CODING_AGENT_SESSION_DIR": sessionsRoot.path,
                    ]
                )
            }
        )
        let restoredKey = RestorableAgentSessionIndex.PanelKey(
            workspaceId: restoredWorkspaceId,
            panelId: panelId
        )
        let detected = try XCTUnwrap(detectedSnapshots[restoredKey])
        XCTAssertEqual(detected.snapshot.sessionId, detectedLatestSessionId)

        let index = RestorableAgentSessionIndex.load(
            homeDirectory: root.path,
            fileManager: fm,
            registry: registry,
            detectedSnapshots: detectedSnapshots,
            processArgumentsProvider: { _ in nil }
        )
        let snapshot = try XCTUnwrap(index.snapshot(workspaceId: restoredWorkspaceId, panelId: panelId))

        XCTAssertEqual(snapshot.sessionId, detectedLatestSessionId)
    }

    func testPiInferredLatestFallbackUsesSameKindPanelHookWhenAnotherKindIsNewer() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-pi-restore-kind-fallback-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let cwd = root.appendingPathComponent("repo", isDirectory: true)
        let configDir = root.appendingPathComponent("claude-config", isDirectory: true)
        let projectsDir = configDir.appendingPathComponent("projects", isDirectory: true)
        try fm.createDirectory(at: cwd, withIntermediateDirectories: true)
        try fm.createDirectory(
            at: projectsDir.appendingPathComponent(
                RestorableAgentSessionIndex.encodeClaudeProjectDir(cwd.path),
                isDirectory: true
            ),
            withIntermediateDirectories: true
        )

        let workspaceId = UUID()
        let panelId = UUID()
        let claudeSessionId = "11111111-1111-1111-1111-111111111111"
        let piHookSessionId = "pi-exact-panel-session"
        let detectedLatestPiSessionId = "pi-newest-cwd-session"

        try writeClaudeTranscript(sessionId: claudeSessionId, cwd: cwd, projectsDir: projectsDir)
        try writeClaudeHookStore(
            root: root,
            sessions: [
                claudeSessionId: hookRecord(
                    sessionId: claudeSessionId,
                    workspaceId: workspaceId,
                    panelId: panelId,
                    cwd: cwd.path,
                    configDir: configDir.path,
                    updatedAt: 50
                ),
            ]
        )
        try writeHookStore(
            root: root,
            storeFilename: "pi-hook-sessions.json",
            sessions: [
                piHookSessionId: driftedAgentHookRecord(
                    launcher: "pi",
                    sessionId: piHookSessionId,
                    workspaceId: workspaceId,
                    panelId: panelId,
                    recordedCwd: cwd.path,
                    launchCwd: cwd.path,
                    updatedAt: 10
                ),
            ]
        )

        let detectedSnapshot = SessionRestorableAgentSnapshot(
            kind: .custom("pi"),
            sessionId: detectedLatestPiSessionId,
            workingDirectory: cwd.path,
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "pi",
                executablePath: "/usr/local/bin/pi",
                arguments: ["/usr/local/bin/pi"],
                workingDirectory: cwd.path,
                environment: nil,
                capturedAt: 99,
                source: "process"
            )
        )
        let key = RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)
        let index = RestorableAgentSessionIndex.load(
            homeDirectory: root.path,
            fileManager: fm,
            registry: CmuxVaultAgentRegistry(registrations: [.builtInPi]),
            detectedSnapshots: [
                key: (
                    snapshot: detectedSnapshot,
                    updatedAt: 99,
                    processIDs: Set([123]), agentProcessIDs: Set([123]),
                    sessionIDSource: .inferredLatestSessionFile
                ),
            ],
            processArgumentsProvider: { _ in nil }
        )
        let snapshot = try XCTUnwrap(index.snapshot(workspaceId: workspaceId, panelId: panelId))

        XCTAssertEqual(snapshot.kind, .custom("pi"))
        XCTAssertEqual(snapshot.sessionId, piHookSessionId)
        XCTAssertEqual(index.processIDs(workspaceId: workspaceId, panelId: panelId), [123])
    }

    // RestorableAgentKind.cwdNamespacing delegates to the shared AgentResumeWorkingDirectory
    // classifier (in CMUXAgentLaunch) so the app-side resolver and the CLI surface-restore publisher
    // apply one policy. The shared resolver's own behavior is covered in CMUXAgentLaunchTests.
    func testRestorableAgentKindCwdNamespacingMatchesSharedClassifier() {
        for kind in RestorableAgentKind.allCases {
            XCTAssertEqual(
                kind.cwdNamespacing,
                AgentResumeWorkingDirectory().cwdNamespacing(forKind: kind.rawValue),
                "\(kind.rawValue) namespacing must match the shared classifier"
            )
        }
    }

    func testClaudeWorkflowDirectorySessionUsesSiblingJsonlSessionForResume() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-claude-workflow-directory-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }

        let configDir = root.appendingPathComponent("claude-config", isDirectory: true)
        let projectsDir = configDir.appendingPathComponent("projects", isDirectory: true)
        let cwd = root.appendingPathComponent("repo", isDirectory: true)
        try fm.createDirectory(at: cwd, withIntermediateDirectories: true)
        let projectDir = projectsDir.appendingPathComponent(
            expectedClaudeProjectDirName(cwd.path),
            isDirectory: true
        )
        let workflowContainerSessionId = "aaaaaaaa-1111-1111-1111-aaaaaaaaaaaa"
        let resumableSessionId = "bbbbbbbb-2222-2222-2222-bbbbbbbbbbbb"
        let workflowContainerURL = projectDir
            .appendingPathComponent(workflowContainerSessionId, isDirectory: true)
        try fm.createDirectory(
            at: workflowContainerURL
                .appendingPathComponent("subagents", isDirectory: true),
            withIntermediateDirectories: true
        )
        let siblingTranscriptURL = projectDir.appendingPathComponent("\(resumableSessionId).jsonl", isDirectory: false)
        try writeClaudeTranscript(sessionId: resumableSessionId, transcriptURL: siblingTranscriptURL, cwd: cwd)

        let workspaceId = UUID()
        let panelId = UUID()
        try writeClaudeHookStore(
            root: root,
            sessions: [
                workflowContainerSessionId: hookRecord(
                    sessionId: workflowContainerSessionId,
                    workspaceId: workspaceId,
                    panelId: panelId,
                    cwd: cwd.path,
                    configDir: configDir.path,
                    transcriptPath: workflowContainerURL.path,
                    isRestorable: true,
                    updatedAt: 10
                ),
            ]
        )

        let index = RestorableAgentSessionIndex.load(homeDirectory: root.path, fileManager: fm)
        let snapshot = try XCTUnwrap(index.snapshot(workspaceId: workspaceId, panelId: panelId))

        XCTAssertEqual(snapshot.sessionId, resumableSessionId)
        XCTAssertEqual(snapshot.workingDirectory, cwd.path)
        let resumeCommand = try XCTUnwrap(snapshot.resumeCommand)
        XCTAssertTrue(
            resumeCommand.contains(resumableSessionId),
            "resume command must target the sibling transcript session; got: \(resumeCommand)"
        )
        XCTAssertFalse(
            resumeCommand.contains(workflowContainerSessionId),
            "The Workflow container id is not accepted by claude --resume."
        )
    }

    private func makeClaudeTranscriptCacheFixture(
        prefix: String,
        sessionId: String,
        updatedAt: TimeInterval = 10
    ) throws -> (
        root: URL,
        configDir: URL,
        projectsDir: URL,
        projectDir: URL,
        cwd: URL,
        workspaceId: UUID,
        panelId: UUID,
        transcriptURL: URL
    ) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        let configDir = root.appendingPathComponent("claude-config", isDirectory: true)
        let projectsDir = configDir.appendingPathComponent("projects", isDirectory: true)
        let cwd = root.appendingPathComponent("repo", isDirectory: true)
        let projectDir = projectsDir.appendingPathComponent(
            expectedClaudeProjectDirName(cwd.path),
            isDirectory: true
        )
        try fm.createDirectory(at: cwd, withIntermediateDirectories: true)
        try fm.createDirectory(at: projectDir, withIntermediateDirectories: true)

        let workspaceId = UUID()
        let panelId = UUID()
        try writeClaudeHookStore(
            root: root,
            sessions: [
                sessionId: hookRecord(
                    sessionId: sessionId,
                    workspaceId: workspaceId,
                    panelId: panelId,
                    cwd: cwd.path,
                    configDir: configDir.path,
                    updatedAt: updatedAt
                ),
            ]
        )

        return (
            root: root,
            configDir: configDir,
            projectsDir: projectsDir,
            projectDir: projectDir,
            cwd: cwd,
            workspaceId: workspaceId,
            panelId: panelId,
            transcriptURL: projectDir.appendingPathComponent("\(sessionId).jsonl", isDirectory: false)
        )
    }

    private func setDirectoryModificationDate(_ date: Date, for directory: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: directory.path)
    }

    /// Mirrors Claude's external project-directory naming rule ("/" and "." both become "-")
    /// independently of the production `encodeClaudeProjectDir`, so these regression tests fail if
    /// that helper regresses instead of masking it by sharing the same code path.
    private func expectedClaudeProjectDirName(_ path: String) -> String {
        path.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    // A custom Vault agent defaults to cwd: .preserve and can expand {{cwd}} in its resume template,
    // so a restored custom session must keep the runtime cwd it drifted into, not the launch dir.
    // (The kind-based namespace classifier would otherwise treat an unknown id as by-directory.)
    func testCustomVaultAgentPreservesRuntimeCwdOnRestore() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-custom-cwd-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let launchCwd = root.appendingPathComponent("repo.main", isDirectory: true)
        let runtimeCwd = root.appendingPathComponent("worktree", isDirectory: true)
        try fm.createDirectory(at: launchCwd, withIntermediateDirectories: true)
        try fm.createDirectory(at: runtimeCwd, withIntermediateDirectories: true)

        let agentId = "my-agent"
        let registry = CmuxVaultAgentRegistry(registrations: [
            CmuxVaultAgentRegistration(
                id: agentId,
                name: "My Agent",
                detect: CmuxVaultAgentDetectRule(processNames: [agentId]),
                sessionIdSource: .argvOption("--resume"),
                resumeCommand: "{{executable}} --resume {{sessionId}}",
                forkCommand: "{{executable}} --resume {{sessionId}} --fork",
                cwd: .preserve
            ),
        ])

        let ws = UUID()
        let panel = UUID()
        let sid = "77777777-7777-7777-7777-777777777777"
        try writeHookStore(
            root: root,
            storeFilename: "\(agentId)-hook-sessions.json",
            sessions: [
                sid: driftedAgentHookRecord(
                    launcher: agentId, sessionId: sid, workspaceId: ws, panelId: panel,
                    recordedCwd: runtimeCwd.path, launchCwd: launchCwd.path, updatedAt: 10
                ),
            ]
        )

        let snapshot = try XCTUnwrap(
            RestorableAgentSessionIndex.load(
                homeDirectory: root.path,
                fileManager: fm,
                registry: registry,
                detectedSnapshots: [:],
                processArgumentsProvider: { _ in nil }
            ).snapshot(workspaceId: ws, panelId: panel),
            "custom agent snapshot"
        )
        XCTAssertEqual(
            snapshot.workingDirectory, runtimeCwd.path,
            "a custom .preserve agent must keep the runtime cwd it drifted into, not the launch dir"
        )
        let resume = try XCTUnwrap(snapshot.resumeCommand)
        XCTAssertTrue(resume.contains(runtimeCwd.path), "resume must cd into the runtime cwd; got: \(resume)")
        XCTAssertFalse(resume.contains(launchCwd.path), "resume must not fall back to the launch dir; got: \(resume)")
        let fork = try XCTUnwrap(snapshot.forkCommand)
        XCTAssertTrue(fork.contains(runtimeCwd.path), "fork must cd into the runtime cwd; got: \(fork)")
        XCTAssertTrue(fork.contains("'--fork'"), "fork must use the custom fork template; got: \(fork)")
    }

    // Forking branches a NEW session off an existing one. The fork command must use the correct
    // per-agent fork verb and cd into the session's directory, so the forked session launches in the
    // right place and is itself resumable.
    func testForkCommandUsesPerAgentVerbAndSessionCwd() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-fork-agents-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let dir = root.appendingPathComponent("repo", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let cases: [(launcher: String, store: String, verbNeedles: [String])] = [
            ("codex", "codex-hook-sessions.json", ["'fork'"]),
            ("opencode", "opencode-hook-sessions.json", ["'--session'", "'--fork'"]),
            ("pi", "pi-hook-sessions.json", ["'--session'", "'--fork'"]),
            ("omp", "omp-hook-sessions.json", ["'--session'", "'--fork'"]),
        ]
        for testCase in cases {
            let ws = UUID()
            let panel = UUID()
            let sid = "55555555-5555-5555-5555-555555555555"
            try writeHookStore(
                root: root,
                storeFilename: testCase.store,
                sessions: [
                    sid: driftedAgentHookRecord(
                        launcher: testCase.launcher, sessionId: sid, workspaceId: ws, panelId: panel,
                        recordedCwd: dir.path, launchCwd: dir.path, updatedAt: 10
                    ),
                ]
            )
            let snapshot = try XCTUnwrap(
                RestorableAgentSessionIndex.load(homeDirectory: root.path, fileManager: fm)
                    .snapshot(workspaceId: ws, panelId: panel),
                "\(testCase.launcher): snapshot"
            )
            let fork = try XCTUnwrap(snapshot.forkCommand, "\(testCase.launcher): forkCommand")
            XCTAssertTrue(
                fork.contains("cd -- '\(dir.path)'"),
                "\(testCase.launcher): fork must cd into the session dir; got: \(fork)"
            )
            XCTAssertTrue(fork.contains("'\(sid)'"), "\(testCase.launcher): fork must reference the session id; got: \(fork)")
            for needle in testCase.verbNeedles {
                XCTAssertTrue(fork.contains(needle), "\(testCase.launcher): fork must use its fork verb \(needle); got: \(fork)")
            }
            // The forked session must be launchable (and therefore itself resumable).
            XCTAssertNotNil(
                snapshot.forkStartupInput(fileManager: fm, temporaryDirectory: root),
                "\(testCase.launcher): forked session must be launchable"
            )
        }
    }

    // Agents without a fork verb must not emit a fork command (a malformed one would launch a broken
    // session). This pins which agents support fork so the set is explicit.
    func testNonForkAgentsProduceNoForkCommand() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-nofork-agents-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let dir = root.appendingPathComponent("repo", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        for launcher in ["gemini", "grok", "amp", "cursor"] {
            let ws = UUID()
            let panel = UUID()
            let sid = "66666666-6666-6666-6666-666666666666"
            try writeHookStore(
                root: root,
                storeFilename: "\(launcher)-hook-sessions.json",
                sessions: [
                    sid: driftedAgentHookRecord(
                        launcher: launcher, sessionId: sid, workspaceId: ws, panelId: panel,
                        recordedCwd: dir.path, launchCwd: dir.path, updatedAt: 10
                    ),
                ]
            )
            let snapshot = try XCTUnwrap(
                RestorableAgentSessionIndex.load(homeDirectory: root.path, fileManager: fm)
                    .snapshot(workspaceId: ws, panelId: panel),
                "\(launcher): snapshot"
            )
            // It still resumes; it just has no fork form.
            XCTAssertNotNil(snapshot.resumeCommand, "\(launcher): must still resume")
            XCTAssertNil(snapshot.forkCommand, "\(launcher): has no fork support and must not emit a fork command")
        }
    }

    // Spawn an agent, end it, spawn a new one on the same surface: restore must pick the NEWEST
    // session (highest updatedAt), not the stale earlier one.
    func testReplacementRestoresNewestSessionForSurface() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-newest-wins-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let dir = root.appendingPathComponent("repo", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let ws = UUID()
        let panel = UUID()
        let oldId = "11111111-1111-1111-1111-111111111111"
        let newId = "22222222-2222-2222-2222-222222222222"
        try writeHookStore(
            root: root,
            storeFilename: "gemini-hook-sessions.json",
            sessions: [
                oldId: driftedAgentHookRecord(
                    launcher: "gemini", sessionId: oldId, workspaceId: ws, panelId: panel,
                    recordedCwd: dir.path, launchCwd: dir.path, updatedAt: 10
                ),
                newId: driftedAgentHookRecord(
                    launcher: "gemini", sessionId: newId, workspaceId: ws, panelId: panel,
                    recordedCwd: dir.path, launchCwd: dir.path, updatedAt: 20
                ),
            ]
        )

        let snapshot = try XCTUnwrap(
            RestorableAgentSessionIndex.load(homeDirectory: root.path, fileManager: fm)
                .snapshot(workspaceId: ws, panelId: panel)
        )
        XCTAssertEqual(snapshot.sessionId, newId, "the surface must resume the newest session, not the replaced one")
    }

    // Reopening the app multiple times must restore the same session each time (load is pure over
    // the on-disk store).
    func testRestoreIsIdempotentAcrossReloads() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-idempotent-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let dir = root.appendingPathComponent("repo", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let ws = UUID()
        let panel = UUID()
        let sid = "33333333-3333-3333-3333-333333333333"
        try writeHookStore(
            root: root,
            storeFilename: "gemini-hook-sessions.json",
            sessions: [
                sid: driftedAgentHookRecord(
                    launcher: "gemini", sessionId: sid, workspaceId: ws, panelId: panel,
                    recordedCwd: dir.path, launchCwd: dir.path, updatedAt: 10
                ),
            ]
        )

        var ids: [String?] = []
        var commands: [String?] = []
        for _ in 0..<3 {
            let snap = RestorableAgentSessionIndex.load(homeDirectory: root.path, fileManager: fm)
                .snapshot(workspaceId: ws, panelId: panel)
            ids.append(snap?.sessionId)
            commands.append(snap?.resumeCommand)
        }
        XCTAssertEqual(ids, [sid, sid, sid])
        XCTAssertEqual(Set(commands.compactMap { $0 }).count, 1, "resume command must be stable across reloads")
    }

    // A session whose recorded process is no longer alive (the agent was killed) must NOT restore
    // from the hook index, even though the record is still on disk.
    func testKilledSessionWithDeadProcessDoesNotRestore() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-killed-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let dir = root.appendingPathComponent("repo", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let ws = UUID()
        let panel = UUID()
        let sid = "44444444-4444-4444-4444-444444444444"
        try writeHookStore(
            root: root,
            storeFilename: "gemini-hook-sessions.json",
            sessions: [
                sid: driftedAgentHookRecord(
                    launcher: "gemini", sessionId: sid, workspaceId: ws, panelId: panel,
                    recordedCwd: dir.path, launchCwd: dir.path, updatedAt: 10, pid: 999_999
                ),
            ]
        )

        let registry = CmuxVaultAgentRegistry.load(homeDirectory: root.path, fileManager: fm)
        let index = RestorableAgentSessionIndex.load(
            homeDirectory: root.path,
            fileManager: fm,
            registry: registry,
            detectedSnapshots: [:],
            processArgumentsProvider: { _ in nil }
        )
        XCTAssertNil(
            index.snapshot(workspaceId: ws, panelId: panel),
            "a killed session whose recorded process is dead must not restore"
        )
    }

    private func driftedHookRecord(
        sessionId: String,
        workspaceId: UUID,
        panelId: UUID,
        recordedCwd: String,
        launchCwd: String,
        configDir: String,
        transcriptPath: String?,
        updatedAt: TimeInterval
    ) -> [String: Any] {
        var record: [String: Any] = [
            "sessionId": sessionId,
            "workspaceId": workspaceId.uuidString,
            "surfaceId": panelId.uuidString,
            "cwd": recordedCwd,
            "pid": NSNull(),
            "updatedAt": updatedAt,
            "launchCommand": [
                "launcher": "claude",
                "executablePath": "/usr/local/bin/claude",
                "arguments": ["/usr/local/bin/claude", "--dangerously-skip-permissions"],
                "workingDirectory": launchCwd,
                "environment": ["CLAUDE_CONFIG_DIR": configDir],
                "capturedAt": updatedAt,
                "source": "test",
            ],
        ]
        if let transcriptPath {
            record["transcriptPath"] = transcriptPath
        }
        return record
    }

    // A drifted hook record for an arbitrary (non-Claude) agent: the recorded runtime cwd differs
    // from the frozen launch working directory, mirroring the production drift in CLI/cmux.swift.
    private func driftedAgentHookRecord(
        launcher: String,
        sessionId: String,
        workspaceId: UUID,
        panelId: UUID,
        recordedCwd: String,
        launchCwd: String,
        updatedAt: TimeInterval,
        pid: Int? = nil
    ) -> [String: Any] {
        [
            "sessionId": sessionId,
            "workspaceId": workspaceId.uuidString,
            "surfaceId": panelId.uuidString,
            "cwd": recordedCwd,
            "pid": pid.map { $0 as Any } ?? NSNull(),
            "isRestorable": true,
            "updatedAt": updatedAt,
            "launchCommand": [
                "launcher": launcher,
                "executablePath": "/usr/local/bin/\(launcher)",
                "arguments": ["/usr/local/bin/\(launcher)"],
                "workingDirectory": launchCwd,
                "capturedAt": updatedAt,
                "source": "test",
            ],
        ]
    }

    private func hookRecord(
        sessionId: String,
        workspaceId: UUID,
        panelId: UUID,
        cwd: String,
        configDir: String,
        updatedAt: TimeInterval
    ) -> [String: Any] {
        hookRecord(
            sessionId: sessionId,
            workspaceId: workspaceId,
            panelId: panelId,
            cwd: cwd,
            configDir: configDir,
            isRestorable: nil,
            updatedAt: updatedAt
        )
    }

    private func hookRecord(
        sessionId: String,
        workspaceId: UUID,
        panelId: UUID,
        cwd: String,
        configDir: String,
        isRestorable: Bool?,
        updatedAt: TimeInterval
    ) -> [String: Any] {
        hookRecord(
            sessionId: sessionId,
            workspaceId: workspaceId,
            panelId: panelId,
            cwd: cwd,
            configDir: configDir,
            transcriptPath: nil,
            isRestorable: isRestorable,
            updatedAt: updatedAt
        )
    }

    private func hookRecord(
        sessionId: String,
        workspaceId: UUID,
        panelId: UUID,
        cwd: String,
        configDir: String,
        transcriptPath: String?,
        isRestorable: Bool?,
        updatedAt: TimeInterval
    ) -> [String: Any] {
        var record: [String: Any] = [
            "sessionId": sessionId,
            "workspaceId": workspaceId.uuidString,
            "surfaceId": panelId.uuidString,
            "cwd": cwd,
            "pid": NSNull(),
            "updatedAt": updatedAt,
            "launchCommand": [
                "launcher": "claude",
                "executablePath": "/usr/local/bin/claude",
                "arguments": ["/usr/local/bin/claude", "--dangerously-skip-permissions"],
                "workingDirectory": cwd,
                "environment": ["CLAUDE_CONFIG_DIR": configDir],
                "capturedAt": updatedAt,
                "source": "test",
            ],
        ]
        if let isRestorable {
            record["isRestorable"] = isRestorable
        }
        if let transcriptPath {
            record["transcriptPath"] = transcriptPath
        }
        return record
    }

    private func writeClaudeTranscript(sessionId: String, cwd: URL, projectsDir: URL) throws {
        let transcriptURL = projectsDir
            .appendingPathComponent(RestorableAgentSessionIndex.encodeClaudeProjectDir(cwd.path), isDirectory: true)
            .appendingPathComponent("\(sessionId).jsonl", isDirectory: false)
        try writeClaudeTranscript(sessionId: sessionId, transcriptURL: transcriptURL, cwd: cwd)
    }

    private func writeClaudeTranscript(sessionId: String, transcriptURL: URL, cwd: URL) throws {
        try """
        {"type":"last-prompt","sessionId":"\(sessionId)"}
        {"type":"user","sessionId":"\(sessionId)","cwd":"\(cwd.path)","message":{"role":"user","content":"hello"}}

        """.write(to: transcriptURL, atomically: true, encoding: .utf8)
    }

    private func writeClaudeHookStore(root: URL, sessions: [String: [String: Any]]) throws {
        try writeHookStore(root: root, storeFilename: "claude-hook-sessions.json", sessions: sessions)
    }

    // A codex launched from inside a claude session inherits claude's CMUX_AGENT_LAUNCH_*
    // environment (every child of a claude process carries it), so the codex hook record can
    // capture a claude launch command: launcher "claude" with the claude binary and
    // claude-only flags. Resume/fork must never run the foreign binary; the cross-agent
    // capture is discarded and the agent's bare verbs are used instead. This is the root
    // cause of "Fork Conversation" breaking for codex sessions started under a claude session.
    func testCrossAgentLaunchCaptureIsDiscardedForResumeAndFork() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-cross-agent-capture-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let dir = root.appendingPathComponent("repo", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let foreignDir = root.appendingPathComponent("claude-launch-dir", isDirectory: true)
        try fm.createDirectory(at: foreignDir, withIntermediateDirectories: true)

        let ws = UUID()
        let panel = UUID()
        let sid = "66666666-6666-6666-6666-666666666666"
        var record = driftedAgentHookRecord(
            launcher: "codex", sessionId: sid, workspaceId: ws, panelId: panel,
            recordedCwd: dir.path, launchCwd: dir.path, updatedAt: 10
        )
        record["launchCommand"] = [
            "launcher": "claude",
            "executablePath": "/Users/someone/.local/bin/claude",
            "arguments": [
                "/Users/someone/.local/bin/claude",
                "--dangerously-skip-permissions",
                "--chrome",
            ],
            "workingDirectory": foreignDir.path,
            "environment": ["CLAUDE_CONFIG_DIR": "/Users/someone/.claude"],
            "capturedAt": 10,
            "source": "environment",
        ]
        try writeHookStore(
            root: root,
            storeFilename: "codex-hook-sessions.json",
            sessions: [sid: record]
        )

        let snapshot = try XCTUnwrap(
            RestorableAgentSessionIndex.load(homeDirectory: root.path, fileManager: fm)
                .snapshot(workspaceId: ws, panelId: panel)
        )
        XCTAssertEqual(
            snapshot.workingDirectory,
            dir.path,
            "the foreign capture's launch cwd must not leak into the snapshot"
        )
        let resume = try XCTUnwrap(snapshot.resumeCommand)
        XCTAssertFalse(resume.contains("claude"), "codex resume must not run the claude binary; got: \(resume)")
        // Bare `codex` now routes through the codex wrapper token (CMUX_CODEX_WRAPPER_SHIM)
        // wrapped in `/bin/sh -c '…'` so the resumed session keeps cmux hooks (issue #5639).
        XCTAssertTrue(resume.contains("/bin/sh -c "), "codex resume must wrap the wrapper token for any login shell; got: \(resume)")
        XCTAssertTrue(resume.contains("CMUX_CODEX_WRAPPER_SHIM"), "codex resume must route through the codex wrapper shim; got: \(resume)")
        XCTAssertTrue(resume.contains("resume") && resume.contains(sid), "codex resume must use the resume verb and session id; got: \(resume)")
        XCTAssertFalse(resume.contains(foreignDir.path), "codex resume must not cd into the foreign launch dir; got: \(resume)")
        let fork = try XCTUnwrap(snapshot.forkCommand)
        XCTAssertFalse(fork.contains("claude"), "codex fork must not run the claude binary; got: \(fork)")
        XCTAssertTrue(fork.contains("/bin/sh -c "), "codex fork must wrap the wrapper token for any login shell; got: \(fork)")
        XCTAssertTrue(fork.contains("CMUX_CODEX_WRAPPER_SHIM"), "codex fork must route through the codex wrapper shim; got: \(fork)")
        XCTAssertTrue(fork.contains("fork") && fork.contains(sid), "codex fork must use the fork verb and session id; got: \(fork)")
        XCTAssertFalse(fork.contains(foreignDir.path), "codex fork must not cd into the foreign launch dir; got: \(fork)")
    }

    // When the launch argv falls back to a PID that points at the hook dispatch shell instead of
    // the agent (`sh -c 'payload=...'`), the captured argv describes the hook wrapper, not a
    // launch. Resume/fork must discard it and use the agent's bare verbs.
    func testShellWrapperArgvCaptureIsDiscardedForResumeAndFork() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-shell-argv-capture-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let dir = root.appendingPathComponent("repo", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let ws = UUID()
        let panel = UUID()
        let sid = "77777777-7777-7777-7777-777777777777"
        var record = driftedAgentHookRecord(
            launcher: "codex", sessionId: sid, workspaceId: ws, panelId: panel,
            recordedCwd: dir.path, launchCwd: dir.path, updatedAt: 10
        )
        record["launchCommand"] = [
            "launcher": "codex",
            "executablePath": "sh",
            "arguments": ["sh", "-c", "payload=\"${CMUX_HOOK_PAYLOAD:-}\"; eval \"$command\""],
            "workingDirectory": dir.path,
            "capturedAt": 10,
            "source": "process",
        ]
        try writeHookStore(
            root: root,
            storeFilename: "codex-hook-sessions.json",
            sessions: [sid: record]
        )

        let snapshot = try XCTUnwrap(
            RestorableAgentSessionIndex.load(homeDirectory: root.path, fileManager: fm)
                .snapshot(workspaceId: ws, panelId: panel)
        )
        let resume = try XCTUnwrap(snapshot.resumeCommand)
        XCTAssertFalse(resume.contains("'sh'"), "codex resume must not run the hook shell wrapper; got: \(resume)")
        // Bare `codex` routes through the codex wrapper token wrapped in `/bin/sh -c '…'`
        // (issue #5639) so the resumed session keeps cmux hooks.
        XCTAssertTrue(resume.contains("CMUX_CODEX_WRAPPER_SHIM"), "codex resume must route through the codex wrapper shim; got: \(resume)")
        XCTAssertTrue(resume.contains("resume") && resume.contains(sid), "codex resume must use the resume verb and session id; got: \(resume)")
        let fork = try XCTUnwrap(snapshot.forkCommand)
        XCTAssertFalse(fork.contains("'sh'"), "codex fork must not run the hook shell wrapper; got: \(fork)")
        XCTAssertTrue(fork.contains("CMUX_CODEX_WRAPPER_SHIM"), "codex fork must route through the codex wrapper shim; got: \(fork)")
        XCTAssertTrue(fork.contains("fork") && fork.contains(sid), "codex fork must use the fork verb and session id; got: \(fork)")
    }

    // Wrapper launchers legitimately differ from the hook kind; their captures must stay trusted.
    func testWrapperLauncherCaptureStaysTrusted() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("cmux-wrapper-launcher-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let dir = root.appendingPathComponent("repo", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let ws = UUID()
        let panel = UUID()
        let sid = "88888888-8888-8888-8888-888888888888"
        var record = driftedAgentHookRecord(
            launcher: "codex", sessionId: sid, workspaceId: ws, panelId: panel,
            recordedCwd: dir.path, launchCwd: dir.path, updatedAt: 10
        )
        record["launchCommand"] = [
            "launcher": "codexTeams",
            "executablePath": "/usr/local/bin/cmux",
            "arguments": ["/usr/local/bin/cmux", "codex-teams"],
            "workingDirectory": dir.path,
            "capturedAt": 10,
            "source": "environment",
        ]
        try writeHookStore(
            root: root,
            storeFilename: "codex-hook-sessions.json",
            sessions: [sid: record]
        )

        let snapshot = try XCTUnwrap(
            RestorableAgentSessionIndex.load(homeDirectory: root.path, fileManager: fm)
                .snapshot(workspaceId: ws, panelId: panel)
        )
        let fork = try XCTUnwrap(snapshot.forkCommand)
        XCTAssertTrue(
            fork.contains("'codex-teams' 'fork' '\(sid)'"),
            "codexTeams capture must keep routing fork through the cmux wrapper; got: \(fork)"
        )
    }

    private func writeHookStore(
        root: URL,
        storeFilename: String,
        sessions: [String: [String: Any]]
    ) throws {
        let stateDir = root.appendingPathComponent(".cmuxterm", isDirectory: true)
        try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: [
                "version": 1,
                "sessions": sessions,
            ],
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(
            to: stateDir.appendingPathComponent(storeFilename, isDirectory: false),
            options: .atomic
        )
    }
}
