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
@Suite
struct BrowserHTTPBasicAuthPromptTests {
    private final class BrowserAuthChallengeSenderStub: NSObject, URLAuthenticationChallengeSender {
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
        func cancel(_ challenge: URLAuthenticationChallenge) {}
        func performDefaultHandling(for challenge: URLAuthenticationChallenge) {}
        func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {}
    }

    private final class BrowserHTTPBasicAuthAlertSpy: NSAlert {
        private(set) var beginSheetModalCallCount = 0
        private(set) var runModalCallCount = 0
        var nextResponse: NSApplication.ModalResponse = .alertFirstButtonReturn
        var beforeResponding: ((NSView?) -> Void)?

        override func beginSheetModal(
            for sheetWindow: NSWindow,
            completionHandler handler: ((NSApplication.ModalResponse) -> Void)?
        ) {
            beginSheetModalCallCount += 1
            beforeResponding?(accessoryView)
            handler?(nextResponse)
        }

        override func runModal() -> NSApplication.ModalResponse {
            runModalCallCount += 1
            beforeResponding?(accessoryView)
            return nextResponse
        }
    }

    private func makeAuthChallenge(
        host: String = "basic-auth.test",
        method: String,
        realm: String? = "EnableIT",
        protocolName: String = "https",
        port: Int = 443,
        proposedCredential: URLCredential? = nil,
        previousFailureCount: Int = 0,
        isProxy: Bool = false
    ) -> URLAuthenticationChallenge {
        let sender = BrowserAuthChallengeSenderStub()
        let protectionSpace: URLProtectionSpace
        if isProxy {
            protectionSpace = URLProtectionSpace(
                proxyHost: host,
                port: 8080,
                type: NSURLProtectionSpaceHTTPProxy,
                realm: realm,
                authenticationMethod: method
            )
        } else {
            protectionSpace = URLProtectionSpace(
                host: host,
                port: port,
                protocol: protocolName,
                realm: realm,
                authenticationMethod: method
            )
        }
        return URLAuthenticationChallenge(
            protectionSpace: protectionSpace,
            proposedCredential: proposedCredential,
            previousFailureCount: previousFailureCount,
            failureResponse: nil,
            error: nil,
            sender: sender
        )
    }

    private func editableTextFields(in root: NSView?) -> [NSTextField] {
        textFields(in: root).filter(\.isEditable)
    }

    private func textFields(in root: NSView?) -> [NSTextField] {
        guard let root else { return [] }
        var result: [NSTextField] = []

        func walk(_ view: NSView) {
            if let field = view as? NSTextField {
                result.append(field)
            }
            for subview in view.subviews {
                walk(subview)
            }
        }

        walk(root)
        return result
    }

    @Test
    func basicAuthPromptUsesSheetWhenWindowIsAvailable() {
        let challenge = makeAuthChallenge(method: NSURLAuthenticationMethodHTTPBasic)
        let alertSpy = BrowserHTTPBasicAuthAlertSpy()
        let webView = WKWebView(frame: .zero)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )

        let handled = browserHandleHTTPBasicAuthenticationChallenge(
            in: webView,
            challenge: challenge,
            alertFactory: { alertSpy },
            windowProvider: { window }
        ) { _, _ in }

