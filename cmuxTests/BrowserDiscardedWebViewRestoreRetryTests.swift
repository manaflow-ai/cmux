import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Reserves an unused loopback port without listening, so WebKit receives a
/// connection refusal instead of rejecting a restricted port such as port 1.
private final class BrowserDiscardRestoreRefusedEndpoint {
    let url: URL
    private let descriptor: Int32

    init(path: String) throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        try #require(descriptor >= 0)
        var initialized = false
        defer { if !initialized { Darwin.close(descriptor) } }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try #require(bindResult == 0)

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        try #require(nameResult == 0)
        let port = UInt16(bigEndian: address.sin_port)
        url = try #require(URL(string: "http://127.0.0.1:\(port)/\(path)"))
        self.descriptor = descriptor
        initialized = true
    }

    deinit { Darwin.close(descriptor) }
}

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
        isMobileBrowserStreamActive: false,
        hasPopups: false,
        isCapturingMedia: false,
        isPlayingMedia: false
    )
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

    @Test func browserPanelRetriesDiscardedRestoreAfterConnectionRefused() async throws {
        // RED(#7504): connection-refused restore must leave the pane retryable on the next restore touch.
        let endpoint = try BrowserDiscardRestoreRefusedEndpoint(path: "cmux-issue-7504")
        defer { withExtendedLifetime(endpoint) {} }
        let url = endpoint.url
        let discardedAt = Date(timeIntervalSince1970: 200)
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: url,
            isRemoteWorkspace: false
        )
        defer { panel.close() }

        try #require(await AppKitTestEventPump().waitUntil(timeout: .seconds(30)) {
            panel.navigationDelegate?.activeErrorPageDisplayURL == url
                && !panel.webView.isLoading && !panel.isLoading
        })

        panel.noteWebViewVisibility(false, reason: "test.hidden", now: discardedAt)
        let originalWebView = panel.webView

        #expect(panel.discardHiddenWebViewForMemory(reason: "test.discard", now: discardedAt))
        #expect(panel.webView !== originalWebView)

        #expect(panel.restoreDiscardedWebViewIfNeeded(reason: "test.restore1"))
        try #require(await AppKitTestEventPump().waitUntil(timeout: .seconds(20)) {
            let restorePending = panel.webViewLifecycleTopPayload()["restore_pending"] as? Bool ?? false
            return panel.navigationDelegate?.activeErrorPageDisplayURL == url
                && !restorePending && !panel.webView.isLoading && !panel.isLoading
        })

        #expect(panel.restoreDiscardedWebViewIfNeeded(reason: "test.restore2"))
    }

    @Test func mobileStreamStartRestoresDiscardedWebView() async throws {
        // RED: streaming a discarded background tab (a restored session's
        // never-revealed pane) mirrors a blank web shell, so the phone shows
        // white until a manual reload. Starting a mobile stream must kick the
        // discard-restore navigation exactly like revealing the tab does.
        let endpoint = try BrowserDiscardRestoreRefusedEndpoint(path: "cmux-mobile-stream-discard")
        defer { withExtendedLifetime(endpoint) {} }
        let url = endpoint.url
        let discardedAt = Date(timeIntervalSince1970: 300)
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: url,
            isRemoteWorkspace: false
        )
        defer { panel.close() }

        try #require(await AppKitTestEventPump().waitUntil(timeout: .seconds(30)) {
            panel.navigationDelegate?.activeErrorPageDisplayURL == url
                && !panel.webView.isLoading && !panel.isLoading
        })

        panel.noteWebViewVisibility(false, reason: "test.hidden", now: discardedAt)
        #expect(panel.discardHiddenWebViewForMemory(reason: "test.discard", now: discardedAt))

        let handlerID = UUID()
        panel.addMobileBrowserStreamSignalHandler(id: handlerID) { _ in }
        defer { panel.removeMobileBrowserStreamSignalHandler(id: handlerID) }

        #expect(
            panel.webViewLifecycleTopPayload()["restore_pending"] as? Bool == true,
            "Mobile stream start must begin the discard-restore navigation"
        )
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
        panel.hiddenWebViewDiscardManager.markDiscarded(reason: "test.discard", now: Date(timeIntervalSince1970: 400))
        panel.noteDiscardedWebViewRestoreNavigationStarted()
        panel.navigationDelegate?.recordAttemptedRequest(URLRequest(url: url))

        panel.navigationDelegate?.didCancelNavigationPolicy?(panel.webView, .terminal(restoreAttemptID: panel.currentDiscardRestoreAttemptID))
        panel.navigationDelegate?.didCancelProvisionalNavigation?(panel.webView, nil)

        let payload = panel.webViewLifecycleTopPayload()
        #expect(payload["state"] as? String != "discarded")
        #expect(payload["restore_pending"] as? Bool == false)
        #expect((payload["discard_blockers"] as? [String])?.contains("already_discarded") == false)
        #expect(!panel.restoreDiscardedWebViewIfNeeded(reason: "test.reveal"))
    }

    @Test func intentBrowserFallbackPolicyCancelStaysRetryableUntilFallbackCommits() throws {
        let intentURLString = [
            "intent://join/abc#Intent",
            "scheme=zoommtg",
            "package=us.zoom.videomeetings",
            "S.browser_fallback_url=https%3A%2F%2Fzoom.us%2Fjoin%2Fabc",
            "end",
        ].joined(separator: ";")
        let intentURL = try #require(URL(string: intentURLString))
        let fallbackURL = try #require(URL(string: "https://zoom.us/join/abc"))
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: nil,
            renderInitialNavigation: false
        )
        defer { panel.close() }

        panel.restoreSessionSnapshot(SessionBrowserPanelSnapshot(
            urlString: intentURL.absoluteString,
            profileID: nil,
            shouldRenderWebView: true,
            pageZoom: 1.0,
            developerToolsVisible: false,
            backHistoryURLStrings: [],
            forwardHistoryURLStrings: []
        ))
        panel.hiddenWebViewDiscardManager.markDiscarded(reason: "test.discard", now: Date(timeIntervalSince1970: 500))
        panel.noteDiscardedWebViewRestoreNavigationStarted()
        panel.navigationDelegate?.recordAttemptedRequest(URLRequest(url: intentURL))
        panel.navigationDelegate?.clearAttemptedRequest(discardPendingBypasses: true)

        var fallbackRequest: URLRequest?
        var terminalCancellationCount = 0
        let handlingResult = browserHandleExternalNavigation(
            intentURL,
            source: "test",
            webView: panel.webView,
            loadFallbackRequest: { fallbackRequest = $0 },
            presentAlert: { _, _, _, cancel in cancel() },
            onTerminalExternalNavigation: { terminalCancellationCount += 1 }
        )
        #expect(handlingResult == .browserFallback)
        #expect(terminalCancellationCount == 0)
        #expect(fallbackRequest?.url == fallbackURL)

        if terminalCancellationCount > 0 {
            panel.navigationDelegate?.didCancelNavigationPolicy?(panel.webView, .terminal(restoreAttemptID: panel.currentDiscardRestoreAttemptID))
        }
        panel.navigationDelegate?.didCancelProvisionalNavigation?(panel.webView, nil)

        let payload = panel.webViewLifecycleTopPayload()
        #expect(payload["restore_pending"] as? Bool == false)
        #expect((payload["discard_blockers"] as? [String])?.contains("already_discarded") == true)
        #expect(panel.restoreDiscardedWebViewIfNeeded(reason: "test.reveal"))
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

    @Test func mainFrameDownloadCompletesRestoreAndSuppressesBlankShellHeal() async throws {
        let endpoint = try BrowserDiscardRestoreRefusedEndpoint(path: "cmux-issue-7504-download")
        defer { withExtendedLifetime(endpoint) {} }
        let url = endpoint.url
        let discardedAt = Date(timeIntervalSince1970: 700)
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: url,
            isRemoteWorkspace: false
        )
        defer { panel.close() }

        try #require(await AppKitTestEventPump().waitUntil(timeout: .seconds(30)) {
            panel.navigationDelegate?.activeErrorPageDisplayURL == url
                && !panel.webView.isLoading && !panel.isLoading
        })

        panel.noteWebViewVisibility(false, reason: "test.hidden", now: discardedAt)
        #expect(panel.discardHiddenWebViewForMemory(reason: "test.discard", now: discardedAt))
        #expect(panel.restoreDiscardedWebViewIfNeeded(reason: "test.restore"))

        // Simulate WebKit converting the pending restore navigation into a
        // main-frame download before any document commits.
        let restoreAttemptID = try #require(panel.currentDiscardRestoreAttemptID)
        panel.navigationDelegate?.didBecomeDownload?(panel.webView, true, restoreAttemptID)

        let payload = panel.webViewLifecycleTopPayload()
        #expect(payload["restore_pending"] as? Bool == false)
        #expect(payload["has_committed_document"] as? Bool == true)
        #expect(payload["state"] as? String != "discarded")

        // A later reveal touch must not blank-shell-heal into re-triggering the
        // download navigation.
        #expect(!panel.restoreDiscardedWebViewIfNeeded(reason: "test.reveal"))
    }

    @Test func aboutBlankDiscardedPaneReactivatesWithoutRestoreNavigation() async throws {
        let url = try #require(URL(string: "about:blank"))
        let discardedAt = Date(timeIntervalSince1970: 800)
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: url,
            isRemoteWorkspace: false
        )
        defer { panel.close() }

        try #require(await AppKitTestEventPump().waitUntil(timeout: .seconds(30)) {
            !panel.webView.isLoading && !panel.isLoading
        })

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
