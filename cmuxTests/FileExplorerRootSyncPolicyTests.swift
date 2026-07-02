import AppKit
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

@MainActor
@Suite("Right sidebar keyboard navigation")
struct RightSidebarKeyboardNavigationTests {
    @Test("Return and keypad Enter open the selected item")
    func returnAndKeypadEnterOpenSelection() throws {
        for keyCode in [UInt16(36), UInt16(76)] {
            let event = try #require(Self.keyEvent(keyCode: keyCode, modifierFlags: []))
            #expect(event.isFileExplorerOpenSelectionShortcut(in: FileExplorerPanelPlacement.rightSidebar))
        }
    }

    @Test("Command Down opens the selected item")
    func commandDownOpensSelection() throws {
        let event = try #require(Self.keyEvent(keyCode: 125, modifierFlags: [.command]))
        #expect(event.isFileExplorerOpenSelectionShortcut(in: FileExplorerPanelPlacement.rightSidebar))
    }

    @Test("Plain Down, Shift Return, and Command Return keep their existing routes")
    func nonActivationKeysDoNotOpenSelection() throws {
        let plainDown = try #require(Self.keyEvent(keyCode: 125, modifierFlags: []))
        let shiftReturn = try #require(Self.keyEvent(keyCode: 36, modifierFlags: [.shift]))
        let commandReturn = try #require(Self.keyEvent(keyCode: 36, modifierFlags: [.command]))

        #expect(!plainDown.isFileExplorerOpenSelectionShortcut(in: FileExplorerPanelPlacement.rightSidebar))
        #expect(!shiftReturn.isFileExplorerOpenSelectionShortcut(in: FileExplorerPanelPlacement.rightSidebar))
        #expect(!commandReturn.isFileExplorerOpenSelectionShortcut(in: FileExplorerPanelPlacement.rightSidebar))
    }

    private static func keyEvent(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        )
    }
}
