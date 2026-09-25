import AppKit
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized, .exclusiveAppContext)
struct CmuxMainWindowKeyViewLoopTests {
    @Test
    func keyViewPolicySurvivesHostingContentReplacement() {
        let window = makeWindow()
        defer { window.close() }

        #expect(!window.autorecalculatesKeyViewLoop)
        window.contentView = MainWindowHostingView(rootView: TextField("First", text: .constant("")))
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(!window.autorecalculatesKeyViewLoop)
        window.contentView = MainWindowHostingView(rootView: TextField("Replacement", text: .constant("")))
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(!window.autorecalculatesKeyViewLoop)
    }

    @Test
    func tabAndBacktabNavigateBetweenHostedTextFields() throws {
        let window = makeWindow()
        defer { window.close() }
        let host = MainWindowHostingView(rootView: VStack {
            TextField("First", text: .constant(""))
            TextField("Second", text: .constant(""))
        })
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()

        let fields = editableTextFields(in: host)
        let first = try #require(fields.first { $0.placeholderString == "First" })
        let second = try #require(fields.first { $0.placeholderString == "Second" })
        #expect(window.makeFirstResponder(first))
        let firstEditor = try #require(first.currentEditor())
        firstEditor.doCommand(by: #selector(NSResponder.insertTab(_:)))
        #expect(second.currentEditor() === window.firstResponder)
        let secondEditor = try #require(second.currentEditor())
        secondEditor.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
        #expect(first.currentEditor() === window.firstResponder)
        #expect(!window.autorecalculatesKeyViewLoop)
    }

    private func makeWindow() -> CmuxMainWindow {
        let window = CmuxMainWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        return window
    }

    private func editableTextFields(in view: NSView) -> [NSTextField] {
        if let field = view as? NSTextField, field.isEditable { return [field] }
        return view.subviews.flatMap { editableTextFields(in: $0) }
    }
}
