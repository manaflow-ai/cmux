import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Coverage for "Resume Agents on First Focus" (`terminal.deferAgentResumeUntilFirstFocus`):
/// with auto-resume enabled, a restorable agent panel normally fires its resume
/// command immediately on restore. With this setting also enabled, cmux instead
/// defers that resume into the existing synthetic "agent hibernation" state, so
/// dozens of restored panels don't all launch resume commands at once on
/// startup; the existing focus/visibility-triggered resume fires it lazily.
@MainActor
@Suite("Agent session deferred resume settings", .serialized)
struct AgentSessionDeferredResumeSettingsTests {
    @Test("Defaults key and notification on flip")
    func defaultsKeyAndNotificationOnFlip() throws {
        let suiteName = "cmux-agent-session-deferred-resume-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(
            AgentSessionDeferredResumeSettings.deferUntilFirstFocusKey
                == "terminal.deferAgentResumeUntilFirstFocus"
        )
        #expect(!AgentSessionDeferredResumeSettings.isEnabled(defaults: defaults))

        let notificationCenter = NotificationCenter()
        var notificationCount = 0
        let observer = notificationCenter.addObserver(
            forName: AgentSessionDeferredResumeSettings.didChangeNotification,
            object: nil,
            queue: nil
        ) { _ in
            notificationCount += 1
        }
        defer { notificationCenter.removeObserver(observer) }

        AgentSessionDeferredResumeSettings.setEnabled(
            true,
            defaults: defaults,
            notificationCenter: notificationCenter
        )
        #expect(AgentSessionDeferredResumeSettings.isEnabled(defaults: defaults))
        #expect(notificationCount == 1)

        AgentSessionDeferredResumeSettings.setEnabled(
            true,
            defaults: defaults,
            notificationCenter: notificationCenter
        )
        #expect(notificationCount == 1)

