import AppKit
import Foundation
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Real WebKit navigations that a public login page starts toward loopback.
/// In an SSH workspace the page's `127.0.0.1` belongs to the remote host, so
/// these must take the workspace's remote route and never reach a service
/// listening on this Mac. A local workspace pane keeps loading this Mac's
/// loopback, which also proves the fixture service is reachable.
@MainActor
@Suite("SSH browser page loopback navigation", .serialized, .timeLimit(.minutes(2)))
struct SSHBrowserPageLoopbackNavigationTests {
    private static let loginPageURL = URL(string: "https://login.example.test/authorize")!
    /// Plain HTTP keeps the frame fixture clear of mixed-content blocking, and
    /// `*.localtest.me` is on the default insecure-HTTP allowlist.
    private static let framingPageURL = URL(string: "http://login.localtest.me/authorize")!

    @Test("A login page's loopback location change takes the SSH workspace's remote route")
    func mainFrameLoopbackNavigationTakesRemoteRoute() async throws {
        let macService = try CloudLoopbackOriginTestServer(marker: "mac-local")
        try await macService.start()
        defer { macService.stop() }
        let callback = "http://127.0.0.1:\(macService.port)/callback?code=from-provider"
        let page = "<script>location.href = \(Self.javaScriptString(callback));</script>"

        let local = Self.makePanel(isSSHWorkspace: false)
        defer { local.close() }
        local.panel.webView.loadHTMLString(page, baseURL: Self.loginPageURL)
        let localReachedCallback = await Self.wait {
            macService.requests.contains { $0.target.hasPrefix("/callback") }
        }
        #expect(localReachedCallback, "A local workspace pane loads this Mac's loopback callback")
        let localRequests = macService.requests.count

        let ssh = Self.makePanel(isSSHWorkspace: true)
        defer { ssh.close() }
        #expect(!ssh.panel.hasPendingRemoteNavigation)
        ssh.panel.webView.loadHTMLString(page, baseURL: Self.loginPageURL)
        #expect(await Self.wait { ssh.panel.hasPendingRemoteNavigation },
                "The loopback callback must wait for the SSH workspace's remote loopback route")
        #expect(macService.requests.count == localRequests,
                "An SSH workspace's loopback callback must never reach this Mac's service")
        #expect(ssh.panel.webView.url?.host != "127.0.0.1")
    }

    @Test("A login page's loopback frame in an SSH workspace never loads from this Mac")
    func subframeLoopbackNavigationNeverReachesMac() async throws {
        let macService = try CloudLoopbackOriginTestServer(marker: "mac-local")
        try await macService.start()
        defer { macService.stop() }
        let frameURL = "http://127.0.0.1:\(macService.port)/frame-callback"
        let page = """
        <script>window.addEventListener('load', () => { document.title = 'page-loaded'; });</script>
        <iframe src=\(Self.javaScriptString(frameURL))></iframe>
        """

        let local = Self.makePanel(isSSHWorkspace: false)
        defer { local.close() }
        local.panel.webView.loadHTMLString(page, baseURL: Self.framingPageURL)
        let localReachedFrame = await Self.wait {
            macService.requests.contains { $0.target == "/frame-callback" }
        }
        #expect(localReachedFrame, "A local workspace pane loads this Mac's loopback frame")
        let localRequests = macService.requests.count

        let ssh = Self.makePanel(isSSHWorkspace: true)
        defer { ssh.close() }
        ssh.panel.webView.loadHTMLString(page, baseURL: Self.framingPageURL)
        // The window load event waits for every parser-inserted frame.
        #expect(await Self.wait { ssh.panel.webView.title == "page-loaded" })
        #expect(macService.requests.count == localRequests,
                "An SSH workspace's loopback frame must never reach this Mac's service")
    }

    private struct HostedPanel {
        let panel: BrowserPanel
        let window: NSWindow

        @MainActor
        func close() {
            window.contentView = nil
            window.close()
            panel.close()
        }
    }

    private static func makePanel(isSSHWorkspace: Bool) -> HostedPanel {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            isRemoteWorkspace: isSSHWorkspace,
            allowsLocalNavigationWithoutRemoteProxy: isSSHWorkspace,
            websiteDataStore: .nonPersistent()
        )
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = panel.webView
        window.orderFrontRegardless()
        return HostedPanel(panel: panel, window: window)
    }

    private static func javaScriptString(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value])) ?? Data("[\"\"]".utf8)
        return String(decoding: data.dropFirst().dropLast(), as: UTF8.self)
    }

    private static func wait(
        timeout: Duration = .seconds(10),
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}
