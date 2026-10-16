import CmuxMobileRPC
@testable import CmuxMobileShell
@testable import CmuxMobileShellUI
import CmuxMobileShellModel
import Testing

@Test @MainActor func confinedNotificationTapDoesNotFollowSurfaceToAnotherWorkspace() {
    let coordinator = MobilePushCoordinator(registration: InertPushRegistration())
    let store = deeplinkTestStore()
    store.replaceForegroundWorkspaceState(PreviewMobileHost.workspaces)
    coordinator.bind(store: store)

    coordinator.handleTap(
        workspaceId: "workspace-docs",
        surfaceId: "terminal-build",
        macDeviceId: nil,
        retargetsToLiveSurfaceOwner: false
    )
    coordinator.workspacesDidChange()

    #expect(store.selectedWorkspaceID == nil)
    #expect(store.selectedTerminalID == nil)
    #expect(store.deeplinkWorkspaceNavigationRequest == nil)
    #expect(coordinator.tabUnavailableAlert != nil)
}

@Test @MainActor func trustedNotificationTapStillFollowsSurfaceToLiveWorkspace() {
    let coordinator = MobilePushCoordinator(registration: InertPushRegistration())
    let store = deeplinkTestStore()
    store.replaceForegroundWorkspaceState(PreviewMobileHost.workspaces)
    coordinator.bind(store: store)

    coordinator.handleTap(
        workspaceId: "workspace-docs",
        surfaceId: "terminal-build",
        macDeviceId: nil,
        retargetsToLiveSurfaceOwner: true
    )

    #expect(store.selectedWorkspaceID == MobileWorkspacePreview.ID(rawValue: "workspace-main"))
    #expect(store.selectedTerminalID == MobileTerminalPreview.ID(rawValue: "terminal-build"))
}

@Test @MainActor func trustedNotificationTapFollowsMovedSurfaceWhenOriginalWorkspaceRemains() {
    let coordinator = MobilePushCoordinator(registration: InertPushRegistration())
    let store = deeplinkTestStore()
    store.replaceForegroundWorkspaceState([
        MobileWorkspacePreview(
            id: "workspace-docs",
            name: "Docs",
            terminals: []
        ),
        MobileWorkspacePreview(
            id: "workspace-main",
            name: "cmux",
            terminals: [MobileTerminalPreview(id: "terminal-build", name: "Build")]
        ),
    ])
    coordinator.bind(store: store)

    coordinator.handleTap(
        workspaceId: "workspace-docs",
        surfaceId: "terminal-build",
        macDeviceId: nil,
        retargetsToLiveSurfaceOwner: true
    )

    #expect(store.selectedWorkspaceID == MobileWorkspacePreview.ID(rawValue: "workspace-main"))
    #expect(store.selectedTerminalID == MobileTerminalPreview.ID(rawValue: "terminal-build"))
    #expect(coordinator.tabUnavailableAlert == nil)
}

@Test @MainActor func trustedNotificationTapFollowsMovedSurfaceWhenOriginalWorkspaceClosed() {
    let coordinator = MobilePushCoordinator(registration: InertPushRegistration())
    let store = deeplinkTestStore()
    store.replaceForegroundWorkspaceState([
        MobileWorkspacePreview(
            id: "workspace-main",
            name: "cmux",
            terminals: [MobileTerminalPreview(id: "terminal-build", name: "Build")]
        )
    ])
    coordinator.bind(store: store)

    coordinator.handleTap(
        workspaceId: "workspace-docs",
        surfaceId: "terminal-build",
        macDeviceId: nil,
        retargetsToLiveSurfaceOwner: true
    )

    #expect(store.selectedWorkspaceID == MobileWorkspacePreview.ID(rawValue: "workspace-main"))
    #expect(store.selectedTerminalID == MobileTerminalPreview.ID(rawValue: "terminal-build"))
    #expect(coordinator.tabUnavailableAlert == nil)
}

@Test @MainActor func confinedNotificationTapDoesNotReplayWorkspaceWhileSurfaceIsAbsent() {
    let coordinator = MobilePushCoordinator(registration: InertPushRegistration())
    let store = deeplinkTestStore()
    store.replaceForegroundWorkspaceState([
        MobileWorkspacePreview(id: "workspace-docs", name: "Docs", terminals: [])
    ])
    coordinator.bind(store: store)

    coordinator.handleTap(
        workspaceId: "workspace-docs",
        surfaceId: "terminal-notes",
        macDeviceId: nil,
        retargetsToLiveSurfaceOwner: false
    )
    coordinator.workspacesDidChange()

    #expect(store.deeplinkWorkspaceNavigationRequest == nil)
    #expect(coordinator.tabUnavailableAlert != nil)

    store.replaceForegroundWorkspaceState(PreviewMobileHost.workspaces)
    coordinator.workspacesDidChange()
    #expect(store.selectedTerminalID == nil)
}

@Test @MainActor func deviceScopedNotificationTapWaitsForItsMacSnapshot() {
    let coordinator = MobilePushCoordinator(registration: InertPushRegistration())
    let store = deeplinkTestStore()
    store.replaceForegroundWorkspaceState([
        MobileWorkspacePreview(
            id: "workspace-other-mac",
            macDeviceID: "mac-other",
            name: "Other Mac",
            terminals: []
        )
    ])
    coordinator.bind(store: store)

    coordinator.handleTap(
        workspaceId: "workspace-target",
        surfaceId: "terminal-target",
        macDeviceId: "mac-target",
        retargetsToLiveSurfaceOwner: false
    )

    #expect(store.selectedWorkspaceID == nil)
    #expect(coordinator.tabUnavailableAlert == nil)
}
