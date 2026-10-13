import AppKit
import CmuxSettings
import CmuxTerminalCore
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The Jump to Bottom button (#15382) is an opt-in preview in Beta Features,
/// off by default: a pane scrolled up into scrollback has no button and no
/// overlay view at all until the person turns it on
/// (`terminal.showJumpToBottomButton`).
@MainActor
@Suite("Terminal Jump to Bottom is opt-in", .serialized)
struct TerminalJumpToBottomOptInTests {
    private static let key = TerminalCatalogSection().showJumpToBottomButton.userDefaultsKey
    /// 400 rows of history, the viewport 260 rows above the bottom.
    private static let scrolledUp = GhosttyScrollbar(total: 400, offset: 100, len: 40)

    /// A pane in an offscreen window, fed one scrolled-up scrollbar packet the
    /// way the runtime publishes it.
    private static func scrolledUpPane() -> (NSWindow, GhosttySurfaceScrollView) {
        let hostedView = GhosttySurfaceScrollView(surfaceView: GhosttyNSView(frame: .zero))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView?.addSubview(hostedView)
        hostedView.frame = window.contentView?.bounds ?? .zero
        hostedView.layoutSubtreeIfNeeded()
        hostedView.surfaceView.scrollbar = scrolledUp
        NotificationCenter.default.post(name: .ghosttyDidUpdateScrollbar, object: hostedView.surfaceView,
                                        userInfo: [GhosttyNotificationKey.scrollbar: scrolledUp])
        hostedView.layoutSubtreeIfNeeded()
        return (window, hostedView)
    }

    private static func indicators(in view: NSView) -> [TerminalJumpToBottomIndicatorView] {
        view.subviews.flatMap { subview -> [TerminalJumpToBottomIndicatorView] in
            (subview as? TerminalJumpToBottomIndicatorView).map { [$0] } ?? indicators(in: subview)
        }
    }

    /// Runs `body` with the setting as `value` (nil: never set), then puts back what was there.
    private static func withSetting(_ value: Bool?, _ body: () -> Void) {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: key)
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        defer {
            if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        body()
    }

    @Test("By default a scrolled-up pane has no Jump to Bottom button or overlay")
    func offByDefault() {
        Self.withSetting(nil) {
            #expect(TerminalCatalogSection().showJumpToBottomButton.defaultValue == false)
            let (window, pane) = Self.scrolledUpPane()
            defer { window.close() }
            #expect(Self.indicators(in: pane).isEmpty, "the pane has a Jump to Bottom overlay with the preview off")
        }
    }

    @Test("Turned on in Beta Features, a scrolled-up pane shows the button")
    func onWhenOptedIn() {
        Self.withSetting(true) {
            let (window, pane) = Self.scrolledUpPane()
            defer { window.close() }
            let shown = Self.indicators(in: pane).filter { !$0.isHidden }
            #expect(shown.count == 1, "no Jump to Bottom button with the preview on")
        }
    }
}
