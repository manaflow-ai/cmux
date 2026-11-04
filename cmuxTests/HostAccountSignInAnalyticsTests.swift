import CMUXAuthCore
import CMUXMobileCore
import CmuxAuthRuntime
import CmuxCloud
import CmuxProductAnalytics
import Foundation
import Observation
import os
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The sign-in funnel as PostHog receives it: the real account flow, browser
/// sign-in flow, auth coordinator and analytics pipeline, with only the
/// browser window and the network faked. The fixture account starts signed
/// in, as for Switch Account or a socket sign-in on a signed-in app.
@MainActor
@Suite("Sign-in funnel analytics", .serialized)
struct HostAccountSignInAnalyticsTests {
    @Test("a sign-in that ends on the same account still succeeds, joined by one attempt id")
    func sameAccountSignInSucceeds() async throws {
        let harness = try await SignInAnalyticsHarness.make()

        _ = harness.flow.startSignInForPane()
        let session = await harness.sessions.session(0)
        session.deliver(harness.callback(for: session))
        await harness.waitForAttemptToEnd()

        let events = await harness.signInEvents()
        #expect(events.map(\.name) == [
            "cmux_sign_in_started", "cmux_sign_in_callback_received", "cmux_sign_in_succeeded",
        ])
        #expect(events[0].string("entrypoint") == "pane")
        #expect(events[0].string("start_outcome") == "opened")
        #expect(events[0].properties["replaced_pending"] == .bool(false))
        #expect(events[1].string("delivery") == "sign_in_window")
        #expect(events[1].string("attempt_link") == "state")
        #expect(events[2].string("attempt_link") == "state")
        #expect(Set(events.compactMap { $0.string("attempt_id") }).count == 1)
        harness.tearDown()
    }

    @Test("closing the window is not a failure, and a late default-browser callback succeeds for the same attempt")
    func windowCloseThenLateCallback() async throws {
        let harness = try await SignInAnalyticsHarness.make()

        harness.flow.startSignIn()
        let session = await harness.sessions.session(0)
        let callback = harness.callback(for: session)
        session.deliver(.cancelled(reason: HostBrowserAuthSessionResult.userClosedWindowReason))
        await harness.waitForAttemptToEnd()
        harness.flow.syncAnalytics()
        #expect(await harness.signInEvents().map(\.name) == ["cmux_sign_in_started", "cmux_sign_in_window_closed"])

        #expect(await harness.flow.handleCallbackURL(callback, delivery: .external))
        let events = await harness.signInEvents()
        #expect(events.map(\.name) == [
            "cmux_sign_in_started", "cmux_sign_in_window_closed",
            "cmux_sign_in_callback_received", "cmux_sign_in_succeeded",
        ])
        #expect(events[0].string("entrypoint") == "app")
        #expect(events[2].string("delivery") == "external")
        #expect(Set(events.compactMap { $0.string("attempt_id") }).count == 1)
        harness.tearDown()
    }

    @Test("a retry while the first attempt is open starts a new attempt that says it replaced one")
    func retryReplacesPendingAttempt() async throws {
        let harness = try await SignInAnalyticsHarness.make()

        harness.flow.startSignIn()
        let first = await harness.sessions.session(0)
        harness.flow.startSignIn()
        let retry = await harness.sessions.session(1)
        // The replaced window reports a close after the app cancelled it.
        first.deliver(.cancelled(reason: HostBrowserAuthSessionResult.userClosedWindowReason))
        retry.deliver(harness.callback(for: retry))
        await harness.waitForAttemptToEnd()
        // The same callback delivered again (a second browser hop) is refused
        // and adds nothing.
        #expect(await harness.flow.handleCallbackURL(harness.callback(for: retry), delivery: .external) == false)
        harness.flow.syncAnalytics()

        let events = await harness.signInEvents()
        #expect(events.map(\.name) == [
            "cmux_sign_in_started", "cmux_sign_in_started",
            "cmux_sign_in_callback_received", "cmux_sign_in_succeeded",
        ])
        #expect(events[0].properties["replaced_pending"] == .bool(false))
        #expect(events[1].properties["replaced_pending"] == .bool(true))
        let firstID = try #require(events[0].string("attempt_id"))
        let retryID = try #require(events[1].string("attempt_id"))
        #expect(firstID != retryID)
        #expect(events[0].string("replaced_attempt_id") == nil)
        #expect(events[1].string("replaced_attempt_id") == firstID)
        #expect(events[2...].allSatisfy { $0.string("attempt_id") == retryID })
        harness.tearDown()
    }

    @Test("an old tab's callback after a newer start is credited to the attempt that issued it, not the newer one")
    func oldTabCallbackAfterNewerStart() async throws {
        let harness = try await SignInAnalyticsHarness.make()

        harness.flow.startSignIn()
        let first = await harness.sessions.session(0)
        let oldTabCallback = harness.callback(for: first)
        harness.flow.startSignIn()
        _ = await harness.sessions.session(1)

        // The replaced attempt's browser tab finishes through LaunchServices
        // while the retry's window is still open.
        #expect(await harness.flow.handleCallbackURL(oldTabCallback, delivery: .external))
        await harness.waitForAttemptToEnd()
        harness.flow.syncAnalytics()

        let events = await harness.signInEvents()
        #expect(events.map(\.name) == [
            "cmux_sign_in_started", "cmux_sign_in_started",
            "cmux_sign_in_callback_received", "cmux_sign_in_succeeded",
        ])
        let firstID = try #require(events[0].string("attempt_id"))
        let retryID = try #require(events[1].string("attempt_id"))
        #expect(firstID != retryID)
        #expect(events[1].properties["replaced_pending"] == .bool(true))
        #expect(events[2].string("delivery") == "external")
        // The success ended the retry too; it gets no result of its own.
        #expect(events[2...].allSatisfy { $0.string("attempt_id") == firstID && $0.string("attempt_link") == "state" })
        harness.tearDown()
    }

    @Test("an old tab's callback that fails is the old attempt's failure; the newer attempt stays open and can succeed")
    func oldTabFailureDoesNotEndNewerAttempt() async throws {
        let harness = try await SignInAnalyticsHarness.make()

        harness.flow.startSignIn()
        let first = await harness.sessions.session(0)
        // The old tab's callback carries the first attempt's state with an
        // unreadable token payload, so completion refuses it.
        let brokenOldTab = URL(string: "cmux://auth-callback?cmux_auth_state=\(harness.state(of: first))")!
        harness.flow.startSignIn()
        let retry = await harness.sessions.session(1)

        #expect(await harness.flow.handleCallbackURL(brokenOldTab, delivery: .external) == false)
        harness.flow.syncAnalytics()
        retry.deliver(harness.callback(for: retry))
        await harness.waitForAttemptToEnd()
        harness.flow.syncAnalytics()

        let events = await harness.signInEvents()
        #expect(events.map(\.name) == [
            "cmux_sign_in_started", "cmux_sign_in_started",
            "cmux_sign_in_failed",
            "cmux_sign_in_callback_received", "cmux_sign_in_succeeded",
        ])
        let firstID = try #require(events[0].string("attempt_id"))
        let retryID = try #require(events[1].string("attempt_id"))
        #expect(events[2].string("attempt_id") == firstID)
        #expect(events[2].string("reason") == "invalid_link")
        #expect(events[3...].allSatisfy { $0.string("attempt_id") == retryID })
        harness.tearDown()
    }

    @Test("a stateless embedded-browser sign-in while one is pending is credited without claiming a link")
    func statelessCallbackIsUnlinked() async throws {
        let harness = try await SignInAnalyticsHarness.make()

        harness.flow.startSignIn()
        let window = await harness.sessions.session(0)
        // The window closes (an open window refuses a stateless callback);
        // the sign-in stays pending and finishes in the embedded browser.
        window.deliver(.cancelled(reason: HostBrowserAuthSessionResult.userClosedWindowReason))
        await harness.waitForAttemptToEnd()
        let embedded = URL(string: "cmux://auth-callback?stack_refresh=refresh-2&stack_access=access-2")!
        #expect(await harness.flow.handleCallbackURL(embedded, delivery: .trustedEmbeddedBrowser))
        harness.flow.syncAnalytics()

        let events = await harness.signInEvents()
        #expect(events.map(\.name) == [
            "cmux_sign_in_started", "cmux_sign_in_window_closed",
            "cmux_sign_in_callback_received", "cmux_sign_in_succeeded",
        ])
        #expect(events[2].string("delivery") == "embedded_browser")
        #expect(events[2...].allSatisfy { $0.string("attempt_link") == "none" })
        #expect(Set(events.compactMap { $0.string("attempt_id") }).count == 1)
        harness.tearDown()
    }

    @Test("a rejected callback fails once with a bounded reason for its attempt")
    func rejectedCallbackFailsOnce() async throws {
        let harness = try await SignInAnalyticsHarness.make()
        // A socket sign-in opens a window only while signed out.
        await harness.flow.signOut()

        let signedIn = Task { await harness.flow.signIn(timeout: 60) }
        let session = await harness.sessions.session(0)
        session.deliver(harness.callback(for: session, state: "not-the-issued-state"))
        #expect(await signedIn.value == false)
        harness.flow.syncAnalytics()
        harness.flow.syncAnalytics()

        let events = await harness.signInEvents()
        #expect(events.map(\.name) == [
            "cmux_sign_in_started", "cmux_sign_in_callback_received", "cmux_sign_in_failed",
        ])
        #expect(events[0].string("entrypoint") == "socket")
        #expect(events[2].string("reason") == "invalid_link")
        #expect(Set(events.compactMap { $0.string("attempt_id") }).count == 1)
        harness.tearDown()
    }

    @Test("a socket sign-in on a signed-in app is a request without an attempt; a window no request opened is unmeasured")
    func requestsWithoutAttempt() async throws {
        let harness = try await SignInAnalyticsHarness.make()

        // Already signed in: the flow returns at once and opens no window.
        #expect(await harness.flow.signIn(timeout: 60))
        // A caller outside the account flow's entrypoints opens a window.
        harness.flow.browserSignIn.beginSignIn()
        let session = await harness.sessions.session(0)
        session.deliver(harness.callback(for: session))
        await harness.waitForAttemptToEnd()
        harness.flow.syncAnalytics()

        let events = await harness.signInEvents()
        #expect(events.map(\.name) == ["cmux_sign_in_started"])
        #expect(events[0].string("entrypoint") == "socket")
        #expect(events[0].string("start_outcome") == "already_signed_in")
        #expect(events[0].string("attempt_id") == nil)
        harness.tearDown()
    }

    @Test("Sign In again on an attempt that continues in the default browser is a reused request; the attempt keeps its result")
    func reusedRequestKeepsAttribution() async throws {
        let opened = OpenedExternalURLs()
        let harness = try await SignInAnalyticsHarness.make(openExternalURL: { opened.open($0) })

        harness.flow.startSignIn()
        let session = await harness.sessions.session(0)
        let callback = harness.callback(for: session)
        // The window ends on a page that is not the callback, so the attempt
        // continues in the default browser.
        session.deliver(URL(string: "https://example.test/handler/sign-in?after_auth_return_to=1")!)
        #expect(opened.urls.count == 1)
        _ = harness.flow.startSignInForPane()
        #expect(await harness.flow.handleCallbackURL(callback, delivery: .external))
        await harness.waitForAttemptToEnd()
        harness.flow.syncAnalytics()

        let events = await harness.signInEvents()
        #expect(events.map(\.name) == [
            "cmux_sign_in_started", "cmux_sign_in_started",
            "cmux_sign_in_callback_received", "cmux_sign_in_succeeded",
        ])
        let attemptID = try #require(events[0].string("attempt_id"))
        #expect(events[0].string("start_outcome") == "opened")
        #expect(events[1].string("start_outcome") == "reused")
        #expect(events[1].string("entrypoint") == "pane")
        #expect(events[1].string("attempt_id") == nil)
        #expect(events[1].properties["replaced_pending"] == .bool(false))
        #expect(events[2...].allSatisfy { $0.string("attempt_id") == attemptID })
        #expect(harness.sessions.sessions.count == 1)
        harness.tearDown()
    }

    @Test("a sign-out interrupts the open attempt; a later sign-in from another path is not credited to it")
    func signOutInterruptsAttempt() async throws {
        let harness = try await SignInAnalyticsHarness.make()

        harness.flow.startSignIn()
        let session = await harness.sessions.session(0)
        await harness.flow.signOut()
        session.deliver(.cancelled(reason: HostBrowserAuthSessionResult.userClosedWindowReason))
        harness.flow.syncAnalytics()

        let embedded = URL(string: "cmux://auth-callback?stack_refresh=refresh-2&stack_access=access-2")!
        #expect(await harness.flow.handleCallbackURL(embedded, delivery: .trustedEmbeddedBrowser))
        harness.flow.syncAnalytics()

        #expect(await harness.signInEvents().map(\.name) == ["cmux_sign_in_started"])
        #expect(harness.sink.named("cmux_signed_out").count == 1)
        harness.tearDown()
    }

    @Test("sign-in events never carry tokens, callback URLs, states, emails or the account id")
    func signInEventsStayPrivate() async throws {
        let harness = try await SignInAnalyticsHarness.make()

        harness.flow.startSignIn()
        let session = await harness.sessions.session(0)
        let state = harness.state(of: session)
        session.deliver(harness.callback(for: session))
        await harness.waitForAttemptToEnd()

        let events = await harness.signInEvents()
        #expect(events.count == 3)
        let forbidden = ["access-1", "refresh-1", "fixture", "@", "://", "auth-callback", state]
        for event in events {
            for (key, value) in event.properties {
                guard case let .string(text) = value else { continue }
                for fragment in forbidden {
                    #expect(!text.contains(fragment), "\(event.name).\(key) leaks \(fragment)")
                }
            }
        }
        harness.tearDown()
    }

    @Test("with telemetry off, a full sign-in records nothing")
    func telemetryOffRecordsNothing() async throws {
        let harness = try await SignInAnalyticsHarness.make(telemetryEnabled: false)

        harness.flow.startSignIn()
        let session = await harness.sessions.session(0)
        session.deliver(harness.callback(for: session))
        await harness.waitForAttemptToEnd()

        await harness.analytics.drain()
        #expect(harness.sink.events.isEmpty)
        harness.tearDown()
    }
}

