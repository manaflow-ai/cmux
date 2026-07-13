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

    #expect(store.selectedWorkspaceID == MobileWorkspacePreview.ID(rawValue: "workspace-docs"))
    #expect(store.selectedTerminalID?.rawValue != "terminal-build")
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
    coordinator.workspacesDidChange()

    #expect(store.selectedWorkspaceID == MobileWorkspacePreview.ID(rawValue: "workspace-main"))
    #expect(store.selectedTerminalID == MobileTerminalPreview.ID(rawValue: "terminal-build"))
}
