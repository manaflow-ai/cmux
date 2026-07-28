import AppKit
import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct CommandPaletteTypedViewAndIdentifierFixture {
    let previousAppDelegate: AppDelegate?
    let appDelegate: AppDelegate
    let window: NSWindow
    let windowID: UUID
    let tabManager: TabManager
    let selectedWorkspace: Workspace
    let targetWorkspace: Workspace
    let targetPanelID: UUID
    let nonTargetPanelID: UUID
    let context: CommandPaletteActionContext
    let contentView: ContentView

    func cleanup() {
        appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
        window.close()
        AppDelegate.shared = previousAppDelegate
    }
}