// MARK: - Harness

@MainActor
private struct SignInAnalyticsHarness {
    let flow: HostAccountFlow
    let sessions: ScriptedSignInWindows
    let analytics: ProductAnalytics
    let sink: SignInRecordingSink
    let suiteName: String

    static func make(
        telemetryEnabled: Bool = true,
        openExternalURL: @escaping @MainActor (URL) -> Bool = { _ in false }
    ) async throws -> Self {
        let sink = SignInRecordingSink()
        let suiteName = "HostAccountSignInAnalyticsTests.\(UUID().uuidString)"
        let analytics = ProductAnalytics(
            isEnabled: telemetryEnabled,
            sink: sink,
            ledger: ProductAnalyticsLedger(defaults: try #require(UserDefaults(suiteName: suiteName))),
            context: ProductAnalyticsContext(appVersion: "0.66.0", appBuild: "1", channel: "dev", osVersion: "15.5"),
            isPreexistingInstall: true
        )
        let sessions = ScriptedSignInWindows()
        let flow = try await HostAccountFlow.makeForTeamChangeTests(
            client: TeamChangeAuthClient(),
            billingPlanClient: BillingPlanClient(session: OfflineURLProtocol.session()),
            sessionFactory: sessions,
            analytics: analytics,
            openExternalURL: openExternalURL
        )
        return Self(flow: flow, sessions: sessions, analytics: analytics, sink: sink, suiteName: suiteName)
    }

    func state(of session: ScriptedSignInWindow) -> String {
        URLComponents(url: session.signInURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "cmux_auth_state" }?.value ?? ""
    }

    func callback(for session: ScriptedSignInWindow, state: String? = nil) -> URL {
        URL(string: "cmux://auth-callback?stack_refresh=refresh-1&stack_access=access-1&cmux_auth_state=\(state ?? self.state(of: session))")!
    }

    /// Suspends until the sign-in UI is idle, woken by the observable flag
    /// itself rather than by polling.
    func waitForAttemptToEnd() async {
        let flow = flow
        while flow.isPresentingSignIn {
            await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
                withObservationTracking {
                    _ = flow.isPresentingSignIn
                } onChange: {
                    resume.resume()
                }
            }
        }
    }

