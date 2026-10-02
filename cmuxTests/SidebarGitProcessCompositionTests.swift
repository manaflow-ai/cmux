import Testing
@testable import CmuxGit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct SidebarGitProcessCompositionTests {
    @Test func nonactivatingWindowsShareTheProcessRequestCoordinator() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        let firstWindowId = appDelegate.createMainWindow(shouldActivate: false)
        let secondWindowId = appDelegate.createMainWindow(shouldActivate: false)
        defer {
            _ = appDelegate.closeMainWindow(windowId: secondWindowId, recordHistory: false)
            _ = appDelegate.closeMainWindow(windowId: firstWindowId, recordHistory: false)
            AppDelegate.shared = previousAppDelegate
        }

        let firstManager = try #require(appDelegate.tabManagerFor(windowId: firstWindowId))
        let secondManager = try #require(appDelegate.tabManagerFor(windowId: secondWindowId))
        let processCoordinator = appDelegate.pullRequestProbeService.requestCoordinator

        #expect(firstManager.pullRequestProbeService.requestCoordinator === processCoordinator)
        #expect(secondManager.pullRequestProbeService.requestCoordinator === processCoordinator)
    }
}
