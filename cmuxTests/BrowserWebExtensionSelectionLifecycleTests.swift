import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct BrowserWebExtensionSelectionLifecycleTests {
    @MainActor
    @Test
    @available(macOS 15.4, *)
    func workspaceTerminalSelectionClearsTheActiveExtensionTab() throws {
        let wasBrowserDisabled = BrowserAvailabilitySettings.isDisabled()
        BrowserAvailabilitySettings.setDisabled(false)
        defer { BrowserAvailabilitySettings.setDisabled(wasBrowserDisabled) }

        let support = BrowserWebExtensionSupport()
        let tabManager = TabManager(browserWebExtensionHost: support)
        let workspace = try #require(tabManager.selectedWorkspace)
        let terminalPanelID = try #require(workspace.focusedPanelId)
        let paneID = try #require(workspace.bonsplitController.allPaneIds.first)
        let browserPanel = try #require(workspace.newBrowserSurface(inPane: paneID, focus: false))
        let window = NSWindow()
        _ = tabManager.setOwningWindow(window)
        defer {
            _ = tabManager.setOwningWindow(nil)
            workspace.teardownAllPanels()
            window.close()
        }

        workspace.focusPanel(browserPanel.id)
        #expect(support.activePanelID(in: window) == browserPanel.id)

        workspace.focusPanel(terminalPanelID)

        #expect(support.activePanelID == nil)
        #expect(support.activePanelID(in: window) == nil)
    }

    @MainActor
    @Test
    @available(macOS 15.4, *)
    func dockTerminalSelectionClearsTheActiveExtensionTab() throws {
        let wasBrowserDisabled = BrowserAvailabilitySettings.isDisabled()
        BrowserAvailabilitySettings.setDisabled(false)
        defer { BrowserAvailabilitySettings.setDisabled(wasBrowserDisabled) }

        let support = BrowserWebExtensionSupport()
        let dock = DockSplitStore(
            workspaceId: UUID(),
            scope: .global,
            baseDirectoryProvider: { nil },
            browserAvailabilityProvider: { true },
            browserWebExtensionHost: support
        )
        let paneID = try #require(dock.resolvePane(requestedPaneID: nil))
        let browserPanelID = try #require(dock.newSurface(kind: .browser, inPane: paneID, focus: true))
        let terminalPanelID = try #require(dock.newSurface(kind: .terminal, inPane: paneID, focus: false))
        let window = NSWindow()
        defer {
            dock.closeAllPanels()
            window.close()
        }
        dock.reconcileBrowserWebExtensionWindows(in: window)

        dock.focusPanel(browserPanelID)
        #expect(support.activePanelID(in: window) == browserPanelID)

        dock.focusPanel(terminalPanelID)

        #expect(support.activePanelID == nil)
        #expect(support.activePanelID(in: window) == nil)
    }
}
