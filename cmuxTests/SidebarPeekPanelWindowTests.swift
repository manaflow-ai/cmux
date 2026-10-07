import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct SidebarPeekPanelWindowTests {
    @MainActor
    private func makePanel() -> (parent: NSWindow, panel: SidebarPeekPanelWindow) {
        let parent = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let panel = SidebarPeekPanelWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 400))
        parent.addChildWindow(panel, ordered: .above)
        return (parent, panel)
    }

    @Test
    @MainActor
    func plainClicksAndHoverNeverMakeThePanelKey() {
        let (parent, panel) = makePanel()
        defer { parent.removeChildWindow(panel) }
        #expect(!panel.canBecomeKey)
        // A row click makes the table (or a row view) first responder; that
        // must not pull the keyboard away from the terminal.
        let plainView = NSView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        panel.contentView?.addSubview(plainView)
        _ = panel.makeFirstResponder(plainView)
        #expect(!panel.canBecomeKey)
        #expect(!panel.hostsKeyboardEditor)
    }

    @Test
    @MainActor
    func anEditorTakesTheKeyboardAndGivesItBackWhenItEnds() {
        let (parent, panel) = makePanel()
        defer { parent.removeChildWindow(panel) }
        var focusChanges: [Bool] = []
        panel.onKeyboardFocusChange = { focusChanges.append($0) }
        // Same entry as the inline rename: the field asks its window for
        // first responder as soon as it is attached.
        let field = SidebarInlineRenameTextField(string: "workspace")
        field.frame = NSRect(x: 0, y: 0, width: 200, height: 22)
        panel.contentView?.addSubview(field)
        #expect(panel.canBecomeKey)
        #expect(panel.hostsKeyboardEditor)
        #expect(SidebarPeekPanelWindow.takesKeyboardInput(panel.firstResponder))

        // Commit or cancel tears the field down; whichever way first
        // responder moves off the editor, the panel stops taking keys.
        field.removeFromSuperview()
        _ = panel.makeFirstResponder(nil)
        #expect(!panel.canBecomeKey)
        #expect(!panel.hostsKeyboardEditor)
        #expect(focusChanges == [true, false])
    }

    @Test
    @MainActor
    func theEventLoopPassReleasesFocusWhenTheEditorVanishedQuietly() {
        let (parent, panel) = makePanel()
        defer { parent.removeChildWindow(panel) }
        let field = SidebarInlineRenameTextField(string: "workspace")
        field.frame = NSRect(x: 0, y: 0, width: 200, height: 22)
        panel.contentView?.addSubview(field)
        #expect(panel.hostsKeyboardEditor)
        // No makeFirstResponder call here: the next event loop pass alone
        // must notice the editor left the panel.
        field.removeFromSuperview()
        panel.update()
        #expect(!panel.hostsKeyboardEditor)
        #expect(!panel.canBecomeKey)
    }

    @Test
    @MainActor
    func onlyEditableTextTakesKeyboardInput() {
        let label = NSTextField(labelWithString: "title")
        let field = NSTextField(string: "draft")
        let readOnlyText = NSTextView()
        readOnlyText.isEditable = false
        #expect(!SidebarPeekPanelWindow.takesKeyboardInput(nil))
        #expect(!SidebarPeekPanelWindow.takesKeyboardInput(NSView()))
        #expect(!SidebarPeekPanelWindow.takesKeyboardInput(NSTableView()))
        #expect(!SidebarPeekPanelWindow.takesKeyboardInput(label))
        #expect(!SidebarPeekPanelWindow.takesKeyboardInput(readOnlyText))
        #expect(SidebarPeekPanelWindow.takesKeyboardInput(field))
        #expect(SidebarPeekPanelWindow.takesKeyboardInput(NSTextView()))
    }
}
