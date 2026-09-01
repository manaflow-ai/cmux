import AppKit
import CMUXAgentLaunch
import CmuxAgentChat
import CmuxArtifacts
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Artifact runtime lifecycle")
@MainActor
struct ArtifactRuntimeLifecycleTests {
    @Test("Workspace grouping uses the restart-stable workspace identity")
    func workspaceGroupingUsesStableIdentity() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(workingDirectory: root.path)

        let selection = try #require(ContentView.artifactSidebarWorkspace(for: workspace))

        #expect(selection.id == workspace.stableId.uuidString)
        #expect(selection.id != workspace.id.uuidString)
    }

    @Test("Disabling automatic capture releases artifact-only transcript tailers")
    func disablingCaptureReleasesArtifactOnlyTailers() throws {
        let fixture = try transcriptFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var captureEnabled = true
        let service = AgentChatTranscriptService(
            registry: AgentChatSessionRegistry(),
            hasEventSubscribers: { false },
            artifactCaptureCoordinator: AgentArtifactCaptureCoordinator(
                captureService: ArtifactCaptureService(store: LocalArtifactRepository())
            ),
            isAutomaticArtifactCaptureEnabled: { captureEnabled }
        )
        service.noteHookEvent(fixture.event)
        #expect(service.debugSessionDump().first?["tailer_active"] as? Bool == true)

        captureEnabled = false
        service.reconcileAutomaticArtifactCaptureAvailability()

        #expect(service.debugSessionDump().first?["tailer_active"] as? Bool == false)
    }

    @Test("Disabling automatic capture preserves mobile-owned transcript tailers")
    func disablingCapturePreservesSubscriberTailers() throws {
        let fixture = try transcriptFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var captureEnabled = true
        let service = AgentChatTranscriptService(
            registry: AgentChatSessionRegistry(),
            hasEventSubscribers: { true },
            artifactCaptureCoordinator: AgentArtifactCaptureCoordinator(
                captureService: ArtifactCaptureService(store: LocalArtifactRepository())
            ),
            isAutomaticArtifactCaptureEnabled: { captureEnabled }
        )
        service.noteHookEvent(fixture.event)
        #expect(service.debugSessionDump().first?["tailer_active"] as? Bool == true)

        captureEnabled = false
        service.reconcileAutomaticArtifactCaptureAvailability()

        #expect(service.debugSessionDump().first?["tailer_active"] as? Bool == true)
    }

    @Test("Enabling automatic capture does not resolve unrecorded Codex transcripts")
    func enablingCaptureSkipsUnrecordedCodexTranscripts() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var captureEnabled = false
        let service = AgentChatTranscriptService(
            registry: AgentChatSessionRegistry(),
            resolver: AgentChatTranscriptResolver(homeDirectory: root, environment: [:]),
            hasEventSubscribers: { false },
            artifactCaptureCoordinator: AgentArtifactCaptureCoordinator(
                captureService: ArtifactCaptureService(store: LocalArtifactRepository())
            ),
            isAutomaticArtifactCaptureEnabled: { captureEnabled }
        )
        service.noteHookEvent(WorkstreamEvent(
            sessionId: UUID().uuidString,
            hookEventName: .sessionStart,
            source: "codex",
            workspaceId: UUID().uuidString,
            surfaceId: nil,
            transcriptPath: nil,
            cwd: root.path,
            ppid: nil,
            receivedAt: .now
        ))

        captureEnabled = true
        service.reconcileAutomaticArtifactCaptureAvailability()

        let session = try #require(service.debugSessionDump().first)
        #expect(session["tailer_active"] as? Bool == false)
        #expect(session["resolution_failed"] as? Bool == false)
    }

    @Test("Enabling automatic capture adopts a recorded Codex transcript")
    func enablingCaptureAdoptsRecordedCodexTranscript() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = root.appendingPathComponent("recorded.jsonl")
        try Data().write(to: transcript)
        var captureEnabled = false
        let service = AgentChatTranscriptService(
            registry: AgentChatSessionRegistry(),
            resolver: AgentChatTranscriptResolver(homeDirectory: root, environment: [:]),
            hasEventSubscribers: { false },
            artifactCaptureCoordinator: AgentArtifactCaptureCoordinator(
                captureService: ArtifactCaptureService(store: LocalArtifactRepository())
            ),
            isAutomaticArtifactCaptureEnabled: { captureEnabled }
        )
        service.noteHookEvent(WorkstreamEvent(
            sessionId: UUID().uuidString,
            hookEventName: .sessionStart,
            source: "codex",
            workspaceId: UUID().uuidString,
            surfaceId: nil,
            transcriptPath: transcript.path,
            cwd: root.path,
            ppid: nil,
            receivedAt: .now
        ))

        captureEnabled = true
        service.reconcileAutomaticArtifactCaptureAvailability()

        #expect(service.debugSessionDump().first?["tailer_active"] as? Bool == true)
    }

    @Test("Transcript-observed completion captures without a Stop hook")
    func transcriptObservedCompletionCapturesWithoutStopHook() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifact = root.appendingPathComponent("hookless-plan.md")
        try "plan".write(to: artifact, atomically: true, encoding: .utf8)
        let transcript = root.appendingPathComponent("transcript.jsonl")
        try claudeArtifactLine(path: artifact.path).write(
            to: transcript,
            atomically: true,
            encoding: .utf8
        )
        let store = OutOfOrderCaptureStore(suspendsFirstImport: false)
        let service = AgentChatTranscriptService(
            registry: AgentChatSessionRegistry(),
            hasEventSubscribers: { false },
            emitEventPayload: { _ in },
            artifactCaptureCoordinator: AgentArtifactCaptureCoordinator(
                captureService: ArtifactCaptureService(store: store)
            )
        )
        let sessionID = UUID().uuidString
        service.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .userPromptSubmit,
            source: "claude",
            workspaceId: "workspace",
            surfaceId: nil,
            transcriptPath: transcript.path,
            cwd: root.path,
            ppid: nil,
            receivedAt: Date(timeIntervalSince1970: 1)
        ))

        service.publishBatch(
            assistantCompletionBatch(timestamp: Date(timeIntervalSince1970: 2)),
            sessionID: sessionID
        )
        let task = try #require(service.artifactCaptureTasks[sessionID]?.task)
        await task.value

        #expect(await store.importedPaths == [artifact.path])
    }

    @Test("Transcript flush after Stop schedules a newer automatic capture")
    func transcriptFlushAfterStopSchedulesNewerCapture() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let artifact = root.appendingPathComponent("late-plan.md")
        try "plan".write(to: artifact, atomically: true, encoding: .utf8)
        let transcript = root.appendingPathComponent("transcript.jsonl")
        try "".write(to: transcript, atomically: true, encoding: .utf8)
        let store = OutOfOrderCaptureStore(suspendsFirstImport: false)
        let service = AgentChatTranscriptService(
            registry: AgentChatSessionRegistry(),
            hasEventSubscribers: { false },
            emitEventPayload: { _ in },
            artifactCaptureCoordinator: AgentArtifactCaptureCoordinator(
                captureService: ArtifactCaptureService(store: store)
            )
        )
        let sessionID = UUID().uuidString
        service.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .userPromptSubmit,
            source: "claude",
            workspaceId: "workspace",
            surfaceId: nil,
            transcriptPath: transcript.path,
            cwd: root.path,
            ppid: nil,
            receivedAt: Date(timeIntervalSince1970: 1)
        ))
        service.noteHookEvent(WorkstreamEvent(
            sessionId: sessionID,
            hookEventName: .stop,
            source: "claude",
            workspaceId: "workspace",
            surfaceId: nil,
            transcriptPath: transcript.path,
            cwd: root.path,
            ppid: nil,
            receivedAt: Date(timeIntervalSince1970: 2)
        ))
        let stopCapture = try #require(service.artifactCaptureTasks[sessionID]?.task)
        await stopCapture.value

        try claudeArtifactLine(path: artifact.path).write(
            to: transcript,
            atomically: true,
            encoding: .utf8
        )
        service.publishBatch(
            assistantCompletionBatch(timestamp: Date(timeIntervalSince1970: 3)),
            sessionID: sessionID
        )
        let flushCapture = try #require(service.artifactCaptureTasks[sessionID]?.task)
        await flushCapture.value

        #expect(await store.importedPaths == [artifact.path])
    }

    @Test("Automatic capture retries transient store contention")
    func captureRetriesTransientStoreContention() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("artifact.md", isDirectory: false)
        try "artifact".write(to: source, atomically: true, encoding: .utf8)
        let store = OutOfOrderCaptureStore(
            suspendsFirstImport: false,
            rejectsFirstImportAsBusy: true
        )
        let service = AgentChatTranscriptService(
            registry: AgentChatSessionRegistry(),
            artifactCaptureCoordinator: AgentArtifactCaptureCoordinator(
                captureService: ArtifactCaptureService(store: store),
                contentionRetryDelay: { _ in }
            )
        )
        let record = AgentChatSessionRecord(
            sessionID: "contention-session",
            agentKind: .claude,
            workspaceID: "workspace",
            surfaceID: nil,
            workingDirectory: root.path,
            workingDirectoryAuthority: .hook,
            transcriptPath: nil,
            state: .idle,
            lastActivityAt: .now,
            title: nil,
            pid: nil
        )
        let snapshot = AgentChatArtifactIndex.Snapshot(
            referencedPaths: [source.path],
            artifacts: [ChatArtifactIndexedReference(
                path: source.path,
                provenance: .created,
                lastReferencedSeq: 1
            )],
            generation: "contention",
            revision: 1
        )

        service.scheduleIndexedArtifactCapture(record: record, snapshot: snapshot)
        let task = try #require(service.artifactCaptureTasks[record.sessionID]?.task)
        await task.value

        #expect(await store.importCount == 2)
        #expect(await store.importedPaths == [source.path])
    }

    @Test("Referenced capture honors configured ephemeral roots within the project")
    func referencedCaptureHonorsConfiguredEphemeralRoots() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let allowedDirectory = root.appendingPathComponent("allowed", isDirectory: true)
        let excludedDirectory = root.appendingPathComponent("excluded", isDirectory: true)
        try FileManager.default.createDirectory(
            at: allowedDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: excludedDirectory,
            withIntermediateDirectories: true
        )
        let allowed = allowedDirectory.appendingPathComponent("allowed.md")
        let excluded = excludedDirectory.appendingPathComponent("excluded.md")
        try "allowed".write(to: allowed, atomically: true, encoding: .utf8)
        try "excluded".write(to: excluded, atomically: true, encoding: .utf8)
        var configuration = ArtifactCaptureConfiguration.defaultValue
        configuration.ephemeralPathPrefixes = [allowedDirectory.path]
        let store = OutOfOrderCaptureStore(
            suspendsFirstImport: false,
            configuration: configuration
        )

        let outcomes = await ArtifactCaptureService(store: store).capture(
            candidates: [
                ArtifactCandidate(sourceURL: allowed, provenance: .referenced),
                ArtifactCandidate(sourceURL: excluded, provenance: .referenced),
            ],
            context: ArtifactCaptureContext(projectRoot: root)
        )

        #expect(await store.importedPaths == [allowed.path])
        #expect(outcomes.count == 2)
        #expect(outcomes.last == .skipped(.provenanceNotEligible))
    }

    @Test("Artifacts focus waits for its search endpoint instead of accepting the sidebar host")
    func artifactsFocusTargetsSearchEndpoint() {
        let defaults = UserDefaults.standard
        let key = RightSidebarBetaFeatureSettings.artifactsEnabledKey
        let previousValue = defaults.object(forKey: key)
        defaults.set(true, forKey: key)
        defer { restore(previousValue, forKey: key) }

        let fileExplorerState = FileExplorerState()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 180),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let contentView = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = contentView
        let controller = MainWindowFocusController(
            windowId: UUID(),
            window: window,
            tabManager: TabManager(),
            fileExplorerState: fileExplorerState
        )
        let fallbackHost = RightSidebarKeyboardFocusView(
            frame: NSRect(x: 0, y: 0, width: 24, height: 24)
        )
        let searchField = ArtifactSidebarSearchFieldView(
            frame: NSRect(x: 0, y: 0, width: 160, height: 24)
        )
        contentView.addSubview(fallbackHost)
        controller.registerRightSidebarHost(fallbackHost)
        defer {
            _ = window.makeFirstResponder(nil)
            searchField.removeFromSuperview()
            fallbackHost.removeFromSuperview()
            window.contentView = nil
            window.orderOut(nil)
        }

        #expect(controller.focusRightSidebar(mode: .artifacts, focusFirstItem: true))
        #expect(controller.debugPendingRightSidebarFocusMode == .artifacts)

        contentView.addSubview(searchField)
        controller.registerArtifactSearchField(searchField)

        #expect(controller.debugPendingRightSidebarFocusMode == nil)
        if let responder = window.firstResponder {
            #expect(searchField.ownsKeyboardFocus(responder))
        } else {
            Issue.record("Expected the Artifacts search field to own keyboard focus")
        }
    }

    private func transcriptFixture() throws -> (root: URL, event: WorkstreamEvent) {
        let root = try temporaryDirectory()
        let transcript = root.appendingPathComponent("transcript.jsonl")
        try Data().write(to: transcript)
        return (
            root,
            WorkstreamEvent(
                sessionId: UUID().uuidString,
                hookEventName: .userPromptSubmit,
                source: "claude",
                workspaceId: UUID().uuidString,
                surfaceId: nil,
                transcriptPath: transcript.path,
                cwd: root.path,
                ppid: nil,
                receivedAt: .now
            )
        )
    }

    private func assistantCompletionBatch(
        timestamp: Date
    ) -> AgentChatTranscriptTailer.Batch {
        AgentChatTranscriptTailer.Batch(
            appended: [ChatMessage(
                id: UUID().uuidString,
                seq: 1,
                role: .agent,
                timestamp: timestamp,
                kind: .prose(ChatProse(text: "Done"))
            )],
            updated: [],
            discoveredTitle: nil
        )
    }

    private func claudeArtifactLine(path: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [
            "type": "assistant",
            "isSidechain": false,
            "uuid": UUID().uuidString,
            "timestamp": "2026-07-21T12:00:00.000Z",
            "message": [
                "role": "assistant",
                "content": [[
                    "type": "tool_use",
                    "id": "write-plan",
                    "name": "Write",
                    "input": ["file_path": path, "content": "plan"],
                ]],
            ],
        ])
        return String(decoding: data, as: UTF8.self)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func restore(_ value: Any?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
