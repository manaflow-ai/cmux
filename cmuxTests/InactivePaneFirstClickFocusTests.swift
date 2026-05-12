import XCTest
import AppKit
import SwiftUI
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

    func testMinimalModeSidebarControlsAcceptFirstMouseWhenSettingEnabled() {
        UserDefaults.standard.set(true, forKey: settingsKey)

        let view = MinimalModeSidebarControlActionView(frame: NSRect(x: 0, y: 0, width: 120, height: 32))

        XCTAssertTrue(view.acceptsFirstMouse(for: nil))
    }

    func testMinimalModeSidebarControlsRejectFirstMouseWhenSettingDisabled() {
        UserDefaults.standard.set(false, forKey: settingsKey)

        let view = MinimalModeSidebarControlActionView(frame: NSRect(x: 0, y: 0, width: 120, height: 32))

        XCTAssertFalse(view.acceptsFirstMouse(for: nil))
    }

    func testPDFChromeHostingViewAcceptsFirstMouseWhenSettingEnabled() {
        UserDefaults.standard.set(true, forKey: settingsKey)

        let view = FilePreviewPDFChromeHostingView(rootView: AnyView(EmptyView()))

        XCTAssertTrue(view.acceptsFirstMouse(for: nil))
    }

    func testPDFChromeHostingViewRejectsFirstMouseWhenSettingDisabled() {
        UserDefaults.standard.set(false, forKey: settingsKey)

        let view = FilePreviewPDFChromeHostingView(rootView: AnyView(EmptyView()))

        XCTAssertFalse(view.acceptsFirstMouse(for: nil))
    }

    private struct SidebarFirstClickHarness {
        let tabManager: TabManager
        let initialWorkspace: Workspace
        let targetWorkspace: Workspace
        let window: NSWindow
        let keyWindow: NSWindow
        let host: NSView

        @MainActor
        func close() {
            window.orderOut(nil)
            keyWindow.orderOut(nil)
        }
    }

    private enum SidebarFirstClickHarnessError: Error, CustomStringConvertible {
        case missingAccessibilityElement(String)
        case missingAccessibilityFrame(String)

        var description: String {
            switch self {
            case .missingAccessibilityElement(let identifier):
                return "Missing sidebar accessibility element \(identifier)"
            case .missingAccessibilityFrame(let identifier):
                return "Missing sidebar accessibility frame \(identifier)"
            }
        }
    }

    private typealias AccessibilityNode = NSAccessibilityElementProtocol & NSAccessibilityProtocol

    private struct InactiveFirstClickResult {
        let acceptedFirstMouse: Bool
        let hitViewClassName: String
    }

    private func makeSidebarFirstClickHarness() throws -> SidebarFirstClickHarness {
        let tabManager = TabManager(autoWelcomeIfNeeded: false)
        let initialWorkspace = try XCTUnwrap(tabManager.selectedWorkspace)
        let targetWorkspace = tabManager.addWorkspace(
            title: "Second Workspace",
            select: false,
            eagerLoadTerminal: false,
            autoWelcomeIfNeeded: false
        )
        var selection = SidebarSelection.tabs
        var selectedTabIds: Set<UUID> = [initialWorkspace.id]
        var lastSidebarSelectionIndex: Int? = 0
        let sidebar = VerticalTabsSidebar(
            updateViewModel: UpdateViewModel(),
            fileExplorerState: FileExplorerState(),
            onSendFeedback: {},
            onToggleSidebar: {},
            onNewTab: {},
            selection: Binding(
                get: { selection },
                set: { selection = $0 }
            ),
            selectedTabIds: Binding(
                get: { selectedTabIds },
                set: { selectedTabIds = $0 }
            ),
            lastSidebarSelectionIndex: Binding(
                get: { lastSidebarSelectionIndex },
                set: { lastSidebarSelectionIndex = $0 }
            )
        )
        .environmentObject(tabManager)
        .environmentObject(TerminalNotificationStore.shared)
        let host = NSHostingView(rootView: sidebar)
        let frame = NSRect(x: 0, y: 0, width: 240, height: 360)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let keyWindow = NSWindow(
            contentRect: NSRect(x: 260, y: 0, width: 120, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        host.frame = frame
        window.orderFront(nil)
        keyWindow.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        host.layoutSubtreeIfNeeded()

        XCTAssertFalse(window.isKeyWindow)

        return SidebarFirstClickHarness(
            tabManager: tabManager,
            initialWorkspace: initialWorkspace,
            targetWorkspace: targetWorkspace,
            window: window,
            keyWindow: keyWindow,
            host: host
        )
    }

    private func findAccessibilityElement(
        identifier: String,
        in root: Any,
        visited: inout Set<ObjectIdentifier>
    ) -> AccessibilityNode? {
        guard let element = root as? AccessibilityNode,
              let object = root as? NSObject else {
            return nil
        }
        let objectIdentifier = ObjectIdentifier(object)
        guard visited.insert(objectIdentifier).inserted else { return nil }

        if let elementIdentifier = element.accessibilityIdentifier?(), elementIdentifier == identifier {
            return element
        }

        let children = object.accessibilityAttributeValue(.children) as? [Any] ?? []
        for child in children {
            if let match = findAccessibilityElement(identifier: identifier, in: child, visited: &visited) {
                return match
            }
        }

        let visibleChildren = object.accessibilityAttributeValue(.visibleChildren) as? [Any] ?? []
        for child in visibleChildren {
            if let match = findAccessibilityElement(identifier: identifier, in: child, visited: &visited) {
                return match
            }
        }

        return nil
    }

    private func targetRowPoint(in harness: SidebarFirstClickHarness) throws -> NSPoint {
        let identifier = "sidebarWorkspace.\(harness.targetWorkspace.id.uuidString)"
        var visited = Set<ObjectIdentifier>()
        guard let targetElement = findAccessibilityElement(
            identifier: identifier,
            in: harness.host,
            visited: &visited
        ) else {
            throw SidebarFirstClickHarnessError.missingAccessibilityElement(identifier)
        }
        let targetFrame = targetElement.accessibilityFrame()
        guard !targetFrame.isEmpty else {
            throw SidebarFirstClickHarnessError.missingAccessibilityFrame(identifier)
        }

        let screenCenter = NSPoint(x: targetFrame.midX, y: targetFrame.midY)
        let windowPoint = harness.window.convertPoint(fromScreen: screenCenter)
        XCTAssertTrue(
            harness.host.bounds.contains(windowPoint),
            "Expected \(identifier) center \(windowPoint) to be inside the sidebar host."
        )
        return windowPoint
    }

    private func mouseEvent(
        _ type: NSEvent.EventType,
        at point: NSPoint,
        in window: NSWindow,
        eventNumber: Int,
        pressure: Float
    ) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: eventNumber,
            clickCount: 1,
            pressure: pressure
        ))
    }

    private func sendClick(at point: NSPoint, in window: NSWindow) throws {
        NSApp.sendEvent(try mouseEvent(.leftMouseDown, at: point, in: window, eventNumber: 1, pressure: 1))
        NSApp.sendEvent(try mouseEvent(.leftMouseUp, at: point, in: window, eventNumber: 2, pressure: 0))
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
    }

    private func dispatchInactiveFirstClick(in harness: SidebarFirstClickHarness) throws -> InactiveFirstClickResult {
        let targetRowPoint = try targetRowPoint(in: harness)
        let downEvent = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: targetRowPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: harness.window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
        let hitView = try XCTUnwrap(harness.host.hitTest(targetRowPoint))
        let acceptedFirstMouse = hitView.acceptsFirstMouse(for: downEvent)

        try sendClick(at: targetRowPoint, in: harness.window)
        return InactiveFirstClickResult(
            acceptedFirstMouse: acceptedFirstMouse,
            hitViewClassName: String(describing: type(of: hitView))
        )
    }

    func testWorkspaceSidebarClickSwitchesWorkspaceWhenWindowIsActive() throws {
        UserDefaults.standard.set(true, forKey: settingsKey)

        let harness = try makeSidebarFirstClickHarness()
        defer { harness.close() }

        harness.window.makeKeyAndOrderFront(nil)
        harness.window.displayIfNeeded()
        harness.host.layoutSubtreeIfNeeded()

        XCTAssertTrue(harness.window.isKeyWindow)
        try sendClick(at: try targetRowPoint(in: harness), in: harness.window)
        XCTAssertEqual(harness.tabManager.selectedTabId, harness.targetWorkspace.id)
    }

    func testWorkspaceSidebarInactiveFirstClickSwitchesWorkspaceWhenSettingEnabled() throws {
        UserDefaults.standard.set(true, forKey: settingsKey)

        let harness = try makeSidebarFirstClickHarness()
        defer { harness.close() }

        let result = try dispatchInactiveFirstClick(in: harness)

        XCTAssertTrue(
            result.acceptedFirstMouse,
            "Inactive first click on workspace \(harness.targetWorkspace.id) should pass through when the setting is enabled."
        )
        XCTAssertTrue(harness.window.isKeyWindow)
        XCTAssertFalse(
            result.hitViewClassName.contains("FirstMouseGated"),
            "Enabled inactive sidebar click should not be captured by the production first-mouse gate, got \(result.hitViewClassName)."
        )
        XCTAssertEqual(harness.tabManager.selectedTabId, harness.targetWorkspace.id)
        XCTAssertNotEqual(harness.tabManager.selectedTabId, harness.initialWorkspace.id)
    }

    func testWorkspaceSidebarInactiveFirstClickDoesNotSwitchWorkspaceWhenSettingDisabled() throws {
        UserDefaults.standard.set(false, forKey: settingsKey)

        let harness = try makeSidebarFirstClickHarness()
        defer { harness.close() }

        let result = try dispatchInactiveFirstClick(in: harness)

        XCTAssertFalse(
            result.acceptedFirstMouse,
            "Inactive first click on workspace \(harness.targetWorkspace.id) should activate the window only."
        )
        XCTAssertTrue(harness.window.isKeyWindow)
        XCTAssertTrue(
            result.hitViewClassName.contains("FirstMouseGated"),
            "Expected inactive sidebar click to be captured by the production first-mouse gate, got \(result.hitViewClassName)."
        )
        XCTAssertEqual(harness.tabManager.selectedTabId, harness.initialWorkspace.id)
        XCTAssertNotEqual(harness.tabManager.selectedTabId, harness.targetWorkspace.id)
    }
}
