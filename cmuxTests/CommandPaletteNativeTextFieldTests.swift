import AppKit
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
@MainActor
struct CommandPaletteNativeTextFieldTests {
    @Test
    func palettePanelDoesNotUseNativeWindowAnimations() throws {
        let ownerWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let controller = WindowCommandPalettePanelController(ownerWindow: ownerWindow)

        controller.update(
            isVisible: true,
            onDismiss: { _ in },
            onDidBecomeKey: {}
        ) { _, _ in
            AnyView(Color.clear.frame(width: 320, height: 120))
        }

        let panel = try #require(controller.presentedWindow)
        #expect(panel.animationBehavior == .none)

        controller.update(
            isVisible: false,
            onDismiss: { _ in },
            onDidBecomeKey: {}
        ) { _, _ in
            AnyView(EmptyView())
        }
    }

    @Test
    func commandRowsPublishSynchronouslyForFirstPresentation() {
        let model = CommandPaletteOverlayRenderModel()
        let state = CommandPaletteCommandListRenderState(
            resultsVersion: 1,
            emptyStateText: "",
            listIdentity: "commands",
            rows: [
                CommandPaletteRenderResultRow(
                    id: "palette.newTerminalFloatingDock",
                    title: "New Terminal Floating Window",
                    matchedIndices: [],
                    trailingLabel: nil
                )
            ],
            selectedIndex: 0,
            shouldShowEmptyState: false,
            scrollTargetID: nil,
            scrollTargetAnchor: nil
        )

        model.scheduleCommandListUpdate(state)

        #expect(model.commandList == state)
    }

    @Test
    func pendingFocusRequestIsAppliedWhenPanelBecomesKey() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let field = CommandPaletteNativeTextField(frame: NSRect(x: 20, y: 260, width: 440, height: 24))
        window.contentView = NSView(frame: window.contentLayoutRect)
        window.contentView?.addSubview(field)
        _ = window.makeFirstResponder(nil)

        #expect(window.initialFirstResponder === field)
        field.requestsFirstResponder = true
        #expect(window.firstResponder !== field)

        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)

        #expect(window.firstResponder === field || field.currentEditor() != nil)
    }

    @Test
    func cancelledFocusRequestDoesNotApplyWhenPanelBecomesKey() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let field = CommandPaletteNativeTextField(frame: NSRect(x: 20, y: 260, width: 440, height: 24))
        window.contentView = NSView(frame: window.contentLayoutRect)
        window.contentView?.addSubview(field)
        field.requestsFirstResponder = true
        field.requestsFirstResponder = false

        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)

        #expect(window.firstResponder !== field)
        #expect(field.currentEditor() == nil)
    }
}
