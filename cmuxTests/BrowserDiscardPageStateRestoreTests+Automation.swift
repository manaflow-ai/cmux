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
    func testAutomationCommandRestoresPageTerminatedWhileHidden() async throws {
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
        let readiness = await awaitAutomationDocumentReadiness(of: panel, driving: context.webView)
        XCTAssertEqual(readiness, .committed)
        XCTAssertTrue(panel.webView === context.webView, "The command must drive the restored web view")
        XCTAssertFalse(panel.isWebViewVisibleInUI, "The restore must not show the pane")

        await waitForPage(panel, url: pageB, timeout: 10)
        XCTAssertEqual(
            panel.webView.backForwardList.backItem?.url.standardizedFileURL,
            pageA.standardizedFileURL
        )
        await waitUntil("typed input restored", timeout: 10) {
            (await self.evaluate(
                "document.getElementById('name').value + '|' + document.getElementById('notes').value",
                in: panel.webView
            ) as? String) == "typed name|typed notes"
        }
    }

    /// A hidden pane an agent is driving is in use, so the memory budget must
    /// not unload it as the pane hidden longest.
    func testAutomationCommandKeepsHiddenPaneFromMemoryBudget() async throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let page = try writePlainPage()
        let panel = try makeWorkspaceBrowser(in: workspace, url: page)
        defer { panel.close() }
        host(panel.webView)
        await waitForPage(panel, url: page)

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

    /// Repeated agent restores detach every app-owned attachment from the dropped web view.
    func testAutomationRestoreCyclesReleaseDroppedWebViews() async throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let page = try writePlainPage()
        let panel = try makeWorkspaceBrowser(in: workspace, url: page)
        defer { panel.close() }
        host(panel.webView)
        await waitForPage(panel, url: page)
        panel.noteWebViewVisibility(true, reason: "test.visible")
        panel.noteWebViewVisibility(false, reason: "test.hidden")

        let hiddenDelay = BrowserHiddenWebViewDiscardPolicy.hiddenDelay(defaults: .standard)
        for cycle in 1...3 {
            weak var dropped: WKWebView?
            dropped = panel.webView
            XCTAssertTrue(
                panel.discardHiddenWebViewForMemoryBudget(now: Date().addingTimeInterval(hiddenDelay + 1)),
                "Cycle \(cycle) discard refused; blockers: " +
                    "\(panel.webViewLifecycleTopPayload()["discard_blockers"] ?? "unknown")"
            )
            XCTAssertFalse(panel.webView === dropped)
            if let dropped { assertDetached(dropped) }
            await waitForRelease("web view dropped in cycle \(cycle)") { dropped }

            let context = try resolveAutomationContext(for: panel, in: workspace, manager: manager)
            let readiness = await awaitAutomationDocumentReadiness(of: panel, driving: context.webView)
            XCTAssertEqual(readiness, .committed)
            await waitForPage(panel, url: page, timeout: 10)
            await waitUntil("cycle \(cycle) capture released") { panel.pageRestoration.discardedCapture == nil }
        }
    }

    /// A web view whose content process died while hidden is fully detached when restored.
    func testAutomationRestoreReleasesWebViewTerminatedWhileHidden() async throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let page = try writePlainPage()
        let panel = try makeWorkspaceBrowser(in: workspace, url: page)
        defer { panel.close() }
        await waitForPage(panel, url: page)
        panel.noteWebViewVisibility(false, reason: "test.hidden")

        weak var terminated: WKWebView?
        terminated = try terminateWebContent(of: panel)
        let context = try resolveAutomationContext(for: panel, in: workspace, manager: manager)
        XCTAssertFalse(context.webView === terminated)
        let readiness = await awaitAutomationDocumentReadiness(of: panel, driving: context.webView)
        XCTAssertEqual(readiness, .committed)
        if let terminated { assertDetached(terminated) }
        await waitForRelease("web view whose content process died") { terminated }
    }

    private func writePlainPage() throws -> URL {
        let page = fixtureDirectory.appendingPathComponent("plain.html")
        try "<html><head><title>Plain</title></head><body>Plain</body></html>"
            .write(to: page, atomically: true, encoding: .utf8)
        return page
    }

    private func assertDetached(_ webView: WKWebView, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(webView.superview, file: file, line: line)
        XCTAssertNil(webView.navigationDelegate, file: file, line: line)
        XCTAssertNil(webView.uiDelegate, file: file, line: line)
        XCTAssertNil(webView.cmuxBrowserViewportHostView, file: file, line: line)
        if let cmuxWebView = webView as? CmuxWebView {
            XCTAssertNil(cmuxWebView.cmuxDownloadDelegate, file: file, line: line)
            XCTAssertNil(cmuxWebView.browserViewportModel, file: file, line: line)
            XCTAssertNil(cmuxWebView.onBrowserViewportHierarchyChanged, file: file, line: line)
            XCTAssertNil(cmuxWebView.onSubframeDownloadIntent, file: file, line: line)
        }
    }

    private func waitForRelease(
        _ description: String,
        timeout: Duration = .seconds(10),
        file: StaticString = #filePath,
        line: UInt = #line,
        _ object: @escaping () -> AnyObject?
    ) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while object() != nil, ContinuousClock.now < deadline {
            autoreleasepool {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            await Task.yield()
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
    ) async -> BrowserAutomationDocumentReadinessResult {
        await panel.ensureAutomationDocumentReady(
            expectedWebViewIdentifier: ObjectIdentifier(webView),
            reason: "test.automation"
        )
    }
}
