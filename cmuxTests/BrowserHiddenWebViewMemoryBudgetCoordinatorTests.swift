import AppKit
import Bonsplit
import CmuxBrowser
import WebKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Coverage for https://github.com/manaflow-ai/cmux/issues/15069: by default,
/// hidden panes are discarded only when their web content exceeds the memory
/// budget, and the pane hidden longest goes first.
@MainActor
final class BrowserHiddenWebViewMemoryBudgetCoordinatorTests: XCTestCase {
    private static let policyKeys = [
        BrowserHiddenWebViewDiscardPolicy.enabledKey,
        BrowserHiddenWebViewDiscardPolicy.hiddenDelayKey,
        BrowserHiddenWebViewDiscardPolicy.modeKey,
        BrowserHiddenWebViewDiscardPolicy.memoryBudgetKey
    ]
    private static let megabyte: UInt64 = 1024 * 1024

    private var fixtureDirectory: URL!
    private var hostWindow: NSWindow!
    private var previousPolicyValues: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        for key in Self.policyKeys {
            previousPolicyValues[key] = defaults.object(forKey: key)
        }
        defaults.set(true, forKey: BrowserHiddenWebViewDiscardPolicy.enabledKey)
        defaults.set(0, forKey: BrowserHiddenWebViewDiscardPolicy.hiddenDelayKey)
        defaults.set("budget", forKey: BrowserHiddenWebViewDiscardPolicy.modeKey)
        defaults.set(256, forKey: BrowserHiddenWebViewDiscardPolicy.memoryBudgetKey)
        fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-discard-budget-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        hostWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        hostWindow.isReleasedWhenClosed = false
    }

    override func tearDown() {
        hostWindow.orderOut(nil)
        hostWindow = nil
        if let fixtureDirectory {
            try? FileManager.default.removeItem(at: fixtureDirectory)
        }
        let defaults = UserDefaults.standard
        for key in Self.policyKeys {
            if let value = previousPolicyValues[key] {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        previousPolicyValues = [:]
        super.tearDown()
    }

    func testOverBudgetDiscardsPaneHiddenLongestAndKeepsTheRest() throws {
        let older = try loadPanel(named: "older")
        let newer = try loadPanel(named: "newer")
        defer {
            older.close()
            newer.close()
        }
        let now = Date()
        older.noteWebViewVisibility(false, reason: "test.hidden", now: now.addingTimeInterval(-120))
        newer.noteWebViewVisibility(false, reason: "test.hidden", now: now.addingTimeInterval(-60))
        XCTAssertEqual(older.webViewLifecycleState, .liveHidden)
        XCTAssertFalse(older.hiddenWebViewDiscardManager.hasScheduledDiscard, "Hidden time alone must not arm a discard")

        let coordinator = makeCoordinator(panels: [newer, older])
        XCTAssertEqual(coordinator.enforceBudget(now: now), 1)

        XCTAssertEqual(older.webViewLifecycleState, .discarded)
        XCTAssertEqual(
            older.hiddenWebViewDiscardManager.lastDiscardReason,
            BrowserHiddenWebViewDiscardManager.memoryBudgetReason
        )
        XCTAssertEqual(newer.webViewLifecycleState, .liveHidden)
        XCTAssertEqual(coordinator.enforceBudget(now: now), 0, "Hidden memory is back under the budget")
    }

    func testTimerModeLeavesHiddenPanesToTheTimer() throws {
        UserDefaults.standard.set("timer", forKey: BrowserHiddenWebViewDiscardPolicy.modeKey)
        UserDefaults.standard.set(3600, forKey: BrowserHiddenWebViewDiscardPolicy.hiddenDelayKey)
        let first = try loadPanel(named: "first")
        let second = try loadPanel(named: "second")
        defer {
            first.close()
            second.close()
        }
        first.noteWebViewVisibility(false, reason: "test.hidden")
        second.noteWebViewVisibility(false, reason: "test.hidden")

        XCTAssertEqual(makeCoordinator(panels: [first, second]).enforceBudget(), 0)
        XCTAssertEqual(first.webViewLifecycleState, .liveHidden)
        XCTAssertEqual(second.webViewLifecycleState, .liveHidden)
    }

    /// Dock panes hold web content like workspace panes, so the budget and the
    /// memory-pressure responder must weigh them too.
    func testLiveBrowserPanelsIncludeDockPanes() throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        AppDelegate.shared = appDelegate
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            appDelegate.forgetRecoverableMainWindowRoute(windowId: windowId)
            manager.tabs.forEach { $0.teardownAllPanels() }
            AppDelegate.shared = previousAppDelegate
        }

        let workspace = try XCTUnwrap(manager.addWorkspaceIfActive(select: true))
        let workspaceDock = try XCTUnwrap(workspace.dockSplit)
        let workspaceDockBrowser = try workspaceDock.seedBrowserPanelForBudgetTest(
            BrowserPanel(
                workspaceId: workspaceDock.workspaceId,
                initialURL: try XCTUnwrap(URL(string: "https://example.com/workspace-dock")),
                renderInitialNavigation: false
            )
        )
        let windowDock = appDelegate.windowDock(forWindowId: windowId)
        let windowDockBrowser = try windowDock.seedBrowserPanelForBudgetTest(
            BrowserPanel(
                workspaceId: windowDock.workspaceId,
                initialURL: try XCTUnwrap(URL(string: "https://example.com/window-dock")),
                renderInitialNavigation: false
            )
        )

        let live = appDelegate.allLiveBrowserPanels().map(ObjectIdentifier.init)
        XCTAssertTrue(live.contains(ObjectIdentifier(workspaceDockBrowser)), "Workspace Dock browser must count")
        XCTAssertTrue(live.contains(ObjectIdentifier(windowDockBrowser)), "Window Dock browser must count")
        XCTAssertEqual(live.count, Set(live).count, "Each panel counts once")
    }

    /// Reports a distinct fake process of 200 MB for each loaded panel, so two
    /// hidden panels hold more than the 256 MB budget and one fits.
    private func makeCoordinator(panels: [BrowserPanel]) -> BrowserHiddenWebViewMemoryBudgetCoordinator {
        let processIDs = Dictionary(
            uniqueKeysWithValues: panels.enumerated().map { (ObjectIdentifier($0.element.webView), 1000 + $0.offset) }
        )
        return BrowserHiddenWebViewMemoryBudgetCoordinator(
            processIdentifier: { processIDs[ObjectIdentifier($0)] },
            footprintBytes: { _ in 200 * Self.megabyte },
            browserPanels: { panels }
        )
    }

    private func loadPanel(named name: String) throws -> BrowserPanel {
        let page = fixtureDirectory.appendingPathComponent("\(name).html")
        try "<html><head><title>\(name)</title></head><body>\(name)</body></html>"
            .write(to: page, atomically: true, encoding: .utf8)
        let panel = BrowserPanel(workspaceId: UUID(), initialURL: page, isRemoteWorkspace: false)
        panel.webView.frame = hostWindow.contentView?.bounds ?? .zero
        hostWindow.contentView?.addSubview(panel.webView)
        waitUntil("load of \(name)") {
            panel.webView.url?.standardizedFileURL == page.standardizedFileURL
                && !panel.webView.isLoading
                && !panel.isLoading
        }
        return panel
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        predicate: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        continueAfterFailure = false
        XCTFail("Timed out waiting for \(description)", file: file, line: line)
    }
}

private extension DockSplitStore {
    func seedBrowserPanelForBudgetTest(_ panel: BrowserPanel) throws -> BrowserPanel {
        let pane = try XCTUnwrap(bonsplitController.allPaneIds.first)
        panels[panel.id] = panel
        let tabId = try XCTUnwrap(
            bonsplitController.createTab(
                title: panel.displayTitle,
                icon: panel.displayIcon,
                kind: "browser",
                isDirty: panel.isDirty,
                inPane: pane
            )
        )
        bindSurface(tabId, toPanelId: panel.id)
        return panel
    }
}
