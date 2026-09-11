import AppKit
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct SidebarSearchFieldTests {
    @Test func hoveringAnUnfocusedSearchFieldUsesTheTextCursor() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let previousCursor = NSCursor.current
        defer { previousCursor.set(); window.close() }
        let field = SidebarSearchField(frame: NSRect(x: 20, y: 20, width: 240, height: SidebarSearchField.visibleHeight))
        window.contentView?.addSubview(field)
        #expect(field.currentEditor() == nil)
        NSCursor.arrow.set()
        field.mouseMoved(with: try hoverEvent(in: field.searchTextBounds, field: field, window: window))
        #expect(NSCursor.current == NSCursor.iBeam)
        #expect(field.currentEditor() == nil)
    }

    @Test func hoveringSearchButtonsKeepsTheArrowCursor() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let previousCursor = NSCursor.current
        defer { previousCursor.set(); window.close() }
        let field = SidebarSearchField(frame: NSRect(x: 20, y: 20, width: 240, height: SidebarSearchField.visibleHeight))
        field.stringValue = "query"
        window.contentView?.addSubview(field)
        for bounds in [field.searchButtonBounds, field.cancelButtonBounds] {
            #expect(!bounds.isEmpty)
            NSCursor.iBeam.set()
            field.mouseMoved(with: try hoverEvent(in: bounds, field: field, window: window))
            #expect(NSCursor.current == NSCursor.arrow)
        }
    }

    private func hoverEvent(in bounds: NSRect, field: SidebarSearchField, window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: field.convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 0, pressure: 0
        ))
    }

    @Test func searchTextAlignsWithSidebarLabelsBeforeAndDuringEditing() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let field = SidebarSearchField(frame: NSRect(x: 4, y: 20, width: 240, height: SidebarSearchField.visibleHeight))
        field.placeholderString = "Search"
        window.contentView?.addSubview(field)
        let expectedLeading: CGFloat = 30
        let placeholderRect = field.cell!.titleRect(forBounds: field.bounds)
        #expect(field.frame.minX + placeholderRect.minX + 2 == expectedLeading)
        field.stringValue = "alpha beta"
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        let insertionRect = editor.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
        let textRect = field.convert(window.convertFromScreen(insertionRect), from: nil)
        #expect(abs(field.frame.minX + textRect.minX - expectedLeading) <= 1)
    }

    @Test func focusedEditorDoesNotOverlapSearchIcon() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let field = SidebarSearchField(frame: NSRect(x: 20, y: 20, width: 240, height: SidebarSearchField.visibleHeight))
        field.stringValue = "alpha beta"
        window.contentView?.addSubview(field)
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        let insertionRect = editor.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
        let textRect = field.convert(window.convertFromScreen(insertionRect), from: nil)
        #expect(textRect.minX >= field.searchButtonBounds.maxX)
    }

    @Test func viewRefreshPreservesMarkedText() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }

        func view(placeholder: String) -> SidebarSearchFieldView {
            SidebarSearchFieldView(
                text: .constant(""), placeholder: placeholder,
                accessibilityIdentifier: "CompositionSearchField",
                onSubmit: {}, onCommandSubmit: {}
            )
        }
        func searchField(in view: NSView) -> SidebarSearchField? {
            if let field = view as? SidebarSearchField { return field }
            return view.subviews.compactMap { searchField(in: $0) }.first
        }

        let host = NSHostingView(rootView: view(placeholder: "Search"))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let field = try #require(searchField(in: host))
        #expect(window.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())

        host.rootView = view(placeholder: "Search updated")
        host.layoutSubtreeIfNeeded()
        let deadline = Date.now.addingTimeInterval(2)
        while field.placeholderString != "Search updated", Date.now < deadline {
            RunLoop.main.run(until: Date.now.addingTimeInterval(0.01))
        }
        #expect(field.placeholderString == "Search updated")
        #expect(editor.hasMarkedText())
        #expect(editor.string == "に")
    }

    @Test func textEditsAndNativeClearUpdateTheBinding() {
        var text = ""
        let coordinator = makeCoordinator(text: Binding(get: { text }, set: { text = $0 }))
        let field = SidebarSearchField(frame: .zero)

        for query in ["session", "日本語", ""] {
            field.stringValue = query
            coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            #expect(text == query)
        }
    }

    @Test func returnPreviewsTheResult() {
        var previews = 0
        var resumes = 0
        let coordinator = makeCoordinator(
            text: .constant("session"),
            onSubmit: { previews += 1 },
            onCommandSubmit: { resumes += 1 }
        )
        let handled = coordinator.control(
            SidebarSearchField(frame: .zero),
            textView: NSTextView(),
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        )
        #expect(handled)
        #expect(previews == 1)
        #expect(resumes == 0)
    }

    @Test func escapeClearsTheEditorAndBindingOnlyWhenNonempty() {
        var text = "session"
        let coordinator = makeCoordinator(text: Binding(get: { text }, set: { text = $0 }))
        let field = SidebarSearchField(frame: .zero)
        let editor = NSTextView()
        field.stringValue = text
        editor.string = text

        #expect(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        #expect(text.isEmpty)
        #expect(field.stringValue.isEmpty)
        #expect(editor.string.isEmpty)
        #expect(!coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
    }

    @Test func markedTextKeepsReturnAndEscapeForInputComposition() {
        var previews = 0
        var text = "session"
        let coordinator = makeCoordinator(
            text: Binding(get: { text }, set: { text = $0 }),
            onSubmit: { previews += 1 }
        )
        let field = SidebarSearchField(frame: .zero)
        field.stringValue = text
        let editor = NSTextView()
        editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))

        for command in [#selector(NSResponder.insertNewline(_:)), #selector(NSResponder.cancelOperation(_:))] {
            #expect(!coordinator.control(field, textView: editor, doCommandBy: command))
        }
        #expect(previews == 0)
        #expect(text == "session")
        #expect(editor.hasMarkedText())
    }

    @Test func commandReturnResumesOnlyTheFocusedSearchField() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let field = SidebarSearchField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        window.contentView?.addSubview(field)
        var resumes = 0
        field.onCommandSubmit = { resumes += 1 }
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
        ))

        #expect(!field.handleCommandSubmit(event))
        #expect(resumes == 0)
        #expect(window.makeFirstResponder(field))
        #expect(field.handleCommandSubmit(event))
        #expect(resumes == 1)

        let editor = try #require(field.currentEditor() as? NSTextView)
        editor.setMarkedText("に", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!field.handleCommandSubmit(event))
        #expect(resumes == 1)
    }

    private func makeCoordinator(
        text: Binding<String>,
        onSubmit: @escaping () -> Void = {},
        onCommandSubmit: @escaping () -> Void = {}
    ) -> SidebarSearchFieldCoordinator {
        SidebarSearchFieldCoordinator(parent: SidebarSearchFieldView(
            text: text,
            placeholder: "Search",
            accessibilityIdentifier: "TestSearchField",
            onSubmit: onSubmit,
            onCommandSubmit: onCommandSubmit
        ))
    }
}
