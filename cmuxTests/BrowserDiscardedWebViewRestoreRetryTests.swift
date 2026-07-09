import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
private func withBrowserDiscardRestoreRetryPolicyEnabled(_ body: (UserDefaults) -> Void) {
    let suiteName = "com.cmux.BrowserDiscardedWebViewRestoreRetryTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.set(true, forKey: BrowserHiddenWebViewDiscardPolicy.enabledKey)
    defaults.set(
        BrowserHiddenWebViewDiscardPolicy.defaultHiddenDelay,
        forKey: BrowserHiddenWebViewDiscardPolicy.hiddenDelayKey
    )
    defer {
        defaults.removePersistentDomain(forName: suiteName)
    }
    body(defaults)
}

@MainActor
private func makeDiscardRestoreRetryBlockerSnapshot() -> BrowserHiddenWebViewDiscardManager.BlockerSnapshot {
    BrowserHiddenWebViewDiscardManager.BlockerSnapshot(
        isClosing: false,
        isVisibleInUI: false,
        shouldRenderWebView: true,
        hasPendingRemoteNavigation: false,
        hasCurrentURL: true,
        isLoading: false,
        webViewIsLoading: false,
        hasActiveMainFrameProvisionalNavigation: false,
        isDownloading: false,
        activeDownloadCount: 0,
        preferredDeveloperToolsVisible: false,
        isDeveloperToolsVisible: false,
        isElementFullscreenActive: false,
        isReactGrabActive: false,
        isVisualAutomationCaptureActive: false,
        hasPopups: false,
        isCapturingMedia: false,
        isPlayingMedia: false
    )
}

@MainActor
@discardableResult
private func waitForDiscardRestoreRetryWebViewToSettle(
    _ panel: BrowserPanel,
    timeout: TimeInterval = 30.0
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while panel.webView.isLoading || panel.isLoading,
          Date() < deadline {
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    return !panel.webView.isLoading && !panel.isLoading
}

@MainActor
@discardableResult
private func waitForDiscardRestoreRetryWebViewToBecomeRetryable(
    _ panel: BrowserPanel,
    timeout: TimeInterval = 20.0
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let restorePending = panel.webViewLifecycleTopPayload()["restore_pending"] as? Bool ?? false
        if !restorePending, !panel.webView.isLoading, !panel.isLoading {
            return true
        }
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    return false
}

@MainActor
@Suite(.serialized)
struct BrowserDiscardedWebViewRestoreRetryTests {
    @Test func discardedManagerRetriesWhenRestoreNeverStartsOrCommits() {
        // RED(#7504): a restore closure that never starts navigation must not consume discard state.
        withBrowserDiscardRestoreRetryPolicyEnabled { defaults in
            let manager = BrowserHiddenWebViewDiscardManager(policyDefaults: defaults)
            manager.markDiscarded(reason: "test.discard", now: Date(timeIntervalSince1970: 100))

            var restoreCount = 0
            #expect(manager.restoreIfNeeded(reason: "test.restore1") {
                restoreCount += 1
            })

            #expect(manager.isDiscardedForMemory)
            #expect(restoreCount == 1)

            #expect(manager.restoreIfNeeded(reason: "test.restore2") {
                restoreCount += 1
            })
            #expect(restoreCount == 2)
        }
    }

    @Test func browserPanelRetriesDiscardedRestoreAfterConnectionRefused() throws {
        // RED(#7504): connection-refused restore must leave the pane retryable on the next restore touch.
        let url = try #require(URL(string: "http://127.0.0.1:1/cmux-issue-7504"))
        let discardedAt = Date(timeIntervalSince1970: 200)
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: url,
            isRemoteWorkspace: false
        )
        defer { panel.close() }

        #expect(waitForDiscardRestoreRetryWebViewToSettle(panel))

        panel.noteWebViewVisibility(false, reason: "test.hidden", now: discardedAt)
        let originalWebView = panel.webView

        #expect(panel.discardHiddenWebViewForMemory(reason: "test.discard", now: discardedAt))
        #expect(panel.webView !== originalWebView)

        #expect(panel.restoreDiscardedWebViewIfNeeded(reason: "test.restore1"))
        #expect(waitForDiscardRestoreRetryWebViewToBecomeRetryable(panel))

        #expect(panel.restoreDiscardedWebViewIfNeeded(reason: "test.restore2"))
    }

    @Test func remoteSessionRestoreQueuedForProxyEndpointDoesNotMarkNavigationPending() throws {
        let url = try #require(URL(string: "http://localhost:3000/cmux-issue-7504"))
        let workspaceId = UUID()
        let panel = BrowserPanel(
            workspaceId: workspaceId,
            isRemoteWorkspace: true,
            remoteWebsiteDataStoreIdentifier: workspaceId
        )
        defer { panel.close() }

        panel.restoreSessionSnapshot(SessionBrowserPanelSnapshot(
            urlString: url.absoluteString,
            profileID: nil,
            shouldRenderWebView: true,
            pageZoom: 1.0,
            developerToolsVisible: false,
            backHistoryURLStrings: [],
            forwardHistoryURLStrings: []
        ))

        #expect(panel.webViewLifecycleState == .discarded)
        #expect(panel.webViewLifecycleTopPayload()["restore_pending"] as? Bool == false)

        #expect(panel.restoreDiscardedWebViewIfNeeded(reason: "test.restore.remote"))

        #expect(panel.hiddenWebViewDiscardSnapshot.hasPendingRemoteNavigation)
        #expect(panel.webViewLifecycleState == .liveHidden)
        #expect(panel.webViewLifecycleTopPayload()["restore_pending"] as? Bool == false)
        #expect(panel.webView.url == nil)
    }
}

