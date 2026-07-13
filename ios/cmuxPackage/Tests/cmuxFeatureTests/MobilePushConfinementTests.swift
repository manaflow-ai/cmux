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
    let firstNavigationToken = store.deeplinkWorkspaceNavigationRequest?.token
    coordinator.workspacesDidChange()

    #expect(store.selectedWorkspaceID == MobileWorkspacePreview.ID(rawValue: "workspace-docs"))
    #expect(store.selectedTerminalID?.rawValue != "terminal-build")
    #expect(store.deeplinkWorkspaceNavigationRequest?.token == firstNavigationToken)
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
    let firstNavigationToken = store.deeplinkWorkspaceNavigationRequest?.token
    coordinator.workspacesDidChange()

    #expect(firstNavigationToken != nil)
    #expect(store.deeplinkWorkspaceNavigationRequest?.token == firstNavigationToken)
    #expect(store.consumeDeeplinkWorkspaceNavigationRequest()?.rawValue == "workspace-docs")
    coordinator.workspacesDidChange()
    #expect(store.deeplinkWorkspaceNavigationRequest == nil)

    store.replaceForegroundWorkspaceState(PreviewMobileHost.workspaces)
    coordinator.workspacesDidChange()
    #expect(store.selectedTerminalID == MobileTerminalPreview.ID(rawValue: "terminal-notes"))
    #expect(store.deeplinkWorkspaceNavigationRequest == nil)
}
