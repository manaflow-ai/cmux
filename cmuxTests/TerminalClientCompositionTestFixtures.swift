import Foundation
import CmuxFoundation
import CmuxGit
import CmuxSettings
import CmuxSidebarGit
import CmuxWorkspaces

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// Production constructors require the process composition. Unit tests that
// intentionally exercise the legacy in-process terminal opt in here instead
// of giving Debug app builds an implicit embedded fallback.
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
        panelTitleUpdateCoalescer: NotificationBurstCoalescer? = nil,
        settings: any SettingsWriting = UserDefaultsSettingsClient(defaults: .standard),
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
            panelTitleUpdateCoalescer: panelTitleUpdateCoalescer,
            settings: settings,
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
        initialTerminalEnvironment: [String: String] = [:],
        initialBrowserURL: URL? = nil,
        initialBrowserOmnibarVisible: Bool = true,
        initialBrowserTransparentBackground: Bool = false,
        workspaceEnvironment: [String: String] = [:],
        allowTextBoxFocusDefault: Bool = true,
        closeTabWarningDefaults: UserDefaults = .standard,
        agentSessionAutoResumeDefaults: UserDefaults = .standard,
        initialDetachedSurface: DetachedSurfaceTransfer? = nil,
        initialCanonicalBrowserPanel: BrowserPanel? = nil,
        sessionRestorePolicy: WorkspaceSessionRestorePolicyService<SurfaceResumeBindingSnapshot>? = nil,
        sidebarProcessTitleObservation: WorkspaceSidebarProcessTitleObservationModel? = nil,
        initialTerminalSurfaceID: UUID? = nil,
        initialTerminalPaneID: UUID? = nil,
        isCanonicalTopologyProjection: Bool = false
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
            initialTerminalEnvironment: initialTerminalEnvironment,
            initialBrowserURL: initialBrowserURL,
            initialBrowserOmnibarVisible: initialBrowserOmnibarVisible,
            initialBrowserTransparentBackground: initialBrowserTransparentBackground,
            workspaceEnvironment: workspaceEnvironment,
            allowTextBoxFocusDefault: allowTextBoxFocusDefault,
            closeTabWarningDefaults: closeTabWarningDefaults,
            agentSessionAutoResumeDefaults: agentSessionAutoResumeDefaults,
            initialDetachedSurface: initialDetachedSurface,
            initialCanonicalBrowserPanel: initialCanonicalBrowserPanel,
            sessionRestorePolicy: sessionRestorePolicy,
            sidebarProcessTitleObservation: sidebarProcessTitleObservation,
            terminalClientComposition: .embedded(),
            initialTerminalSurfaceID: initialTerminalSurfaceID,
            initialTerminalPaneID: initialTerminalPaneID,
            isCanonicalTopologyProjection: isCanonicalTopologyProjection
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
        browserAvailabilityProvider: @escaping () -> Bool = { BrowserAvailabilitySettings.isEnabled() }
    ) {
        self.init(
            workspaceId: workspaceId,
            scope: scope,
            terminalClientComposition: .embedded(),
            baseDirectoryProvider: baseDirectoryProvider,
            remoteBrowserSettingsProvider: remoteBrowserSettingsProvider,
            browserAvailabilityProvider: browserAvailabilityProvider
        )
    }
}
