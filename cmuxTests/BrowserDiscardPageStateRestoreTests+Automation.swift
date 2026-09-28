import AppKit
import CmuxBrowser
import WebKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Agents drive hidden browser panes through socket commands. A hidden page
/// that needs a restore must come back for the command, without anyone
/// showing its pane first.
extension BrowserDiscardPageStateRestoreTests {
    /// A WebContent process that died while its pane was hidden left a web
    /// view that never committed another document, so every command on the
    /// pane timed out until the user showed it.
    func testAutomationCommandRestoresPageTerminatedWhileHidden() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let (panel, pageA, pageB) = try loadScrolledFormPage { url in
            try self.makeWorkspaceBrowser(in: workspace, url: url)
        }
        defer { panel.close() }

        panel.noteWebViewVisibility(false, reason: "test.hidden")
        let terminatedWebView = try terminateWebContent(of: panel)
        terminatedWebView.removeFromSuperview()

        let context = try resolveAutomationContext(for: panel, in: workspace, manager: manager)
        XCTAssertEqual(awaitAutomationDocumentReadiness(of: panel, driving: context.webView), .committed)
        XCTAssertTrue(panel.webView === context.webView, "The command must drive the restored web view")
        XCTAssertFalse(panel.isWebViewVisibleInUI, "The restore must not show the pane")

