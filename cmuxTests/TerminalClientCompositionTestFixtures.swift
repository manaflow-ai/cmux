import CmuxAgentChat
import CmuxFoundation
import CmuxGit
import CmuxRemoteSession
import CmuxSettings
import CmuxSidebarGit
import CmuxTerminalCore
import CmuxWorkspaces
import Foundation

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

/// Production constructors require the process composition. Unit tests that
/// intentionally exercise the legacy in-process terminal opt in here instead
/// of giving Debug app builds an implicit embedded fallback.
extension TabManager {
    @MainActor
    convenience init(
        initialWorkspaceTitle: String? = nil,
        initialWorkingDirectory: String? = nil,
        initialTerminalInput: String? = nil,
        autoWelcomeIfNeeded: Bool = true,
        commandRunner: any CommandRunning = CommandRunner(),
        gitMetadataService: GitMetadataService = GitMetadataService(),
        pullRequestProbeService: PullRequestProbeService? = nil,
        workspaceGitMetadataReader: (any WorkspaceGitMetadataReading)? = nil,
        gitPollClock: any GitPollClock = SystemGitPollClock(),
        gitProbeLimiter: WorkspaceGitMetadataProbeLimiter? = nil,
        focusHistoryNow: @escaping @MainActor @Sendable () -> Date = { Date() },
        panelTitleUpdateCoalescer: NotificationBurstCoalescer? = nil,
        settings: any SettingsWriting = UserDefaultsSettingsClient(defaults: .standard),
        defaultWorkspaceWorkingDirectoryProvider: @escaping () -> String = {
            GhosttyWorkingDirectoryResolver(
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
                processWorkingDirectory: FileManager.default.currentDirectoryPath
            ).resolve(configuredValue: GhosttyConfig.load().workingDirectory)
        },
        workspaceCustomizationStore: WorkspaceCustomizationStore? = nil,
        nativeSSHConnectionBroker: NativeSSHConnectionBroker = NativeSSHConnectionBroker(),
        agentChatResumeIntentRecorder: any AgentChatResumeIntentRecording = AgentChatTranscriptResumeIntentRecorder(),
        closeTabWarningDefaults: UserDefaults = .standard
    ) {
        self.init(
            initialWorkspaceTitle: initialWorkspaceTitle,
            initialWorkingDirectory: initialWorkingDirectory,
            initialTerminalInput: initialTerminalInput,
            autoWelcomeIfNeeded: autoWelcomeIfNeeded,
            terminalClientComposition: .embedded(),
            commandRunner: commandRunner,
            gitMetadataService: gitMetadataService,
            pullRequestProbeService: pullRequestProbeService,
            workspaceGitMetadataReader: workspaceGitMetadataReader,
            gitPollClock: gitPollClock,
            gitProbeLimiter: gitProbeLimiter,
            focusHistoryNow: focusHistoryNow,
            panelTitleUpdateCoalescer: panelTitleUpdateCoalescer,
            settings: settings,
            defaultWorkspaceWorkingDirectoryProvider: defaultWorkspaceWorkingDirectoryProvider,
            workspaceCustomizationStore: workspaceCustomizationStore,
            nativeSSHConnectionBroker: nativeSSHConnectionBroker,
            agentChatResumeIntentRecorder: agentChatResumeIntentRecorder,
            closeTabWarningDefaults: closeTabWarningDefaults
        )
    }
}

