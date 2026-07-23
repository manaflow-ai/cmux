import AppKit
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
        contentView.addSubview(fallbackHost)
        controller.registerRightSidebarHost(fallbackHost)
        defer {
            _ = window.makeFirstResponder(nil)
            fallbackHost.removeFromSuperview()
            window.contentView = nil
            window.orderOut(nil)
        }

        #expect(controller.focusRightSidebar(mode: .artifacts, focusFirstItem: true))
        #expect(controller.debugPendingRightSidebarFocusMode == .artifacts)
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
