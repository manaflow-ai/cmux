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
    timeout: TimeInterval = 5.0
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while panel.webView.isLoading || panel.isLoading,
          Date() < deadline {
        _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    return !panel.webView.isLoading && !panel.isLoading
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
        _ = waitForDiscardRestoreRetryWebViewToSettle(panel)

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

    @Test func pureRestoreHealPredicatesCoverBlankShellAndStalledCases() throws {
        let intentURL = try #require(URL(string: "http://127.0.0.1:7777/app"))
        let aboutBlankURL = try #require(URL(string: "about:blank"))
        let mixedCaseAboutBlankURL = try #require(URL(string: "ABOUT:BLANK"))

        #expect(BrowserPanel.isAboutBlankURL(aboutBlankURL))
        #expect(BrowserPanel.isAboutBlankURL(mixedCaseAboutBlankURL))
        #expect(!BrowserPanel.isAboutBlankURL(intentURL))
        #expect(!BrowserPanel.isAboutBlankURL(nil))

        #expect(BrowserPanel.shouldHealBlankShell(
            shouldRenderWebView: true,
            isClosing: false,
            hasPendingRemoteNavigation: false,
            isWebViewLoading: false,
            isMainFrameProvisionalNavigationActive: false,
            hasCommittedDocument: false,
            isNavigationBlockedPendingConsent: false,
            intentURL: intentURL
        ))
        #expect(!BrowserPanel.shouldHealBlankShell(
            shouldRenderWebView: true,
            isClosing: false,
            hasPendingRemoteNavigation: false,
            isWebViewLoading: false,
            isMainFrameProvisionalNavigationActive: false,
            hasCommittedDocument: true,
            isNavigationBlockedPendingConsent: false,
            intentURL: intentURL
        ))
        #expect(!BrowserPanel.shouldHealBlankShell(
            shouldRenderWebView: true,
            isClosing: false,
            hasPendingRemoteNavigation: false,
            isWebViewLoading: false,
            isMainFrameProvisionalNavigationActive: false,
            hasCommittedDocument: false,
            isNavigationBlockedPendingConsent: false,
            intentURL: aboutBlankURL
        ))
        #expect(!BrowserPanel.shouldHealBlankShell(
            shouldRenderWebView: true,
            isClosing: false,
            hasPendingRemoteNavigation: true,
            isWebViewLoading: false,
            isMainFrameProvisionalNavigationActive: false,
            hasCommittedDocument: false,
            isNavigationBlockedPendingConsent: false,
            intentURL: intentURL
        ))
        #expect(!BrowserPanel.shouldHealBlankShell(
            shouldRenderWebView: true,
            isClosing: false,
            hasPendingRemoteNavigation: false,
            isWebViewLoading: false,
            isMainFrameProvisionalNavigationActive: false,
            hasCommittedDocument: false,
            isNavigationBlockedPendingConsent: false,
            intentURL: nil
        ))
        #expect(!BrowserPanel.shouldHealBlankShell(
            shouldRenderWebView: true,
            isClosing: false,
            hasPendingRemoteNavigation: false,
            isWebViewLoading: false,
            isMainFrameProvisionalNavigationActive: false,
            hasCommittedDocument: false,
            isNavigationBlockedPendingConsent: true,
            intentURL: intentURL
        ))

        #expect(BrowserPanel.isRestoreStalled(
            isRestoreNavigationPending: true,
            isWebViewLoading: false,
            isMainFrameProvisionalNavigationActive: false,
            hasPendingRemoteNavigation: false,
            hasCommittedDocument: false
        ))
        #expect(!BrowserPanel.isRestoreStalled(
            isRestoreNavigationPending: true,
            isWebViewLoading: true,
            isMainFrameProvisionalNavigationActive: false,
            hasPendingRemoteNavigation: false,
            hasCommittedDocument: false
        ))
        #expect(!BrowserPanel.isRestoreStalled(
            isRestoreNavigationPending: true,
            isWebViewLoading: false,
            isMainFrameProvisionalNavigationActive: false,
            hasPendingRemoteNavigation: true,
            hasCommittedDocument: false
        ))
        #expect(!BrowserPanel.isRestoreStalled(
            isRestoreNavigationPending: true,
            isWebViewLoading: false,
            isMainFrameProvisionalNavigationActive: false,
            hasPendingRemoteNavigation: false,
            hasCommittedDocument: true
        ))
    }
}