        #expect(handled)
        #expect(alertSpy.beginSheetModalCallCount == 1)
        #expect(alertSpy.runModalCallCount == 0)
    }

    @Test
    func basicAuthPromptFallsBackToRunModalWithoutWindow() {
        let challenge = makeAuthChallenge(method: NSURLAuthenticationMethodHTTPBasic)
        let alertSpy = BrowserHTTPBasicAuthAlertSpy()
        let webView = WKWebView(frame: .zero)

        let handled = browserHandleHTTPBasicAuthenticationChallenge(
            in: webView,
            challenge: challenge,
            alertFactory: { alertSpy },
            windowProvider: { nil }
        ) { _, _ in }

        #expect(handled)
        #expect(alertSpy.beginSheetModalCallCount == 0)
        #expect(alertSpy.runModalCallCount == 1)
    }

    @Test
    func basicAuthPromptCanDeferThroughInjectedPresenter() {
        let challenge = makeAuthChallenge(method: NSURLAuthenticationMethodHTTPBasic)
        let alertSpy = BrowserHTTPBasicAuthAlertSpy()
        let webView = WKWebView(frame: .zero)
        var presenterCalled = false
        var completionCalled = false

        let handled = browserHandleHTTPBasicAuthenticationChallenge(
            in: webView,
            challenge: challenge,
            alertFactory: { alertSpy },
            presentAlert: { alert, presentedWebView, _, _ in
                presenterCalled = true
                #expect(alert === alertSpy)
                #expect(presentedWebView === webView)
            }
        ) { _, _ in
            completionCalled = true
        }

        #expect(handled)
        #expect(presenterCalled)
        #expect(alertSpy.beginSheetModalCallCount == 0)
        #expect(alertSpy.runModalCallCount == 0)
        #expect(!completionCalled)
    }

    @Test
    func basicAuthPromptPresenterCancelCancelsChallenge() {
        let challenge = makeAuthChallenge(method: NSURLAuthenticationMethodHTTPBasic)
        let alertSpy = BrowserHTTPBasicAuthAlertSpy()
        let webView = WKWebView(frame: .zero)
        var disposition: URLSession.AuthChallengeDisposition?
        var credential: URLCredential?

        let handled = browserHandleHTTPBasicAuthenticationChallenge(
            in: webView,
            challenge: challenge,
            alertFactory: { alertSpy },
            presentAlert: { _, _, _, cancel in
                cancel()
            }
        ) { returnedDisposition, returnedCredential in
            disposition = returnedDisposition
            credential = returnedCredential
        }

        #expect(handled)
        #expect(alertSpy.beginSheetModalCallCount == 0)
        #expect(alertSpy.runModalCallCount == 0)
        #expect(disposition == .cancelAuthenticationChallenge)
        #expect(credential == nil)
    }

    @Test
    func mainBrowserCoalescesDuplicateBasicAuthChallengesWhilePreloadPromptIsPending() throws {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: try #require(URL(string: "about:blank")),
            preloadInitialNavigationInBackground: true,
            isRemoteWorkspace: false
        )
        var didClosePanel = false
        defer {
            if !didClosePanel {
                panel.close()
            }
        }

        #expect(panel.hasBackgroundPreloadHost)
        #expect(browserInteractiveModalHostWindow(for: panel.webView) == nil)

        let delegate = try #require(panel.webView.navigationDelegate)
        let firstChallenge = makeAuthChallenge(method: NSURLAuthenticationMethodHTTPBasic)
        let secondChallenge = makeAuthChallenge(method: NSURLAuthenticationMethodHTTPBasic)
        var firstDisposition: URLSession.AuthChallengeDisposition?
        var secondDisposition: URLSession.AuthChallengeDisposition?
        var secondCredential: URLCredential?

        delegate.webView?(
            panel.webView,
            didReceive: firstChallenge
        ) { disposition, _ in
            firstDisposition = disposition
        }

        delegate.webView?(
            panel.webView,
            didReceive: secondChallenge
        ) { disposition, credential in
            secondDisposition = disposition
            secondCredential = credential
        }

        #expect(firstDisposition == nil)
        #expect(secondDisposition == nil)

        panel.close()
        didClosePanel = true

        #expect(firstDisposition == .cancelAuthenticationChallenge)
        #expect(secondDisposition == .cancelAuthenticationChallenge)
        #expect(secondCredential == nil)
    }

    @Test
    func basicAuthPromptConfirmReturnsSessionCredential() {
        let proposed = URLCredential(user: "prefill", password: "old", persistence: .forSession)
        let challenge = makeAuthChallenge(
            method: NSURLAuthenticationMethodHTTPBasic,
            proposedCredential: proposed
        )
        let alertSpy = BrowserHTTPBasicAuthAlertSpy()
        let webView = WKWebView(frame: .zero)
        var disposition: URLSession.AuthChallengeDisposition?
        var credential: URLCredential?

        alertSpy.beforeResponding = { accessoryView in
            let fields = self.editableTextFields(in: accessoryView)
            #expect(fields.count == 2, "Expected username and password fields in the auth alert")
            guard fields.count >= 2 else { return }
            fields[0].stringValue = "alice"
            fields[1].stringValue = "secret"
        }

        let handled = browserHandleHTTPBasicAuthenticationChallenge(
            in: webView,
            challenge: challenge,
            alertFactory: { alertSpy },
            windowProvider: { nil }
        ) { returnedDisposition, returnedCredential in
            disposition = returnedDisposition
            credential = returnedCredential
        }

        #expect(handled)
        #expect(disposition == .useCredential)
        #expect(credential?.user == "alice")
        #expect(credential?.password == "secret")
        #expect(credential?.persistence == .forSession)
    }

    @Test
    func basicAuthPromptSanitizesHostAndRealmText() {
        let challenge = makeAuthChallenge(
            host: "basic\u{202E}-auth.test\n",
            method: NSURLAuthenticationMethodHTTPBasic,
            realm: "En\u{200B}able\u{0007}IT"
        )
        let alertSpy = BrowserHTTPBasicAuthAlertSpy()
        let webView = WKWebView(frame: .zero)
        var promptMessage: String?

        alertSpy.beforeResponding = { accessoryView in
            promptMessage = self.textFields(in: accessoryView)
                .first(where: { !$0.isEditable })?
                .stringValue
        }

        let handled = browserHandleHTTPBasicAuthenticationChallenge(
            in: webView,
            challenge: challenge,
            alertFactory: { alertSpy },
            windowProvider: { nil }
        ) { _, _ in }

        #expect(handled)
        #expect(alertSpy.runModalCallCount == 1)
        #expect(promptMessage?.contains("basic-auth.test") == true)
        #expect(promptMessage?.contains("EnableIT") == true)
        #expect(promptMessage?.contains("\u{202E}") == false)
        #expect(promptMessage?.contains("\u{200B}") == false)
        #expect(promptMessage?.unicodeScalars.contains("\u{0007}") == false)
    }

    @Test
    func basicAuthPromptShowsSanitizedOriginWithNonDefaultPort() {
        let challenge = makeAuthChallenge(
            host: "localhost",
            method: NSURLAuthenticationMethodHTTPBasic,
            realm: nil,
            protocolName: "http",
            port: 8443
        )
        let alertSpy = BrowserHTTPBasicAuthAlertSpy()
        let webView = WKWebView(frame: .zero)
        var promptMessage: String?

        alertSpy.beforeResponding = { accessoryView in
            promptMessage = self.textFields(in: accessoryView)
                .first(where: { !$0.isEditable })?
                .stringValue
        }

        let handled = browserHandleHTTPBasicAuthenticationChallenge(
            in: webView,
            challenge: challenge,
            alertFactory: { alertSpy },
            windowProvider: { nil }
        ) { _, _ in }

        #expect(handled)
        #expect(alertSpy.runModalCallCount == 1)
        #expect(promptMessage?.contains("http://localhost:8443") == true)
    }

    @Test
    func basicAuthPromptMiddleElidesLongOriginPreservingHostSuffixAndPort() {
        let longHost = "trusted.example."
            + String(repeating: "middle.", count: 80)
            + "attacker.test"
        let challenge = makeAuthChallenge(
            host: longHost,
            method: NSURLAuthenticationMethodHTTPBasic,
            realm: nil,
            protocolName: "https",
            port: 9443
        )
        let alertSpy = BrowserHTTPBasicAuthAlertSpy()
        let webView = WKWebView(frame: .zero)
        var promptMessage: String?

        alertSpy.beforeResponding = { accessoryView in
            promptMessage = self.textFields(in: accessoryView)
                .first(where: { !$0.isEditable })?
                .stringValue
        }

        let handled = browserHandleHTTPBasicAuthenticationChallenge(
            in: webView,
            challenge: challenge,
            alertFactory: { alertSpy },
            windowProvider: { nil }
        ) { _, _ in }

        #expect(handled)
        #expect(alertSpy.runModalCallCount == 1)
        #expect(promptMessage?.contains("...") == true)
        #expect(promptMessage?.contains("attacker.test:9443") == true)
    }

    @Test
    func basicAuthPromptShowsPreviousFailureMessage() {
        let challenge = makeAuthChallenge(
            method: NSURLAuthenticationMethodHTTPBasic,
            previousFailureCount: 1
        )
        let alertSpy = BrowserHTTPBasicAuthAlertSpy()
        let webView = WKWebView(frame: .zero)
        var promptMessage: String?

        alertSpy.beforeResponding = { accessoryView in
            promptMessage = self.textFields(in: accessoryView)
                .first(where: { !$0.isEditable })?
                .stringValue
        }

        let handled = browserHandleHTTPBasicAuthenticationChallenge(
            in: webView,
            challenge: challenge,
            alertFactory: { alertSpy },
            windowProvider: { nil }
        ) { _, _ in }

        let failureMessage = String(
            localized: "browser.dialog.auth.basic.incorrectCredentials",
            defaultValue: "The username or password you entered is incorrect."
        )
        #expect(handled)
        #expect(alertSpy.runModalCallCount == 1)
        #expect(promptMessage?.contains(failureMessage) == true)
        #expect(promptMessage?.contains("basic-auth.test") == true)
    }

    @Test
    func basicAuthPromptCancelCancelsChallenge() {
        let challenge = makeAuthChallenge(method: NSURLAuthenticationMethodHTTPBasic)
        let alertSpy = BrowserHTTPBasicAuthAlertSpy()
        let webView = WKWebView(frame: .zero)
        var disposition: URLSession.AuthChallengeDisposition?
        var credential: URLCredential?

        alertSpy.nextResponse = .alertSecondButtonReturn

        let handled = browserHandleHTTPBasicAuthenticationChallenge(
            in: webView,
            challenge: challenge,
            alertFactory: { alertSpy },
            windowProvider: { nil }
        ) { returnedDisposition, returnedCredential in
            disposition = returnedDisposition
            credential = returnedCredential
        }

        #expect(handled)
        #expect(disposition == .cancelAuthenticationChallenge)
        #expect(credential == nil)
    }

    @Test
    func basicAuthPromptRegistersCancellationHandler() throws {
        let challenge = makeAuthChallenge(method: NSURLAuthenticationMethodHTTPBasic)
        let alertSpy = BrowserHTTPBasicAuthAlertSpy()
        let webView = WKWebView(frame: .zero)
        var registeredCancelPrompt: (() -> Void)?
        var completionCount = 0
        var disposition: URLSession.AuthChallengeDisposition?

        let handled = browserHandleHTTPBasicAuthenticationChallenge(
            in: webView,
            challenge: challenge,
            alertFactory: { alertSpy },
            presentAlert: { _, _, _, _ in },
            registerCancelPrompt: { cancelPrompt in
                registeredCancelPrompt = cancelPrompt
            }
        ) { returnedDisposition, _ in
            completionCount += 1
            disposition = returnedDisposition
        }

        #expect(handled)
        #expect(alertSpy.beginSheetModalCallCount == 0)
        #expect(alertSpy.runModalCallCount == 0)

        let cancelPrompt = try #require(registeredCancelPrompt)
        cancelPrompt()
        cancelPrompt()

        #expect(completionCount == 1)
        #expect(disposition == .cancelAuthenticationChallenge)
    }

    @Test
    func nonBasicAuthChallengeDoesNotPrompt() {
        let challenge = makeAuthChallenge(method: NSURLAuthenticationMethodServerTrust)
        let alertSpy = BrowserHTTPBasicAuthAlertSpy()
        let webView = WKWebView(frame: .zero)
        var completionCalled = false

        let handled = browserHandleHTTPBasicAuthenticationChallenge(
            in: webView,
            challenge: challenge,
            alertFactory: { alertSpy },
            windowProvider: { nil }
        ) { _, _ in
            completionCalled = true
        }

        #expect(!handled)
        #expect(alertSpy.beginSheetModalCallCount == 0)
        #expect(alertSpy.runModalCallCount == 0)
        #expect(!completionCalled)
    }

    @Test
    func proxyBasicAuthChallengeDoesNotPrompt() {
        let challenge = makeAuthChallenge(
            method: NSURLAuthenticationMethodHTTPBasic,
            isProxy: true
        )
        let alertSpy = BrowserHTTPBasicAuthAlertSpy()
        let webView = WKWebView(frame: .zero)
        var completionCalled = false

        let handled = browserHandleHTTPBasicAuthenticationChallenge(
            in: webView,
            challenge: challenge,
            alertFactory: { alertSpy },
            windowProvider: { nil }
        ) { _, _ in
            completionCalled = true
        }

        #expect(!handled)
        #expect(alertSpy.beginSheetModalCallCount == 0)
        #expect(alertSpy.runModalCallCount == 0)
        #expect(!completionCalled)
    }
}
