import AppKit
import Bonsplit
import CmuxAppKitSupportUI
import CmuxNotifications
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct BrowserPanelViewIdentityTests {
    @Test func replacingBrowserPanelClearsUncommittedOmnibarDraft() throws {
        let workspaceID = UUID()
        let firstPanel = BrowserPanel(workspaceId: workspaceID)
        let secondPanel = BrowserPanel(workspaceId: workspaceID)
        let paneID = PaneID()
        let contentController = PanelContentViewController(
            configuration: configuration(panel: firstPanel, paneID: paneID)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        contentController.view.frame = window.contentView?.bounds ?? .zero
        contentController.view.autoresizingMask = [.width, .height]
        window.contentViewController = contentController
        window.makeKeyAndOrderFront(nil)

        defer {
            contentController.teardown()
            window.orderOut(nil)
            window.contentViewController = nil
            firstPanel.close()
            secondPanel.close()
        }

        let firstField = try #require(waitForOmnibarField(panelID: firstPanel.id, in: window))
        firstField.stringValue = "stale search"
        let firstCoordinator = try #require(
            firstField.delegate as? OmnibarTextFieldNativeHost.Coordinator
        )
        firstCoordinator.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: firstField)
        )
        render(window)
        #expect(firstField.stringValue == "stale search")

        contentController.update(configuration: configuration(panel: secondPanel, paneID: paneID))

        let secondField = try #require(waitForOmnibarField(panelID: secondPanel.id, in: window))
        #expect(
            secondField.stringValue.isEmpty,
            "A new browser panel must not inherit the previous panel's uncommitted omnibar draft."
        )
    }

    private func waitForOmnibarField(
        panelID: UUID,
        in window: NSWindow,
        timeout: TimeInterval = 1
    ) -> OmnibarNativeTextField? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            render(window)
            if let field = BrowserOmnibarNativeFieldRegistry.shared.field(for: panelID, in: window) {
                return field
            }
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        } while Date() < deadline
        return nil
    }

    private func render(_ window: NSWindow) {
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func configuration(panel: BrowserPanel, paneID: PaneID) -> PanelContentConfiguration {
        PanelContentConfiguration(
            panel: panel,
            workspaceID: panel.workspaceId,
            paneID: paneID,
            isFocused: true,
            isSelectedInPane: true,
            isVisibleInUI: true,
            allowsPointerInput: true,
            pointerEntryEventFilter: nil,
            portalPriority: 1,
            isSplit: false,
            appearance: PanelAppearance(
                backgroundColor: .windowBackgroundColor,
                foregroundColor: .labelColor,
                dividerColor: .clear,
                unfocusedOverlayNSColor: .clear,
                unfocusedOverlayOpacity: 0,
                usesClearContentBackground: false
            ),
            windowAppearance: .rightSidebarPanelViewTestDefault,
            customSidebarTabManager: nil,
            customSidebarUnread: SidebarUnreadModel(),
            hasUnreadNotification: false,
            terminalAgentContext: "",
            paneOwnershipOverride: true,
            terminalPaneOwnershipResolver: nil,
            paneDropZone: nil,
            onFocus: {},
            onRequestPanelFocus: {},
            onResumeAgentHibernation: {},
            onAutoResumeAgentHibernation: {},
            onTriggerFlash: {}
        )
    }
}
