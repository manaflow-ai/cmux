import XCTest
import AppKit
import CMUXAuthCore
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class BrowserArrowKeyForwardingTests: XCTestCase {
    func testRoutesAllPlainArrowKeysWhenBrowserFirstResponder() {
        for keyCode in [123, 124, 125, 126] as [UInt16] {
            XCTAssertTrue(
                shouldDispatchBrowserArrowViaFirstResponderKeyDown(
                    keyCode: keyCode,
                    firstResponderIsBrowser: true,
                    flags: []
                ),
                "Expected browser responder to own plain arrow keyCode \(keyCode)"
            )
        }
    }

    func testDoesNotForceForwardArrowsOutsidePlainBrowserResponderPath() {
        XCTAssertFalse(shouldDispatchBrowserArrowViaFirstResponderKeyDown(keyCode: 123, firstResponderIsBrowser: false, flags: []))
        XCTAssertFalse(shouldDispatchBrowserArrowViaFirstResponderKeyDown(keyCode: 124, firstResponderIsBrowser: true, firstResponderHasMarkedText: true, flags: []))
        XCTAssertFalse(shouldDispatchBrowserArrowViaFirstResponderKeyDown(keyCode: 125, firstResponderIsBrowser: true, flags: [.command]))
    }
}

@MainActor
final class BrowserReturnKeyForwardingTests: XCTestCase {
    private final class RecordingWKWebView: WKWebView {
        var keyDownCallCount = 0
        var lastKeyCode: UInt16?
        var reentrantPerformKeyEquivalentEvent: NSEvent?
        var reentrantPerformKeyEquivalentResult: Bool?

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            keyDownCallCount += 1
            lastKeyCode = event.keyCode
            if let reentrantPerformKeyEquivalentEvent {
                reentrantPerformKeyEquivalentResult = window?.performKeyEquivalent(with: reentrantPerformKeyEquivalentEvent)
            }
        }
    }

    private final class FocusableWebSubview: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    private func makeKeyEvent(
        windowNumber: Int,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags = [],
        characters: String = "\r",
        charactersIgnoringModifiers: String = "\r"
    ) -> NSEvent {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            fatalError("Failed to construct key event")
        }
        return event
    }

    func testRoutesPlainReturnFromEmbeddedWKWebViewResponderToKeyDownAndConsumesIt() {
        AppDelegate.installWindowResponderSwizzlesForTesting()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.close() }

        let webView = RecordingWKWebView(frame: window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 320, height: 240))
        let webSubview = FocusableWebSubview(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        webView.addSubview(webSubview)
        window.contentView = webView

        XCTAssertTrue(window.makeFirstResponder(webSubview))

        let event = makeKeyEvent(windowNumber: window.windowNumber, keyCode: 36)
        XCTAssertTrue(window.performKeyEquivalent(with: event))
        XCTAssertEqual(webView.keyDownCallCount, 1)
        XCTAssertEqual(webView.lastKeyCode, 36)
    }

    func testRoutesPlainArrowFromEmbeddedWKWebViewResponderToKeyDown() {
        AppDelegate.installWindowResponderSwizzlesForTesting()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.close() }

        let webView = RecordingWKWebView(frame: window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 320, height: 240))
        let webSubview = FocusableWebSubview(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        webView.addSubview(webSubview)
        window.contentView = webView

        XCTAssertTrue(window.makeFirstResponder(webSubview))

        let event = makeKeyEvent(windowNumber: window.windowNumber, keyCode: 123)
        XCTAssertTrue(window.performKeyEquivalent(with: event))
        XCTAssertEqual(webView.keyDownCallCount, 1)
        XCTAssertEqual(webView.lastKeyCode, 123)
    }

    func testConsumesReentrantReturnDuringForwardedBrowserKeyDown() {
        AppDelegate.installWindowResponderSwizzlesForTesting()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.close() }

        let webView = RecordingWKWebView(frame: window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 320, height: 240))
        let webSubview = FocusableWebSubview(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        webView.addSubview(webSubview)
        window.contentView = webView

        XCTAssertTrue(window.makeFirstResponder(webSubview))

        let event = makeKeyEvent(windowNumber: window.windowNumber, keyCode: 36)
        webView.reentrantPerformKeyEquivalentEvent = event

        XCTAssertTrue(window.performKeyEquivalent(with: event))
        XCTAssertEqual(webView.keyDownCallCount, 1)
        XCTAssertEqual(webView.lastKeyCode, 36)
        XCTAssertEqual(webView.reentrantPerformKeyEquivalentResult, true)
    }

    func testDoesNotConsumeReentrantNonReturnDuringForwardedBrowserKeyDown() {
        AppDelegate.installWindowResponderSwizzlesForTesting()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.close() }

        let webView = RecordingWKWebView(frame: window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 320, height: 240))
        let webSubview = FocusableWebSubview(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        webView.addSubview(webSubview)
        window.contentView = webView

        XCTAssertTrue(window.makeFirstResponder(webSubview))

        let returnEvent = makeKeyEvent(windowNumber: window.windowNumber, keyCode: 36)
        webView.reentrantPerformKeyEquivalentEvent = makeKeyEvent(
            windowNumber: window.windowNumber,
            keyCode: 13,
            characters: "w",
            charactersIgnoringModifiers: "w"
        )

        XCTAssertTrue(window.performKeyEquivalent(with: returnEvent))
        XCTAssertEqual(webView.keyDownCallCount, 1)
        XCTAssertEqual(webView.reentrantPerformKeyEquivalentResult, false)
    }

    func testReturnForwardingKeepsShortcutAndIMECasesOutOfTheForcedPath() {
        XCTAssertFalse(
            shouldDispatchBrowserReturnViaFirstResponderKeyDown(
                keyCode: 36,
                firstResponderIsBrowser: false,
                flags: []
            )
        )
        XCTAssertFalse(
            shouldDispatchBrowserReturnViaFirstResponderKeyDown(
                keyCode: 36,
                firstResponderIsBrowser: true,
                firstResponderHasMarkedText: true,
                flags: []
            )
        )
        XCTAssertFalse(
            shouldDispatchBrowserReturnViaFirstResponderKeyDown(
                keyCode: 36,
                firstResponderIsBrowser: true,
                flags: [.command]
            )
        )
        XCTAssertTrue(
            shouldDispatchBrowserReturnViaFirstResponderKeyDown(
                keyCode: 76,
                firstResponderIsBrowser: true,
                flags: [.shift]
            )
        )
    }
}

