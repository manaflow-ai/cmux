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
                FileExplorerRootSyncPolicy.shouldSyncFileExplorerStore(
                    isRightSidebarVisible: false,
                    mode: mode
                ) == false
            )
        }
    }

    @Test("Visible Files and Find may sync file explorer root")
    func visibleFileModesMaySyncFileExplorerRoot() {
        for mode in [RightSidebarMode.files, .find] {
            #expect(
                FileExplorerRootSyncPolicy.shouldSyncFileExplorerStore(
                    isRightSidebarVisible: true,
                    mode: mode
                )
            )
        }
    }

    @Test("Visible non-file modes keep file explorer root lazy")
    func visibleNonFileModesKeepFileExplorerRootLazy() {
        for mode in [RightSidebarMode.sessions, .feed, .dock] {
            #expect(
                FileExplorerRootSyncPolicy.shouldSyncFileExplorerStore(
                    isRightSidebarVisible: true,
                    mode: mode
                ) == false
            )
        }
    }
}