        AgentSessionDeferredResumeSettings.reset(defaults: defaults, notificationCenter: notificationCenter)
        #expect(!AgentSessionDeferredResumeSettings.isEnabled(defaults: defaults))
        #expect(notificationCount == 2)
    }

    /// Default-off path (dock restore): behavior must stay bit-identical to
    /// today's immediate auto-resume when the new setting isn't enabled.
    @Test("Dock restore auto-resumes immediately while the setting is off")
    func deferDisabledMatchesPriorBehaviorOnDockRestore() throws {
        let suiteName = "cmux-agent-session-deferred-resume-dock-off-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let snapshot = try Self.makeDockAgentSnapshot(sessionId: "dock-defer-off-session-\(UUID().uuidString)")
        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil },
            agentSessionAutoResumeDefaults: defaults
        )
        defer { store.closeAllPanels() }

        let restoredIds = store.restoreSessionSnapshot(snapshot)
        let panelId = try #require(restoredIds.values.first)
        let panel = try #require(store.panels[panelId] as? TerminalPanel)

        #expect(!panel.isAgentHibernated)
        let input = panel.surface.debugInitialInputMetadata()
        #expect(input.hasInitialInput)
        #expect(input.byteCount > 0)
    }

    /// With the setting enabled, the dock restore path must skip the immediate
    /// resume and instead enter the same synthetic hibernation state a
    /// snapshot that was already hibernated at quit time would use.
    @Test("Dock restore defers resume into synthetic hibernation when enabled")
    func deferEnabledEntersHibernationOnDockRestore() throws {
        let suiteName = "cmux-agent-session-deferred-resume-dock-on-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        AgentSessionDeferredResumeSettings.setEnabled(true, defaults: defaults)

        let snapshot = try Self.makeDockAgentSnapshot(sessionId: "dock-defer-on-session-\(UUID().uuidString)")
        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil },
            agentSessionAutoResumeDefaults: defaults
        )
        defer { store.closeAllPanels() }

        let restoredIds = store.restoreSessionSnapshot(snapshot)
        let panelId = try #require(restoredIds.values.first)
        let panel = try #require(store.panels[panelId] as? TerminalPanel)

        #expect(panel.isAgentHibernated)
        let input = panel.surface.debugInitialInputMetadata()
        #expect(!input.hasInitialInput)
        #expect(input.byteCount == 0)

        // The existing focus-triggered resume must still be able to wake it.
        #expect(store.resumeAgentHibernation(panelId: panelId, focus: false))
        #expect(!panel.isAgentHibernated)
    }

    /// An agent whose process is already live (so cmux would connect to it as
    /// already-active rather than resuming) must not be forced into hibernation
    /// just because the defer setting is on.
    @Test("Dock restore leaves an already-active agent session alone even when deferring")
    func deferEnabledDoesNotHibernateAlreadyActiveAgent() throws {
        let suiteName = "cmux-agent-session-deferred-resume-dock-active-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        AgentSessionDeferredResumeSettings.setEnabled(true, defaults: defaults)

        let sessionId = "dock-defer-active-session-\(UUID().uuidString)"
        // Pre-claim the resume launch slot the same way a live process would
        // be treated as already active by `sessionAgentAlreadyActive`.
        #expect(AgentResumeLaunchGuard.shared.claimResumeLaunch(kind: RestorableAgentKind.codex.rawValue, sessionId: sessionId))

        let snapshot = try Self.makeDockAgentSnapshot(sessionId: sessionId)
        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil },
            agentSessionAutoResumeDefaults: defaults
        )
        defer {
            store.closeAllPanels()
            AgentResumeLaunchGuard.shared.releaseResumeLaunch(kind: RestorableAgentKind.codex.rawValue, sessionId: sessionId)
        }

        let restoredIds = store.restoreSessionSnapshot(snapshot)
        let panelId = try #require(restoredIds.values.first)
        let panel = try #require(store.panels[panelId] as? TerminalPanel)

        #expect(!panel.isAgentHibernated)
        #expect(!panel.surface.debugInitialInputMetadata().hasInitialInput)
    }

    /// Real-world restores mostly carry a local agent-hook resume binding for
    /// the session (`codex resume …` / `claude --resume …` replayed into the
    /// terminal). Deferring only the agent's own resume command while letting
    /// the binding fire at startup would defeat the setting for exactly those
    /// panels — the original ~90-concurrent-resume storm came from binding
    /// launches (#9145 dogfood).
    @Test("Dock restore defers an agent-hook binding resume into hibernation when enabled")
    func deferEnabledSuppressesAgentHookBindingLaunch() throws {
        let suiteName = "cmux-agent-session-deferred-resume-binding-on-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        AgentSessionDeferredResumeSettings.setEnabled(true, defaults: defaults)

        let snapshot = try Self.makeDockAgentSnapshot(
            sessionId: "dock-defer-binding-on-session-\(UUID().uuidString)",
            includeAgentHookBinding: true
        )
        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil },
            agentSessionAutoResumeDefaults: defaults
        )
        defer { store.closeAllPanels() }

        let restoredIds = store.restoreSessionSnapshot(snapshot)
        let panelId = try #require(restoredIds.values.first)
        let panel = try #require(store.panels[panelId] as? TerminalPanel)

        #expect(panel.isAgentHibernated)
        let input = panel.surface.debugInitialInputMetadata()
        #expect(!input.hasInitialInput)
        #expect(input.byteCount == 0)

        // The existing focus-triggered resume must still be able to wake it.
        #expect(store.resumeAgentHibernation(panelId: panelId, focus: false))
        #expect(!panel.isAgentHibernated)
    }

    /// Default-off companion: without the defer setting, an auto-resume
    /// agent-hook binding keeps firing its startup launch immediately.
    @Test("Dock restore fires an agent-hook binding immediately while the setting is off")
    func deferDisabledKeepsAgentHookBindingLaunch() throws {
        let suiteName = "cmux-agent-session-deferred-resume-binding-off-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let snapshot = try Self.makeDockAgentSnapshot(
            sessionId: "dock-defer-binding-off-session-\(UUID().uuidString)",
            includeAgentHookBinding: true
        )
        let store = DockSplitStore(
            workspaceId: UUID(),
            baseDirectoryProvider: { nil },
            agentSessionAutoResumeDefaults: defaults
        )
        defer { store.closeAllPanels() }

        let restoredIds = store.restoreSessionSnapshot(snapshot)
        let panelId = try #require(restoredIds.values.first)
        let panel = try #require(store.panels[panelId] as? TerminalPanel)

        #expect(!panel.isAgentHibernated)
        let input = panel.surface.debugInitialInputMetadata()
        #expect(input.hasInitialInput)
        #expect(input.byteCount > 0)
    }

    private static func makeDockAgentSnapshot(
        sessionId: String,
        includeAgentHookBinding: Bool = false
    ) throws -> SessionSplitContainerSnapshot {
        let panelId = UUID()
        let agent = SessionRestorableAgentSnapshot(
            kind: .codex,
            sessionId: sessionId,
            workingDirectory: "/tmp/dock-defer-project",
            launchCommand: nil
        )
        let resumeBinding = includeAgentHookBinding
            ? SurfaceResumeBindingSnapshot(
                name: "Codex",
                kind: "codex",
                command: "codex resume \(sessionId)",
                cwd: "/tmp/dock-defer-project",
                checkpointId: sessionId,
                source: "agent-hook",
                autoResume: true,
                updatedAt: 1_777_777_777
            )
            : nil
        let panel = SessionPanelSnapshot(
            id: panelId,
            type: .terminal,
            title: "Agent",
            customTitle: nil,
            directory: "/tmp/dock-defer-project",
            isPinned: false,
            isManuallyUnread: false,
            listeningPorts: [],
            ttyName: "ttys002",
            terminal: SessionTerminalPanelSnapshot(
                workingDirectory: "/tmp/dock-defer-project",
                agent: agent,
                resumeBinding: resumeBinding,
                wasAgentRunning: true
            ),
            browser: nil,
            markdown: nil,
            filePreview: nil,
            rightSidebarTool: nil
        )
        return SessionSplitContainerSnapshot(
            focusedPanelId: panelId,
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [panelId], selectedPanelId: panelId)),
            panels: [panel]
        )
    }
}
