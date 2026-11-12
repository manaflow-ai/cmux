import AppKit
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Entering Chief Home takes the keyboard from every hidden workspace view,
/// not only terminals (`ChiefHomeNavigation.homeMustTakeFocus`).
@MainActor
@Suite struct ChiefHomeNavigationFocusTests {
    private final class HomeRoot: NSView {}

    @MainActor
    private struct Fixture {
        let window: NSWindow
        let home = HomeRoot()
        let homeField = NSTextField()
        let panel = NSView()
        let portalHost = NSView()
        let portalTerminal = NSView()
        let panelField = NSTextField()

        init() {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: true)
            let content = NSView()
            window.contentView = content
            content.addSubview(panel)
            panel.addSubview(panelField)
            // Portal-hosted views sit beside the SwiftUI content, not inside a panel.
            content.addSubview(portalHost)
            portalHost.addSubview(portalTerminal)
            content.addSubview(home)
            home.addSubview(homeField)
        }

        func mustTake(_ responder: NSResponder?) -> Bool {
            ChiefHomeNavigation.homeMustTakeFocus(from: responder, in: window, isHome: { $0 is HomeRoot })
        }
    }

    @Test func workspaceViewsGiveWay() {
        let f = Fixture()
        #expect(f.mustTake(f.panel))
        #expect(f.mustTake(f.portalTerminal))
        #expect(f.mustTake(f.panelField))
    }

    @Test func homeAndNonViewRespondersKeepFocus() {
        let f = Fixture()
        #expect(!f.mustTake(nil))
        #expect(!f.mustTake(f.window))
        #expect(!f.mustTake(f.home))
        #expect(!f.mustTake(f.homeField))
    }

    @Test func fieldEditorCountsAsItsTextField() {
        let f = Fixture()
        let editor = NSTextView()
        editor.isFieldEditor = true
        // A field editor's delegate is its text field; the Xcode 26.6 SDK does not
        // declare NSTextField as an NSTextViewDelegate in Swift, so set it as AppKit does.
        editor.setValue(f.panelField, forKey: "delegate")
        #expect(f.mustTake(editor))
        editor.setValue(f.homeField, forKey: "delegate")
        #expect(!f.mustTake(editor))
    }

    @Test func viewOfAnotherWindowKeepsFocus() {
        let f = Fixture()
        let other = Fixture()
        #expect(!f.mustTake(other.panel))
    }
}
