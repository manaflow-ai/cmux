import CmuxSidebar
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("File explorer root sync policy")
struct FileExplorerRootSyncPolicyTests {
    @Test("Hidden right sidebar keeps file explorer root lazy")
    func hiddenRightSidebarKeepsFileExplorerRootLazy() {
        for mode in RightSidebarMode.allCases {
            #expect(
                mode.shouldSyncFileExplorerStore(
                    isRightSidebarVisible: false
                ) == false
            )
        }
    }

    @Test("Visible Files and Find may sync file explorer root")
    func visibleFileModesMaySyncFileExplorerRoot() {
        for mode in [RightSidebarMode.files, .find] {
            #expect(
                mode.shouldSyncFileExplorerStore(
                    isRightSidebarVisible: true
                )
            )
        }
    }

    @Test("Visible non-file modes keep file explorer root lazy")
    func visibleNonFileModesKeepFileExplorerRootLazy() {
        let fileModes = Set([RightSidebarMode.files, .find])
        for mode in RightSidebarMode.allCases.filter({ !fileModes.contains($0) }) {
            #expect(
                mode.shouldSyncFileExplorerStore(
                    isRightSidebarVisible: true
                ) == false
            )
        }
    }
}

@Suite("Right sidebar directory context")
struct RightSidebarDirectoryContextTests {
    @Test("Dock root prefers selected workspace directory")
    func dockRootPrefersSelectedWorkspaceDirectory() {
        #expect(
            RightSidebarMode.dockRootDirectory(
                workspaceDirectory: " /remote/project ",
                fallbackDirectory: "/local/session"
            ) == "/remote/project"
        )
    }

    @Test("Dock root falls back to session index directory")
    func dockRootFallsBackToSessionIndexDirectory() {
        #expect(
            RightSidebarMode.dockRootDirectory(
                workspaceDirectory: " ",
                fallbackDirectory: "/local/session"
            ) == "/local/session"
        )
    }
}
