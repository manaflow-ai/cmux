import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Pure-predicate coverage for the discard-restore heal decision helpers in
/// BrowserDiscardRestoreHeal (blank-shell healing gates and restore-stall
/// detection). Panel-level restore-retry behavior lives in
/// BrowserDiscardedWebViewRestoreRetryTests.
@MainActor
struct BrowserDiscardRestoreHealPredicateTests {
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
            hasRecoverableWebContentTermination: false,
            userStoppedLoad: false,
            isShowingErrorPage: false,
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
            hasRecoverableWebContentTermination: false,
            userStoppedLoad: false,
            isShowingErrorPage: false,
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
            hasRecoverableWebContentTermination: false,
            userStoppedLoad: false,
            isShowingErrorPage: false,
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
            hasRecoverableWebContentTermination: false,
            userStoppedLoad: false,
            isShowingErrorPage: false,
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
            hasRecoverableWebContentTermination: false,
            userStoppedLoad: false,
            isShowingErrorPage: false,
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
            hasRecoverableWebContentTermination: false,
            userStoppedLoad: false,
            isShowingErrorPage: false,
            intentURL: intentURL
        ))
        // A crashed WebContent process must wait for the user's explicit
        // Reload; blank-shell healing never auto-navigates over that gate.
        #expect(!BrowserPanel.shouldHealBlankShell(
            shouldRenderWebView: true,
            isClosing: false,
            hasPendingRemoteNavigation: false,
            isWebViewLoading: false,
            isMainFrameProvisionalNavigationActive: false,
            hasCommittedDocument: false,
            isNavigationBlockedPendingConsent: false,
            hasRecoverableWebContentTermination: true,
            userStoppedLoad: false,
            isShowingErrorPage: false,
            intentURL: intentURL
        ))
        // A load the user explicitly stopped before first commit must stay
        // stopped; a reveal never heals over the Stop.
        #expect(!BrowserPanel.shouldHealBlankShell(
            shouldRenderWebView: true,
            isClosing: false,
            hasPendingRemoteNavigation: false,
            isWebViewLoading: false,
            isMainFrameProvisionalNavigationActive: false,
            hasCommittedDocument: false,
            isNavigationBlockedPendingConsent: false,
            hasRecoverableWebContentTermination: false,
            userStoppedLoad: true,
            isShowingErrorPage: false,
            intentURL: intentURL
        ))
        // The browser's own error page is content awaiting the user's Reload;
        // a reveal never heals over it into re-requesting the failed URL.
        #expect(!BrowserPanel.shouldHealBlankShell(
            shouldRenderWebView: true,
            isClosing: false,
            hasPendingRemoteNavigation: false,
            isWebViewLoading: false,
            isMainFrameProvisionalNavigationActive: false,
            hasCommittedDocument: false,
            isNavigationBlockedPendingConsent: false,
            hasRecoverableWebContentTermination: false,
            userStoppedLoad: false,
            isShowingErrorPage: true,
            intentURL: intentURL
        ))

        #expect(BrowserPanel.isQueuedRemoteRestoreInFlight(
            isDiscardedForMemory: true,
            hasPendingRemoteNavigation: true,
            forceRestartPendingRestore: false
        ))
        #expect(!BrowserPanel.isQueuedRemoteRestoreInFlight(
            isDiscardedForMemory: true,
            hasPendingRemoteNavigation: true,
            forceRestartPendingRestore: true
        ))
        #expect(!BrowserPanel.isQueuedRemoteRestoreInFlight(
            isDiscardedForMemory: false,
            hasPendingRemoteNavigation: true,
            forceRestartPendingRestore: false
        ))
        #expect(!BrowserPanel.isQueuedRemoteRestoreInFlight(
            isDiscardedForMemory: true,
            hasPendingRemoteNavigation: false,
            forceRestartPendingRestore: false
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
