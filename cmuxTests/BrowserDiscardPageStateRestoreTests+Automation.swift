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
        let page = fixtureDirectory.appendingPathComponent("plain.html")
        try "<html><head><title>Plain</title></head><body>Plain</body></html>"
            .write(to: page, atomically: true, encoding: .utf8)
        let panel = try makeWorkspaceBrowser(in: workspace, url: page)
        defer { panel.close() }
        host(panel.webView)
        waitForPage(panel, url: page)

        let hiddenDelay = BrowserHiddenWebViewDiscardPolicy.hiddenDelay(defaults: .standard)
        panel.noteWebViewVisibility(false, reason: "test.hidden", now: Date().addingTimeInterval(-hiddenDelay - 60))
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
