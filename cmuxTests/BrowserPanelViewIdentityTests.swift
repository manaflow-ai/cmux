import AppKit
import Bonsplit
import CmuxAppKitSupportUI
import Observation
import SwiftUI
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
        let model = BrowserPanelReplacementModel(panel: firstPanel)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let hostingView = NSHostingView(
            rootView: BrowserPanelReplacementHarness(model: model, paneID: PaneID())
        )
        hostingView.frame = window.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)

        defer {
            window.orderOut(nil)
            window.contentView = nil
            firstPanel.close()
            secondPanel.close()
        }

        let firstField = try #require(waitForOmnibarField(panelID: firstPanel.id, in: window))
        firstField.stringValue = "stale search"
        let firstCoordinator = try #require(
            firstField.delegate as? OmnibarTextFieldRepresentable.Coordinator
        )
        firstCoordinator.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: firstField)
        )
        render(window)
        #expect(firstField.stringValue == "stale search")

        model.panel = secondPanel

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
}

@MainActor
@Observable
private final class BrowserPanelReplacementModel {
    var panel: BrowserPanel

    init(panel: BrowserPanel) {
        self.panel = panel
    }
}

@MainActor
private struct BrowserPanelReplacementHarness: View {
    let model: BrowserPanelReplacementModel
    let paneID: PaneID

    var body: some View {
        PanelContentView(
            panel: model.panel,
            workspaceId: model.panel.workspaceId,
            paneId: paneID,
            isFocused: true,
            isSelectedInPane: true,
            isVisibleInUI: true,
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
            hasUnreadNotification: false,
            terminalAgentContext: "",
            paneOwnershipOverride: true,
            onFocus: {},
            onRequestPanelFocus: {},
            onResumeAgentHibernation: {},
            onAutoResumeAgentHibernation: {},
            onTriggerFlash: {}
        )
    }
}