    /// The `cmux_sign_in_*` events PostHog would receive, after the pipeline drains.
    func signInEvents() async -> [SignInRecordingSink.Event] {
        await analytics.drain()
        return sink.events.filter { $0.name.hasPrefix("cmux_sign_in_") }
    }

    func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }
}

/// Records what ``ProductAnalytics`` hands to PostHog.
private final class SignInRecordingSink: AnalyticsEmitting {
    struct Event {
        let name: String
        let properties: [String: AnalyticsValue]

        func string(_ key: String) -> String? {
            if case let .string(value)? = properties[key] { return value }
            return nil
        }
    }

    private let state = OSAllocatedUnfairLock<[Event]>(initialState: [])
    var events: [Event] { state.withLock { $0 } }
    func named(_ name: String) -> [Event] { events.filter { $0.name == name } }

    func capture(_ event: String, _ properties: [String: AnalyticsValue]) {
        state.withLock { $0.append(Event(name: event, properties: properties)) }
    }
    func identify(userId: String?, alias: String?, properties: [String: AnalyticsValue]) {}
    func setSuperProperties(_ properties: [String: AnalyticsValue]) {}
    func flush() async {}
}

/// Stands in for the sign-in window; the test chooses how each one ends.
@MainActor
private final class ScriptedSignInWindows: HostBrowserAuthSessionFactory {
    private(set) var sessions: [ScriptedSignInWindow] = []
    private var waiters: [(index: Int, resume: CheckedContinuation<ScriptedSignInWindow, Never>)] = []