@MainActor
final class AuthManagerBrowserSignInTests: XCTestCase {
    private actor InMemoryAuthTokenStore: StackAuthTokenStoreProtocol {
        private var accessToken: String?
        private var refreshToken: String?

        func getStoredAccessToken() async -> String? {
            accessToken
        }

        func getStoredRefreshToken() async -> String? {
            refreshToken
        }

        func setTokens(accessToken: String?, refreshToken: String?) async {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
        }

        func clearTokens() async {
            accessToken = nil
            refreshToken = nil
        }

        func compareAndSet(
            compareRefreshToken: String,
            newRefreshToken: String?,
            newAccessToken: String?
        ) async {
            guard refreshToken == compareRefreshToken else { return }
            refreshToken = newRefreshToken
            accessToken = newAccessToken
        }
    }

    private struct StubAuthClient: AuthClientProtocol {
        let user = CMUXAuthUser(
            id: "user_123",
            primaryEmail: "user@example.com",
            displayName: "Test User"
        )
        let teams = [AuthTeamSummary(id: "team_123", displayName: "Team")]

        func currentUser() async throws -> CMUXAuthUser? {
            user
        }

        func listTeams() async throws -> [AuthTeamSummary] {
            teams
        }
    }

    private func makeIsolatedSettingsStore() -> AuthSettingsStore {
        let suiteName = "cmux-auth-manager-browser-sign-in-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return AuthSettingsStore(userDefaults: defaults)
    }

    func testBeginSignInOpensExternalBrowserCallbackURL() async {
        let tokenStore = InMemoryAuthTokenStore()
        var openedURL: URL?
        let manager = AuthManager(
            client: StubAuthClient(),
            tokenStore: tokenStore,
            settingsStore: makeIsolatedSettingsStore(),
            urlOpener: { openedURL = $0 }
        )
        await manager.awaitBootstrapped()

        manager.beginSignIn()

        let url = openedURL
        XCTAssertEqual(url?.path, "/handler/sign-in")
        let components = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        let afterAuthReturnTo = components?.queryItems?.first { $0.name == "after_auth_return_to" }?.value
        XCTAssertEqual(url?.scheme, AuthEnvironment.afterSignInOrigin.scheme)
        XCTAssertEqual(url?.host, AuthEnvironment.afterSignInOrigin.host)
        XCTAssertTrue(afterAuthReturnTo?.contains(AuthEnvironment.callbackURL.absoluteString) == true)
        XCTAssertFalse(manager.isLoading)
        await manager.signOut()
    }

    func testBrowserCallbackClearsLoadingAndSeedsTokens() async throws {
        let tokenStore = InMemoryAuthTokenStore()
        var openedURL: URL?
        let manager = AuthManager(
            client: StubAuthClient(),
            tokenStore: tokenStore,
            settingsStore: makeIsolatedSettingsStore(),
            urlOpener: { openedURL = $0 }
        )
        await manager.awaitBootstrapped()

        manager.beginSignIn()
        XCTAssertNotNil(openedURL)
        XCTAssertFalse(manager.isLoading)

        let callbackURL = try XCTUnwrap(URL(
            string: "\(AuthEnvironment.callbackScheme)://auth-callback?stack_refresh=refresh-token&stack_access=access-token"
        ))
        try await manager.handleCallbackURL(callbackURL)

        XCTAssertFalse(manager.isLoading)
        XCTAssertTrue(manager.isAuthenticated)
        XCTAssertEqual(manager.currentUser?.id, "user_123")
        let storedAccessToken = await tokenStore.getStoredAccessToken()
        let storedRefreshToken = await tokenStore.getStoredRefreshToken()
        XCTAssertEqual(storedAccessToken, "access-token")
        XCTAssertEqual(storedRefreshToken, "refresh-token")
    }
}
