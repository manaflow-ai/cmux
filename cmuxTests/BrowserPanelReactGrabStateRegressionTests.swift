import AppKit
import Foundation
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Browser Panel React Grab State Regressions", .serialized)
struct BrowserPanelReactGrabStateRegressionTests {
    @Test func activationUpdaterInvocationEmbedsRequestGeneration() throws {
        #expect(
            reactGrabActivationUpdaterInvocation(
                receiver: "existingActivationUpdater",
                active: true,
                requestGeneration: 42
            ) == "existingActivationUpdater(true, '42')"
        )

        let message = try #require(ReactGrabBridgeMessage(body: [
            "type": "stateChange",
            "isActive": true,
            "requestGeneration": "42",
        ]))
        guard case let .stateChange(isActive, requestGeneration) = message else {
            Issue.record("Expected a request-scoped state change")
            return
        }
        #expect(isActive)
        #expect(requestGeneration == 42)
    }

    @Test func stateConfirmationWaitsForMatchingBridgeState() async {
        let confirmation = ReactGrabStateConfirmation(target: true)
        let waiter = Task { await confirmation.wait() }

        confirmation.receive(false)
        await Task.yield()
        confirmation.receive(true)

        #expect(await waiter.value)
    }

    @Test func stateConfirmationExplicitCancellationWinsOverLateBridgeState() async {
        let confirmation = ReactGrabStateConfirmation(target: true)
        confirmation.cancel()
        confirmation.receive(true)

        #expect(!(await confirmation.wait()))
    }

    @Test func stateConfirmationTaskCancellationWinsOverLateBridgeState() async {
        let confirmation = ReactGrabStateConfirmation(target: true)
        let waiter = Task { await confirmation.wait() }

        waiter.cancel()
        #expect(!(await waiter.value))

        confirmation.receive(true)
        #expect(!(await confirmation.wait()))
    }

    @Test func bridgeStateChangeIsTheConfirmedStateAuthority() async {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        let confirmation = ReactGrabStateConfirmation(target: true)
        panel.reactGrabStateConfirmation = confirmation

        panel.handleReactGrabBridgeMessage(.stateChange(isActive: false))
        #expect(!panel.isReactGrabActive)

        panel.handleReactGrabBridgeMessage(.stateChange(isActive: true))
        #expect(panel.isReactGrabActive)
        #expect(await confirmation.wait())
    }

    @Test func latestStateRequestStartsANewReconciliationGeneration() {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }

        #expect(panel.requestReactGrabActive(true, reason: "test.activate"))
        let activationGeneration = panel.reactGrabStateReconciliationGeneration

        #expect(panel.requestReactGrabActive(false, reason: "test.deactivate"))

        #expect(
            panel.reactGrabStateReconciliationGeneration
                == activationGeneration + 1
        )
        #expect(panel.requestedReactGrabActive == false)
    }

    @Test func staleScopedBridgeStateCannotOverwriteNewerRequest() {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }

        #expect(panel.requestReactGrabActive(true, reason: "test.activate"))
        let activationGeneration = panel.reactGrabStateReconciliationGeneration
        #expect(panel.requestReactGrabActive(false, reason: "test.deactivate"))
        let deactivationGeneration = panel.reactGrabStateReconciliationGeneration

        panel.handleReactGrabBridgeMessage(.stateChange(
            isActive: false,
            requestGeneration: deactivationGeneration
        ))
        panel.handleReactGrabBridgeMessage(.stateChange(
            isActive: true,
            requestGeneration: activationGeneration
        ))

        #expect(!panel.isReactGrabActive)
    }

    @Test func completedScopedRequestCannotOverwriteLaterUnscopedState() async {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        panel.handleReactGrabBridgeMessage(.stateChange(isActive: true))

        let confirmed = await panel.requestReactGrabActiveAndWait(
            true,
            reason: "test.alreadyActive"
        )
        let completedGeneration = panel.reactGrabStateReconciliationGeneration

        #expect(confirmed)
        #expect(panel.requestedReactGrabActive == nil)
        #expect(panel.latestReactGrabRequestedState == nil)

        panel.handleReactGrabBridgeMessage(.stateChange(isActive: false))
        panel.handleReactGrabBridgeMessage(.stateChange(
            isActive: true,
            requestGeneration: completedGeneration
        ))

        #expect(!panel.isReactGrabActive)
    }

    @Test func navigationCommitInvalidatesReactGrabStateAndRoundTrip() async throws {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        panel.handleReactGrabBridgeMessage(.stateChange(isActive: true))
        panel.armReactGrabRoundTrip(returnTo: UUID())
        #expect(panel.requestReactGrabActive(true, reason: "test.pending"))
        let pendingConfirmation = ReactGrabStateConfirmation(target: true)
        panel.reactGrabStateConfirmation = pendingConfirmation
        let reconciliationGeneration = panel.reactGrabStateReconciliationGeneration
        let navigationDelegate = try #require(panel.webView.navigationDelegate)

        navigationDelegate.webView?(panel.webView, didCommit: nil)

        #expect(!panel.isReactGrabActive)
        #expect(panel.requestedReactGrabActive == nil)
        #expect(panel.latestReactGrabRequestedState == nil)
        #expect(panel.reactGrabStateReconciliationTask == nil)
        #expect(panel.reactGrabStateConfirmation == nil)
        #expect(panel.pendingReactGrabReturnTargetPanelId == nil)
        #expect(panel.pendingReactGrabRoundTripToken == nil)
        #expect(
            panel.reactGrabStateReconciliationGeneration
                > reconciliationGeneration
        )
        #expect(!(await pendingConfirmation.wait()))
    }

    @Test func webViewReplacementInvalidatesReactGrabStateAndRoundTrip() async {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        let returnPanelID = UUID()

        panel.handleReactGrabBridgeMessage(.stateChange(isActive: true))
        panel.armReactGrabRoundTrip(returnTo: returnPanelID)
        #expect(panel.requestReactGrabActive(true, reason: "test.pending"))
        let pendingConfirmation = ReactGrabStateConfirmation(target: true)
        panel.reactGrabStateConfirmation = pendingConfirmation
        let reconciliationGeneration = panel.reactGrabStateReconciliationGeneration
        let originalWebView = panel.webView

        panel.replaceWebViewPreservingState(
            from: originalWebView,
            websiteDataStore: panel.websiteDataStore,
            reason: "test.replacement"
        )

        #expect(panel.webView !== originalWebView)
        #expect(!panel.isReactGrabActive)
        #expect(panel.requestedReactGrabActive == nil)
        #expect(panel.reactGrabStateReconciliationTask == nil)
        #expect(panel.reactGrabStateConfirmation == nil)
        #expect(panel.pendingReactGrabReturnTargetPanelId == nil)
        #expect(panel.pendingReactGrabRoundTripToken == nil)
        #expect(
            panel.reactGrabStateReconciliationGeneration
                > reconciliationGeneration
        )
        #expect(!(await pendingConfirmation.wait()))
    }

    @Test(.timeLimit(.minutes(1)))
    func toggleCompletesFromVerifiedScriptStateWithoutBridgeCallback() async {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }
        panel.handleReactGrabBridgeMessage(.stateChange(isActive: true))

        let toggleTask = Task { @MainActor in
            await panel.toggleOrInjectReactGrab()
        }

        #expect(await toggleTask.value)
        #expect(!panel.isReactGrabActive)
        #expect(panel.requestedReactGrabActive == nil)
        #expect(panel.reactGrabStateReconciliationTask == nil)
    }

    @Test func ensureActiveConfirmsAndClearsRequestStateWhenAlreadyActive() async throws {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.close() }

        _ = try await panel.evaluateJavaScript(
            """
            window['\(panel.reactGrabBridgeSessionUpdaterName)'] = function(token) {
                window.__cmuxTestRoundTripToken = token;
                return true;
            };
            true;
            """
        )

        panel.handleReactGrabBridgeMessage(.stateChange(isActive: true))
        panel.armReactGrabRoundTrip(returnTo: UUID())
        let token = try #require(panel.pendingReactGrabRoundTripToken)

        let confirmed = await panel.ensureReactGrabActive()

        let refreshedToken = try await panel.evaluateJavaScript(
            "window.__cmuxTestRoundTripToken"
        ) as? String
        #expect(confirmed)
        #expect(refreshedToken == token)
        #expect(panel.requestedReactGrabActive == nil)
        #expect(panel.reactGrabStateReconciliationTask == nil)
    }

    @Test func missingPageAPIFailsActivationButConfirmsInactiveState() async {
        let panel = await loadedBrowserPanel()
        defer { panel.close() }
        panel.reactGrabTestingScriptSourceOverride = ""

        let activated = await panel.ensureReactGrabActive()
        let deactivated = await panel.requestReactGrabActiveAndWait(
            false,
            reason: "test.missingAPI.deactivate"
        )

        #expect(!activated)
        #expect(deactivated)
        #expect(!panel.isReactGrabActive)
        #expect(panel.requestedReactGrabActive == nil)
        #expect(panel.reactGrabStateReconciliationTask == nil)
    }

    private func loadedBrowserPanel() async -> BrowserPanel {
        let panel = BrowserPanel(workspaceId: UUID())
        let (loaded, loadedContinuation) = AsyncStream<Void>.makeStream()
        let existingDidFinish = panel.navigationDelegate?.didFinish
        panel.navigationDelegate?.didFinish = { webView in
            existingDidFinish?(webView)
            loadedContinuation.yield()
            loadedContinuation.finish()
        }
        panel.navigate(to: URL(string: "about:blank")!)
        var iterator = loaded.makeAsyncIterator()
        _ = await iterator.next()
        return panel
    }
}