// MARK: - GREEN(#7504) new-API coverage (added with the fix)

@MainActor
@Suite(.serialized)
struct BrowserDiscardedWebViewRestoreRetryGreenTests {
    @Test func managerKeepsDiscardStateUntilRestoreNavigationCommits() {
        withBrowserDiscardRestoreRetryPolicyEnabled { defaults in
            let manager = BrowserHiddenWebViewDiscardManager(policyDefaults: defaults)
            manager.markDiscarded(reason: "test.discard", now: Date(timeIntervalSince1970: 300))

            var restoreCount = 0
            #expect(manager.restoreIfNeeded(reason: "test.restore1") {
                restoreCount += 1
            })
            manager.noteRestoreNavigationStarted(reason: "test.navigation1")
            manager.noteRestoreNavigationDidNotCommit(reason: "test.failed")

            #expect(manager.isDiscardedForMemory)
            #expect(!manager.isRestoreNavigationPending)
            #expect(manager.blockers(for: makeDiscardRestoreRetryBlockerSnapshot()).contains("already_discarded"))

            #expect(manager.restoreIfNeeded(reason: "test.restore2") {
                restoreCount += 1
            })
            manager.noteRestoreNavigationStarted(reason: "test.navigation2")
            #expect(manager.noteRestoreNavigationCommitted(reason: "test.commit"))

            #expect(!manager.isDiscardedForMemory)
            #expect(!manager.isRestoreNavigationPending)
            let didRestoreAfterCommit = manager.restoreIfNeeded(reason: "test.restore3") {
                restoreCount += 1
            }
            #expect(!didRestoreAfterCommit)
            #expect(restoreCount == 2)
        }
    }

    @Test func managerDeduplicatesRestoreWhileNavigationIsPending() {
        withBrowserDiscardRestoreRetryPolicyEnabled { defaults in
            let manager = BrowserHiddenWebViewDiscardManager(policyDefaults: defaults)
            manager.markDiscarded(reason: "test.discard", now: Date(timeIntervalSince1970: 400))

            var restoreCount = 0
            #expect(manager.restoreIfNeeded(reason: "test.restore1") {
                restoreCount += 1
            })
            manager.noteRestoreNavigationStarted(reason: "test.navigation")

            #expect(manager.restoreIfNeeded(reason: "test.restore2") {
                restoreCount += 1
            })
            #expect(restoreCount == 1)
            #expect(manager.isRestoreNavigationPending)
        }
    }

    @Test func managerClearsDiscardStateWhenRestoreBecomesDownload() {
        withBrowserDiscardRestoreRetryPolicyEnabled { defaults in
            let manager = BrowserHiddenWebViewDiscardManager(policyDefaults: defaults)
            manager.markDiscarded(reason: "test.discard", now: Date(timeIntervalSince1970: 450))

            #expect(manager.restoreIfNeeded(reason: "test.restore") {})
            manager.noteRestoreNavigationStarted(reason: "test.navigation")
            #expect(manager.noteRestoreNavigationCommitted(reason: "test.download"))

            #expect(!manager.isDiscardedForMemory)
            #expect(!manager.isRestoreNavigationPending)
        }
    }

    @Test func explicitReloadForcesRestartOfPendingRestore() {
        withBrowserDiscardRestoreRetryPolicyEnabled { defaults in
            let manager = BrowserHiddenWebViewDiscardManager(policyDefaults: defaults)
            manager.markDiscarded(reason: "test.discard", now: Date(timeIntervalSince1970: 900))

            var restoreCount = 0
            #expect(manager.restoreIfNeeded(reason: "test.restore") { restoreCount += 1 })
            manager.noteRestoreNavigationStarted(reason: "test.navigation")

            // A plain restore touch is deduplicated while a restore is pending…
            #expect(manager.restoreIfNeeded(reason: "test.touch") { restoreCount += 1 })
            #expect(restoreCount == 1)

            // …but an explicit reload restarts the pending restore.
            #expect(manager.restoreIfNeeded(reason: "test.reload", force: true) { restoreCount += 1 })
            #expect(restoreCount == 2)
            #expect(manager.isDiscardedForMemory)
        }
    }

    @Test func queuedRemoteRestoreDeduplicatesUntilExplicitReload() throws {
        let url = try #require(URL(string: "http://localhost:3000/cmux-issue-7504-dedupe"))
        let workspaceId = UUID()
        let panel = BrowserPanel(
            workspaceId: workspaceId,
            isRemoteWorkspace: true,
            remoteWebsiteDataStoreIdentifier: workspaceId
        )
        defer { panel.close() }

        panel.restoreSessionSnapshot(SessionBrowserPanelSnapshot(
            urlString: url.absoluteString,
            profileID: nil,
            shouldRenderWebView: true,
            pageZoom: 1.0,
            developerToolsVisible: false,
            backHistoryURLStrings: [],
            forwardHistoryURLStrings: []
        ))

        #expect(panel.restoreDiscardedWebViewIfNeeded(reason: "test.restore.remote1"))
        #expect(panel.hiddenWebViewDiscardSnapshot.hasPendingRemoteNavigation)
        #expect(panel.hiddenWebViewDiscardManager.lastRestoreReason == "test.restore.remote1")

        #expect(panel.restoreDiscardedWebViewIfNeeded(reason: "test.restore.remote2"))
        #expect(panel.hiddenWebViewDiscardSnapshot.hasPendingRemoteNavigation)
        #expect(panel.hiddenWebViewDiscardManager.lastRestoreReason == "test.restore.remote1")

        #expect(panel.restoreDiscardedWebViewIfNeeded(
            reason: "test.restore.remote3",
            forceRestartPendingRestore: true
        ))
        #expect(panel.hiddenWebViewDiscardSnapshot.hasPendingRemoteNavigation)
        #expect(panel.hiddenWebViewDiscardManager.lastRestoreReason == "test.restore.remote3")
    }

    @Test func policyCancelledRestoreClearsDiscardStateInsteadOfReplaying() throws {
        let url = try #require(URL(string: "https://example.com/cmux-issue-7504-policy-cancel"))
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: nil,
            renderInitialNavigation: false
        )
        defer { panel.close() }

        panel.restoreSessionSnapshot(SessionBrowserPanelSnapshot(
            urlString: url.absoluteString,
            profileID: nil,
            shouldRenderWebView: true,
            pageZoom: 1.0,
            developerToolsVisible: false,
            backHistoryURLStrings: [],
            forwardHistoryURLStrings: []
        ))
        panel.hiddenWebViewDiscardManager.noteRestoreNavigationStarted(reason: "test.restore")
        panel.navigationDelegate?.recordAttemptedRequest(URLRequest(url: url))

        panel.navigationDelegate?.didCancelNavigationPolicy?(panel.webView, .terminal)
        panel.navigationDelegate?.didCancelProvisionalNavigation?(panel.webView, nil)

        let payload = panel.webViewLifecycleTopPayload()
        #expect(payload["state"] as? String != "discarded")
        #expect(payload["restore_pending"] as? Bool == false)
        #expect((payload["discard_blockers"] as? [String])?.contains("already_discarded") == false)
        #expect(!panel.restoreDiscardedWebViewIfNeeded(reason: "test.reveal"))
    }

    @Test func unknownCancellationAfterClearedAttemptedURLKeepsRestoreRetryable() throws {
        let url = try #require(URL(string: "file:///tmp/cmux-issue-7504-policy-cancel.html"))
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: nil,
            renderInitialNavigation: false
        )
        defer { panel.close() }

        panel.restoreSessionSnapshot(SessionBrowserPanelSnapshot(
            urlString: url.absoluteString,
            profileID: nil,
            shouldRenderWebView: true,
            pageZoom: 1.0,
            developerToolsVisible: false,
            backHistoryURLStrings: [],
            forwardHistoryURLStrings: []
        ))
        panel.hiddenWebViewDiscardManager.noteRestoreNavigationStarted(reason: "test.restore")
        panel.navigationDelegate?.clearAttemptedRequest(discardPendingBypasses: true)

        panel.navigationDelegate?.didCancelProvisionalNavigation?(panel.webView, nil)

        let payload = panel.webViewLifecycleTopPayload()
        #expect(payload["restore_pending"] as? Bool == false)
        #expect((payload["discard_blockers"] as? [String])?.contains("already_discarded") == true)
        #expect(panel.restoreDiscardedWebViewIfNeeded(reason: "test.reveal"))
    }

    @Test func markDiscardedResetsStalePendingRestoreNavigation() {
        withBrowserDiscardRestoreRetryPolicyEnabled { defaults in
            let manager = BrowserHiddenWebViewDiscardManager(policyDefaults: defaults)
            manager.markDiscarded(reason: "test.discard1", now: Date(timeIntervalSince1970: 500))
            #expect(manager.restoreIfNeeded(reason: "test.restore") {})
            manager.noteRestoreNavigationStarted(reason: "test.navigation")
            #expect(manager.isRestoreNavigationPending)

            manager.markDiscarded(reason: "test.discard2", now: Date(timeIntervalSince1970: 501))

            #expect(manager.isDiscardedForMemory)
            #expect(!manager.isRestoreNavigationPending)
        }
    }

    @Test func reactivationWithoutNavigationClearsDiscardState() {
        withBrowserDiscardRestoreRetryPolicyEnabled { defaults in
            let manager = BrowserHiddenWebViewDiscardManager(policyDefaults: defaults)
            manager.markDiscarded(reason: "test.discard", now: Date(timeIntervalSince1970: 600))

            var reactivationCount = 0
            #expect(manager.reactivateWithoutNavigation(reason: "test.reactivate") {
                reactivationCount += 1
            })

            #expect(reactivationCount == 1)
            #expect(!manager.isDiscardedForMemory)
            #expect(!manager.isRestoreNavigationPending)
            #expect(!manager.blockers(for: makeDiscardRestoreRetryBlockerSnapshot()).contains("already_discarded"))

            var restoreCount = 0
            #expect(!manager.restoreIfNeeded(reason: "test.restore") {
                restoreCount += 1
            })
            #expect(restoreCount == 0)
        }
    }

    @Test func mainFrameDownloadCompletesRestoreAndSuppressesBlankShellHeal() throws {
        let url = try #require(URL(string: "http://127.0.0.1:1/cmux-issue-7504-download"))
        let discardedAt = Date(timeIntervalSince1970: 700)
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: url,
            isRemoteWorkspace: false
        )
        defer { panel.close() }

        #expect(waitForDiscardRestoreRetryWebViewToSettle(panel))

        panel.noteWebViewVisibility(false, reason: "test.hidden", now: discardedAt)
        #expect(panel.discardHiddenWebViewForMemory(reason: "test.discard", now: discardedAt))
        #expect(panel.restoreDiscardedWebViewIfNeeded(reason: "test.restore"))

        // Simulate WebKit converting the pending restore navigation into a
        // main-frame download before any document commits.
        panel.navigationDelegate?.didBecomeDownload?(panel.webView, true)

        let payload = panel.webViewLifecycleTopPayload()
        #expect(payload["restore_pending"] as? Bool == false)
        #expect(payload["has_committed_document"] as? Bool == true)
        #expect(payload["state"] as? String != "discarded")

        // A later reveal touch must not blank-shell-heal into re-triggering the
        // download navigation.
        #expect(!panel.restoreDiscardedWebViewIfNeeded(reason: "test.reveal"))
    }

    @Test func aboutBlankDiscardedPaneReactivatesWithoutRestoreNavigation() throws {
        let url = try #require(URL(string: "about:blank"))
        let discardedAt = Date(timeIntervalSince1970: 800)
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: url,
            isRemoteWorkspace: false
        )
        defer { panel.close() }

        #expect(waitForDiscardRestoreRetryWebViewToSettle(panel))

        panel.noteWebViewVisibility(false, reason: "test.hidden", now: discardedAt)
        #expect(panel.discardHiddenWebViewForMemory(reason: "test.discard", now: discardedAt))

        // Restoring a pane whose only URL is about:blank must reactivate in
        // place (no navigation) and fully clear discard bookkeeping instead of
        // waiting on a restore commit that shouldTreatCommitAsDiscardedRestoreCommit ignores.
        #expect(panel.restoreDiscardedWebViewIfNeeded(reason: "test.restore"))

        let payload = panel.webViewLifecycleTopPayload()
        #expect(payload["state"] as? String != "discarded")
        #expect(payload["restore_pending"] as? Bool == false)
        #expect(payload["discard_blockers"] is [String])
        #expect((payload["discard_blockers"] as? [String])?.contains("already_discarded") == false)
    }
}