    func makeSession(
        signInURL: URL,
        callbackScheme: String,
        completion: @escaping @MainActor (HostBrowserAuthSessionResult) -> Void
    ) -> any HostBrowserAuthSession {
        let session = ScriptedSignInWindow(signInURL: signInURL, completion: completion)
        sessions.append(session)
        waiters.removeAll { waiter in
            guard waiter.index < sessions.count else { return false }
            waiter.resume.resume(returning: sessions[waiter.index])
            return true
        }
        return session
    }

    /// The `index`th window, once the flow has opened it.
    func session(_ index: Int) async -> ScriptedSignInWindow {
        if index < sessions.count { return sessions[index] }
        return await withCheckedContinuation { waiters.append((index, $0)) }
    }
}

@MainActor
private final class OpenedExternalURLs {
    private(set) var urls: [URL] = []
    func open(_ url: URL) -> Bool {
        urls.append(url)
        return true
    }
}

@MainActor
private final class ScriptedSignInWindow: HostBrowserAuthSession {
    let signInURL: URL
    private let completion: @MainActor (HostBrowserAuthSessionResult) -> Void
    private var completed = false

    init(signInURL: URL, completion: @escaping @MainActor (HostBrowserAuthSessionResult) -> Void) {
        self.signInURL = signInURL
        self.completion = completion
    }

    func start() -> Bool { true }
    // Like ASWebAuthenticationSession, an app-side cancel completes later
    // only if the test delivers it.
    func cancel() {}

    func deliver(_ url: URL) { deliver(.callback(url)) }

    func deliver(_ result: HostBrowserAuthSessionResult) {
        guard !completed else { return }
        completed = true
        completion(result)
    }
}

/// Fails every request at once, so the post-sign-in plan refresh never
/// reaches a real server.
private final class OfflineURLProtocol: URLProtocol, @unchecked Sendable {
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