        waitForPage(panel, url: pageB, timeout: 10)
        XCTAssertEqual(
            panel.webView.backForwardList.backItem?.url.standardizedFileURL,
            pageA.standardizedFileURL
        )
        waitUntil("typed input restored", timeout: 10) {
            (self.evaluate(
                "document.getElementById('name').value + '|' + document.getElementById('notes').value",
                in: panel.webView
            ) as? String) == "typed name|typed notes"
        }
    }

    /// A hidden pane an agent is driving is in use, so the memory budget must
    /// not unload it as the pane hidden longest.
    func testAutomationCommandKeepsHiddenPaneFromMemoryBudget() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let page = try writePlainPage()
        let panel = try makeWorkspaceBrowser(in: workspace, url: page)
        defer { panel.close() }
        host(panel.webView)
        waitForPage(panel, url: page)

        // The workspace may already have recorded the pane hidden, which would
        // keep that hide time; show it first so the backdated hide is recorded.
        let hiddenDelay = BrowserHiddenWebViewDiscardPolicy.hiddenDelay(defaults: .standard)
        let hiddenAt = Date().addingTimeInterval(-hiddenDelay - 60)
        panel.noteWebViewVisibility(true, reason: "test.visible", now: hiddenAt.addingTimeInterval(-1))
        panel.noteWebViewVisibility(false, reason: "test.hidden", now: hiddenAt)
        XCTAssertTrue(
            panel.hiddenWebViewDiscardManager.isEligibleForMemoryBudgetDiscard(),
            "Discard refused; blockers: \(panel.webViewLifecycleTopPayload()["discard_blockers"] ?? "unknown")"
        )

        let commandAt = Date()
        _ = try resolveAutomationContext(for: panel, in: workspace, manager: manager)
        XCTAssertFalse(panel.hiddenWebViewDiscardManager.isEligibleForMemoryBudgetDiscard())
        let budgetPane = panel.hiddenMemoryBudgetPane(now: Date(), processIdentifier: { _ in 1 })
        XCTAssertFalse(budgetPane.isEvictable)
        XCTAssertGreaterThanOrEqual(budgetPane.hiddenAt ?? .distantPast, commandAt)
    }

    /// An agent that keeps waking a hidden pane must not grow memory: each
    /// discard releases the web view it drops, so its WebContent process can
    /// exit, the restored page goes back under the memory budget once idle,
    /// and the captured page state is freed when the restore commits.
    func testAutomationRestoreCyclesReleaseDroppedWebViews() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let page = try writePlainPage()
        let panel = try makeWorkspaceBrowser(in: workspace, url: page)
        defer { panel.close() }
        host(panel.webView)
        waitForPage(panel, url: page)
        panel.noteWebViewVisibility(true, reason: "test.visible")
        panel.noteWebViewVisibility(false, reason: "test.hidden")

        let hiddenDelay = BrowserHiddenWebViewDiscardPolicy.hiddenDelay(defaults: .standard)
        for cycle in 1...3 {
            weak var dropped: WKWebView?
            autoreleasepool {
                let live = panel.webView
                dropped = live
                XCTAssertTrue(
                    panel.discardHiddenWebViewForMemoryBudget(now: Date().addingTimeInterval(hiddenDelay + 1)),
                    "Cycle \(cycle) discard refused; blockers: " +
                        "\(panel.webViewLifecycleTopPayload()["discard_blockers"] ?? "unknown")"
                )
                // Only the first web view sits in the test window, not the pane.
                if cycle == 1 { live.removeFromSuperview() }
            }
            waitForRelease("web view dropped in cycle \(cycle)") { dropped }

            let context = try resolveAutomationContext(for: panel, in: workspace, manager: manager)
            XCTAssertEqual(awaitAutomationDocumentReadiness(of: panel, driving: context.webView), .committed)
            waitForPage(panel, url: page, timeout: 10)
            waitUntil("cycle \(cycle) capture released") { panel.pageRestoration.discardedCapture == nil }
        }
    }

    /// The web view whose content process died while hidden is dropped when
    /// an agent command restores the page, and nothing may keep it alive.
    func testAutomationRestoreReleasesWebViewTerminatedWhileHidden() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let page = try writePlainPage()
        let panel = try makeWorkspaceBrowser(in: workspace, url: page)
        defer { panel.close() }
        waitForPage(panel, url: page)
        panel.noteWebViewVisibility(false, reason: "test.hidden")

        weak var terminated: WKWebView?
        try autoreleasepool {
            terminated = try terminateWebContent(of: panel)
        }
        let context = try resolveAutomationContext(for: panel, in: workspace, manager: manager)
        XCTAssertFalse(context.webView === terminated)
        XCTAssertEqual(awaitAutomationDocumentReadiness(of: panel, driving: context.webView), .committed)
        waitForRelease("web view whose content process died") { terminated }
    }

    private func writePlainPage() throws -> URL {
        let page = fixtureDirectory.appendingPathComponent("plain.html")
        try "<html><head><title>Plain</title></head><body>Plain</body></html>"
            .write(to: page, atomically: true, encoding: .utf8)
        return page
    }

    /// Drains autorelease pools while waiting, so an object only a pending
    /// pool still holds is not reported as leaked.
    private func waitForRelease(
        _ description: String,
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line,
        of object: () -> AnyObject?
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while object() != nil, Date() < deadline {
            autoreleasepool {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
        }
        XCTAssertNil(object(), "\(description) was never released", file: file, line: line)
    }

    private func makeWorkspaceBrowser(in workspace: Workspace, url: URL) throws -> BrowserPanel {
        let pane = try XCTUnwrap(workspace.bonsplitController.focusedPaneId)
        return try XCTUnwrap(workspace.newBrowserSurface(inPane: pane, url: url, focus: false))
    }

    /// Resolves the pane the way every browser socket command does.
    private func resolveAutomationContext(
        for panel: BrowserPanel,
        in workspace: Workspace,
        manager: TabManager
    ) throws -> TerminalController.V2BrowserPanelContext {
        let resolved = TerminalController.shared.v2ResolveBrowserPanelContext(
            params: ["workspace_id": workspace.id.uuidString, "surface_id": panel.id.uuidString],
            tabManager: manager
        )
        XCTAssertNil(resolved.error)
        return try XCTUnwrap(resolved.context)
    }

    /// Waits, as a page-reading command does, for the web view the command
    /// captured to have a document.
    private func awaitAutomationDocumentReadiness(
        of panel: BrowserPanel,
        driving webView: WKWebView
    ) -> BrowserAutomationDocumentReadinessResult? {
        let readiness = AutomationReadinessBox()
        Task {
            readiness.result = await panel.ensureAutomationDocumentReady(
                expectedWebViewIdentifier: ObjectIdentifier(webView),
                reason: "test.automation"
            )
        }
        waitUntil("automation document readiness", timeout: 10) { readiness.result != nil }
        return readiness.result
    }
}

@MainActor
private final class AutomationReadinessBox {
    var result: BrowserAutomationDocumentReadinessResult?
}