extension Workspace {
    @MainActor
    convenience init(
        id: UUID = UUID(),
        title: String = "Terminal",
        workingDirectory: String? = nil,
        portOrdinal: Int = 0,
        configTemplate: CmuxSurfaceConfigTemplate? = nil,
        initialSurface: NewWorkspaceInitialSurface = .terminal,
        initialTerminalCommand: String? = nil,
        initialTerminalInput: String? = nil,
        initialTerminalStartupRestoreAgent: SessionRestorableAgentSnapshot? = nil,
        initialTerminalStartupRestoreCommitOwner: WorkspaceTerminalStartupRestoreCommitOwner = .workspaceTopology,
        initialTerminalEnvironment: [String: String] = [:],
        initialBrowserURL: URL? = nil,
        initialBrowserOmnibarVisible: Bool = true,
        initialBrowserTransparentBackground: Bool = false,
        workspaceEnvironment: [String: String] = [:],
        allowTextBoxFocusDefault: Bool = true,
        settings: any SettingsReading = UserDefaultsSettingsClient(defaults: .standard),
        closeTabWarningDefaults: UserDefaults = .standard,
        agentSessionAutoResumeDefaults: UserDefaults = .standard,
        initialDetachedSurface: DetachedSurfaceTransfer? = nil,
        initialCanonicalBrowserPanel: BrowserPanel? = nil,
        sessionRestorePolicy: WorkspaceSessionRestorePolicyService<SurfaceResumeBindingSnapshot>? = nil,
        sidebarProcessTitleObservation: WorkspaceSidebarProcessTitleObservationModel? = nil,
        initialTerminalSurfaceID: UUID? = nil,
        initialTerminalPaneID: UUID? = nil,
        isCanonicalTopologyProjection: Bool = false,
        agentChatResumeIntentRecorder: any AgentChatResumeIntentRecording = AgentChatTranscriptResumeIntentRecorder(),
        nativeSSHConnectionBroker: NativeSSHConnectionBroker = NativeSSHConnectionBroker()
    ) {
        self.init(
            id: id,
            title: title,
            workingDirectory: workingDirectory,
            portOrdinal: portOrdinal,
            configTemplate: configTemplate,
            initialSurface: initialSurface,
            initialTerminalCommand: initialTerminalCommand,
            initialTerminalInput: initialTerminalInput,
            initialTerminalStartupRestoreAgent: initialTerminalStartupRestoreAgent,
            initialTerminalStartupRestoreCommitOwner: initialTerminalStartupRestoreCommitOwner,
            initialTerminalEnvironment: initialTerminalEnvironment,
            initialBrowserURL: initialBrowserURL,
            initialBrowserOmnibarVisible: initialBrowserOmnibarVisible,
            initialBrowserTransparentBackground: initialBrowserTransparentBackground,
            workspaceEnvironment: workspaceEnvironment,
            allowTextBoxFocusDefault: allowTextBoxFocusDefault,
            settings: settings,
            closeTabWarningDefaults: closeTabWarningDefaults,
            agentSessionAutoResumeDefaults: agentSessionAutoResumeDefaults,
            initialDetachedSurface: initialDetachedSurface,
            initialCanonicalBrowserPanel: initialCanonicalBrowserPanel,
            sessionRestorePolicy: sessionRestorePolicy,
            sidebarProcessTitleObservation: sidebarProcessTitleObservation,
            terminalClientComposition: .embedded(),
            initialTerminalSurfaceID: initialTerminalSurfaceID,
            initialTerminalPaneID: initialTerminalPaneID,
            isCanonicalTopologyProjection: isCanonicalTopologyProjection,
            agentChatResumeIntentRecorder: agentChatResumeIntentRecorder,
            nativeSSHConnectionBroker: nativeSSHConnectionBroker
        )
    }
}

extension DockSplitStore {
    @MainActor
    convenience init(
        workspaceId: UUID,
        scope: DockScope = .workspace,
        baseDirectoryProvider: @escaping () -> String?,
        remoteBrowserSettingsProvider: @escaping () -> DockRemoteBrowserSettings = { .local },
        browserAvailabilityProvider: @escaping () -> Bool = { BrowserAvailabilitySettings.isEnabled() },
        terminalTitleUpdateCoalescer: NotificationBurstCoalescer? = nil,
        settings: any SettingsReading = UserDefaultsSettingsClient(defaults: .standard),
        agentSessionAutoResumeDefaults: UserDefaults = .standard,
        agentChatResumeIntentRecorder: any AgentChatResumeIntentRecording = AgentChatTranscriptResumeIntentRecorder(),
        terminalWorkingDirectoryResolver: TerminalWorkingDirectoryResolver = TerminalWorkingDirectoryResolver(),
        closedItemHistoryStore: ClosedItemHistoryStore? = nil
    ) {
        self.init(
            workspaceId: workspaceId,
            scope: scope,
            terminalClientComposition: .embedded(),
            baseDirectoryProvider: baseDirectoryProvider,
            remoteBrowserSettingsProvider: remoteBrowserSettingsProvider,
            browserAvailabilityProvider: browserAvailabilityProvider,
            terminalTitleUpdateCoalescer: terminalTitleUpdateCoalescer,
            settings: settings,
            agentSessionAutoResumeDefaults: agentSessionAutoResumeDefaults,
            agentChatResumeIntentRecorder: agentChatResumeIntentRecorder,
            terminalWorkingDirectoryResolver: terminalWorkingDirectoryResolver,
            closedItemHistoryStore: closedItemHistoryStore
        )
    }
}
