import XCTest
import AppKit
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class InactivePaneFirstClickFocusTests: XCTestCase {
    private let settingsKey = "paneFirstClickFocus.enabled"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: settingsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: settingsKey)
        super.tearDown()
    }

    func testTerminalViewAcceptsFirstMouseWhenSettingEnabled() {
        UserDefaults.standard.set(true, forKey: settingsKey)

        let view = GhosttyNSView(frame: .zero)

        XCTAssertTrue(view.acceptsFirstMouse(for: nil))
    }

    func testTerminalViewRejectsFirstMouseWhenSettingDisabled() {
        UserDefaults.standard.set(false, forKey: settingsKey)

        let view = GhosttyNSView(frame: .zero)

        XCTAssertFalse(view.acceptsFirstMouse(for: nil))
    }

    func testBrowserViewAcceptsFirstMouseWhenSettingEnabled() {
        UserDefaults.standard.set(true, forKey: settingsKey)

        let view = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())

        XCTAssertTrue(view.acceptsFirstMouse(for: nil))
    }

    func testBrowserViewRejectsFirstMouseWhenSettingDisabled() {
        UserDefaults.standard.set(false, forKey: settingsKey)

        let view = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())

        XCTAssertFalse(view.acceptsFirstMouse(for: nil))
    }

    func testMarkdownPointerObserverAcceptsFirstMouseWhenSettingEnabled() {
        UserDefaults.standard.set(true, forKey: settingsKey)

        let view = MarkdownPanelPointerObserverView(frame: .zero)

        XCTAssertTrue(view.acceptsFirstMouse(for: nil))
    }

    func testMarkdownPointerObserverRejectsFirstMouseWhenSettingDisabled() {
        UserDefaults.standard.set(false, forKey: settingsKey)

        let view = MarkdownPanelPointerObserverView(frame: .zero)

        XCTAssertFalse(view.acceptsFirstMouse(for: nil))
    }

    func testPaneFirstClickGateSwallowsWithinGraceWhenSettingDisabled() {
        UserDefaults.standard.set(false, forKey: settingsKey)
        let now = ProcessInfo.processInfo.systemUptime
        PaneFirstClickGate.markActivatedForTesting(at: now)

        XCTAssertTrue(PaneFirstClickGate.shouldSwallowFirstClick(now: now + 0.05))
        XCTAssertTrue(PaneFirstClickGate.shouldSwallowFirstClick(now: now + 0.19))
    }

    func testPaneFirstClickGateAllowsAfterGrace() {
        UserDefaults.standard.set(false, forKey: settingsKey)
        let now = ProcessInfo.processInfo.systemUptime
        PaneFirstClickGate.markActivatedForTesting(at: now)

        XCTAssertFalse(PaneFirstClickGate.shouldSwallowFirstClick(now: now + 1.0))
    }

    func testPaneFirstClickGateAllowsWhenSettingEnabled() {
        UserDefaults.standard.set(true, forKey: settingsKey)
        let now = ProcessInfo.processInfo.systemUptime
        PaneFirstClickGate.markActivatedForTesting(at: now)

        XCTAssertFalse(PaneFirstClickGate.shouldSwallowFirstClick(now: now + 0.05))
    }
}
