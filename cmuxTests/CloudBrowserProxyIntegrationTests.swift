import CmuxCloud
import AppKit
import CryptoKit
import Foundation
import Network
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Real WebKit requests through the production per-panel userspace proxy configuration.
/// The fixtures replace the remote carrier, not WebKit or URL routing.
@MainActor
@Suite("Cloud browser proxy integration", .serialized, .timeLimit(.minutes(2)))
struct CloudBrowserProxyIntegrationTests {
    @Test("Desktop readiness uses the authenticated carrier and closes on failure")
    func desktopReadinessThroughCarrier() async throws {
        let server = try CloudBrowserProxyTestServer(address: "10.16.0.10", marker: "desktop-probe")
        try await server.start()
        defer { server.stop() }
        #expect(try await CloudBrowserRouting.desktopIsReachable(endpoint: server.endpoint, address: server.address, port: 8000))
        #expect(server.requests.count == 1)
        #expect(server.requests.first?.method == "HEAD")
        #expect(server.requests.first?.target == "/vnc.html")
        let rejected = CloudBrowserProxyEndpoint(host: "127.0.0.1", port: server.port, username: "wrong", password: "wrong")
        #expect(try await !CloudBrowserRouting.desktopIsReachable(endpoint: rejected, address: server.address, port: 8000))
        #expect(server.requests.count == 1, "Failed proxy auth must not reach the service")
        #expect(try await !CloudBrowserRouting.desktopIsReachable(endpoint: server.endpoint, address: server.address, port: 6901))
    }

    @Test("the browser carrier does not inherit app credentials")
    func browserCarrierSanitizesInheritedCredentials() {
        let environment = CloudBrowserProxyProcess.sanitizedEnvironment([
            "HOME": "/Users/test",
            "CMUX_AUTH_CREDENTIALS_FILE": "/tmp/credentials",
            "CMUX_DOGFOOD_STACK_PASSWORD": "secret",
            "CMUX_UITEST_STACK_PASSWORD": "secret",
            "CMUX_SOCKET_PASSWORD": "secret",
            "PATH": "/usr/bin",
        ])
        #expect(environment["HOME"] == "/Users/test")
        #expect(environment["PATH"] == "/usr/bin")
        #expect(environment["CMUX_AUTH_CREDENTIALS_FILE"] == nil)
        #expect(environment["CMUX_DOGFOOD_STACK_PASSWORD"] == nil)
        #expect(environment["CMUX_UITEST_STACK_PASSWORD"] == nil)
        #expect(environment["CMUX_SOCKET_PASSWORD"] == nil)
    }

    @Test("a cold Cloud page has a loading host and proxy before its first request")
    func coldCloudNavigationKeepsItsLoadingHost() async throws {
        let server = try CloudBrowserProxyTestServer(address: "10.16.0.10", marker: "cold")
        try await server.start()
        defer { server.stop() }
        let panel = BrowserPanel(
            workspaceId: UUID(), initialURL: URL(string: "about:blank"),
            preloadInitialNavigationInBackground: true, websiteDataStore: .nonPersistent()
        )
        defer { panel.close() }
        let readiness = CloudLinkFirstValue<CloudBrowserProxyEndpoint>()
        let model = CloudPortAccessModel(
            target: .init(host: server.address, port: 8000), coordinator: nil,
            wake: {}, startForward: { _ in Issue.record("Unexpected forward"); return 1 },
            stopForward: {}, startBrowserProxy: {
                try #require(await readiness.result)
            }
        )
        let remote = try #require(URL(string: "http://\(server.address):8000/page?source=cold#retained"))
        panel.cloudAccess.configure(model: model, url: remote)
        panel.prepareCloudBrowserStore(machineID: server.marker)
        panel.showCloudAddress(remote)
        model.connect()
        #expect(panel.cloudAccess.nextURL() == nil)
        #expect(server.requests.isEmpty)
        readiness.resolve(server.endpoint)
        let readyDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !model.isReady && ContinuousClock.now < readyDeadline { await Task.yield() }
        let destination = try #require(panel.cloudAccess.nextURL())
        _ = panel.navigate(to: destination)

        // The browser is visible immediately without a connection card. The replacement
        // WebView must still have a loading host while the userspace route starts.
        #expect(panel.webView.window != nil, "Cloud loading must not orphan the replacement WebView")
        #expect(panel.webView.configuration.websiteDataStore.proxyConfigurations.count == 1)
        let loadedDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !panel.cloudAccess.showsPage && ContinuousClock.now < loadedDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(panel.cloudAccess.showsPage, "The initial navigation must complete without Reload")
        #expect(panel.webView.url == remote)
        #expect(try await panel.webView.evaluateJavaScript("document.body.dataset.machine") as? String == "cold")
        #expect(try await panel.webView.evaluateJavaScript("window.__cmuxCloudWebSocketBridgeInstalled === true") as? Bool == true, "Cloud WebSocket bridge script must run before page JavaScript")
        #expect(try await panel.webView.evaluateJavaScript("window.__cmuxCloudWebSocketBridgeConstructor === window.WebSocket") as? Bool == true, "Cloud WebSocket bridge must remain the active constructor")
        #expect((try await panel.webView.evaluateJavaScript("window.__cmuxCloudWebSocketBridgeRewrite('ws://10.16.0.10:8000/_next/hmr?id=fixture')") as? String)?.contains("/__cmux_ws__/") == true, "Cloud WebSocket URLs must be rewritten to the authenticated bridge")
        let websocketDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while (try await panel.webView.evaluateJavaScript("window.cloudWebSocketState") as? String) != "open",
              ContinuousClock.now < websocketDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!server.bridgeRequests.isEmpty, "The Cloud WebSocket bridge must receive the page upgrade")
        let websocketState = try await panel.webView.evaluateJavaScript("JSON.stringify({state:window.cloudWebSocketState,error:window.cloudWebSocketError || null})") as? String
        #expect(websocketState == "{\"state\":\"open\",\"error\":null}", "WebSocket traffic must use the same Cloud browser route: \(websocketState ?? "missing")")
        await model.retire()
    }

    @Test("Cloud websites keep the pane background while styles load, then restore normal page rendering",
          arguments: ["/ordinary", "/vnc.html"])
    func genericWebsiteLoadingBackground(path: String) async throws {
        let styles = CloudLinkFirstValue<Bool>()
        let server = try CloudBrowserProxyTestServer(address: "10.16.0.12", marker: "styles", styles: styles)
        try await server.start()
        defer { styles.resolve(false); server.stop() }
        let panel = BrowserPanel(workspaceId: UUID(), websiteDataStore: .nonPersistent())
        defer { panel.close() }
        let access = model(server: server)
        _ = try await prepare(panel: panel, model: access, server: server)
        let url = try #require(URL(string: "http://\(server.address):8000\(path)"))
        panel.cloudAccess.configure(model: access, url: url)
        panel.navigate(to: try #require(panel.cloudAccess.nextURL()))
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !server.requests.contains(where: { $0.target == "/delayed.css" }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(server.requests.contains(where: { $0.target == "/delayed.css" }))
        #expect(panel.currentURL == url)
        #expect(!panel.cloudAccess.loaded)
        #expect(panel.webView.value(forKey: "drawsBackground") as? Bool == false,
                "A committed document waiting for CSS must not expose WebKit's white bootstrap background")
        styles.resolve(true)
        while !panel.cloudAccess.showsPage, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(panel.cloudAccess.showsPage)
        #expect(panel.webView.value(forKey: "drawsBackground") as? Bool == true,
                "After load, every site owns its document background, including pages without CSS")
        #expect(try await panel.webView.evaluateJavaScript("getComputedStyle(document.body).backgroundColor") as? String == "rgb(18, 20, 24)")
        let unstyled = try #require(URL(string: "http://\(server.address):8000/unstyled"))
        panel.navigate(to: unstyled)
        while (panel.webView.url != unstyled || !panel.cloudAccess.showsPage || panel.webView.isLoading), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(panel.webView.url == unstyled && panel.cloudAccess.showsPage)
        #expect(panel.webView.value(forKey: "drawsBackground") as? Bool == true)
        #expect(try await panel.webView.evaluateJavaScript("document.body.textContent") as? String == "Unstyled page")
        await access.retire()
    }

    @Test("Replacing a carrier registers only its current WebSocket credentials")
    func webSocketBridgeCredentialRotation() {
        let configuration = WKWebViewConfiguration()
        let retained = WKUserScript(source: "window.retained = true", injectionTime: .atDocumentStart, forMainFrameOnly: true)
        configuration.userContentController.addUserScript(retained)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        for token in ["expired", "current"] {
            CloudBrowserRouting.installWebSocketBridge(
                endpoint: .init(host: "127.0.0.1", port: 1234, username: "user", password: "pass", websocketToken: token),
                address: "10.16.0.10", on: webView
            )
        }
        let scripts = configuration.userContentController.userScripts
        #expect(scripts.count == 2)
        #expect(scripts.contains { $0.source == retained.source })
        #expect(!scripts.contains { $0.source.contains("expired") })
        #expect(scripts.contains { $0.source.contains("current") })
    }

    @Test("Secure page WebSockets use WebKit's native TLS through the authenticated CONNECT proxy")
    func secureWebSocketUsesNativeProxy() async throws {
        let tls = try CloudBrowserTLSTestServer()
        let port = try await tls.start()
        defer { tls.stop() }
        let server = try CloudBrowserProxyTestServer(address: "10.16.0.13", marker: "tls", securePort: port)
        try await server.start()
        defer { server.stop() }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.websiteDataStore.proxyConfigurations = [CloudBrowserRouting.configuration(endpoint: server.endpoint, address: server.address)]
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 600, height: 400), configuration: configuration)
        let window = NSWindow(contentRect: webView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        defer { webView.stopLoading(); webView.navigationDelegate = nil; window.contentView = nil; window.close() }
        let navigation = CloudBrowserProxyTestNavigation()
        navigation.trustedFixtureCertificate = tls.certificate
        webView.navigationDelegate = navigation
        try await navigation.load(try #require(URL(string: "https://\(server.address):8443/")), in: webView)
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while (try await webView.evaluateJavaScript("document.body.dataset.ws") as? String) == "pending", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try await webView.evaluateJavaScript("document.body.dataset.ws") as? String == "echo-ok")
        #expect(server.authorizedTargets.filter { $0 == "\(server.address):8443" }.count >= 2,
                "Both HTTPS and WSS must reach the authenticated CONNECT listener")
    }

    @Test("a Cloud profile switch keeps localhost requests on the VM")
    func profileSwitchPreservesCloudRouting() async throws {
        let server = try CloudBrowserProxyTestServer(address: "10.16.0.11", marker: "profile")
        try await server.start()
        defer { server.stop() }
        let profiles = BrowserProfileStore.shared
        let profile = try #require(profiles.createProfile(named: "Cloud routing \(UUID())"))
        defer { _ = profiles.deleteProfile(id: profile.id) }
        let panel = BrowserPanel(workspaceId: UUID(), profileID: profiles.builtInDefaultProfileID)
        defer { panel.close() }
        let access = model(server: server)
        let url = try await prepare(panel: panel, model: access, server: server)
        _ = panel.navigate(to: url)
        let initialDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !panel.cloudAccess.showsPage && ContinuousClock.now < initialDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(panel.cloudAccess.showsPage)
        let previousStore = panel.websiteDataStore
        #expect(panel.switchToProfile(profile.id))
        #expect(panel.websiteDataStore !== previousStore)
        #expect(panel.webView.configuration.websiteDataStore === panel.websiteDataStore)
        #expect(panel.websiteDataStore.proxyConfigurations.count == 1)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while (!panel.cloudAccess.showsPage || panel.webView.url != url || panel.webView.isLoading)
            && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(panel.cloudAccess.showsPage)
        try #require(panel.webView.url == url && !panel.webView.isLoading)
        let posted = try #require(try await panel.webView.callAsyncJavaScript("""
            const response = await fetch('http://localhost:8000/echo', {
              method: 'POST', body: 'after-profile-switch', signal: AbortSignal.timeout(5000)
            });
            return await response.json();
            """, arguments: [:], in: nil, contentWorld: .page) as? [String: String])
        #expect(posted["machine"] == server.marker)
        #expect(posted["host"] == "\(server.address):8000")
        #expect(posted["body"] == "after-profile-switch")
        #expect(panel.webView.url == url)
        await access.retire()
    }

    @Test("two VM origins use the same port without sharing routing or changing document identity")
    func twoMachinesKeepTheirPrivateOrigins() async throws {
        let first = try CloudBrowserProxyTestServer(address: "10.16.0.7", marker: "vm-a")
        let second = try CloudBrowserProxyTestServer(address: "10.16.0.8", marker: "vm-b")
        try await first.start()
        defer { first.stop() }
        try await second.start()
        defer { second.stop() }

        let firstPanel = BrowserPanel(workspaceId: UUID(), websiteDataStore: .nonPersistent())
        let secondPanel = BrowserPanel(workspaceId: UUID(), websiteDataStore: .nonPersistent())
        defer {
            firstPanel.close()
            secondPanel.close()
        }
        let firstModel = model(server: first)
        let secondModel = model(server: second)
        let firstURL = try await prepare(panel: firstPanel, model: firstModel, server: first)
        #expect(firstPanel.websiteDataStore.identifier == nil)
        let secondURL = try await prepare(panel: secondPanel, model: secondModel, server: second)
        #expect(secondPanel.websiteDataStore.identifier == nil)
        #expect(firstPanel.websiteDataStore !== secondPanel.websiteDataStore)
        #expect(firstPanel.webView.configuration.websiteDataStore === firstPanel.websiteDataStore)
        #expect(secondPanel.webView.configuration.websiteDataStore === secondPanel.websiteDataStore)

        // Preparing B after A must not replace A's shared-profile routing.
        let firstNavigation = CloudBrowserProxyTestNavigation()
        let secondNavigation = CloudBrowserProxyTestNavigation()
        firstPanel.webView.navigationDelegate = firstNavigation
        secondPanel.webView.navigationDelegate = secondNavigation
        defer {
            firstPanel.webView.navigationDelegate = nil
            secondPanel.webView.navigationDelegate = nil
        }
        async let firstLoad: Void = firstNavigation.load(firstURL, in: firstPanel.webView)
        async let secondLoad: Void = secondNavigation.load(secondURL, in: secondPanel.webView)
        try await firstLoad
        try await secondLoad

        for (panel, server, url) in [(firstPanel, first, firstURL), (secondPanel, second, secondURL)] {
            let page = try #require(try await panel.webView.evaluateJavaScript("""
                ({href: location.href, origin: location.origin,
                  marker: document.body.dataset.machine, asset: window.cloudAsset,
                  rewrite: window.__cmuxRewriteRemoteLoopbackURL?.('http://localhost:8000/echo') || 'missing'})
                """) as? [String: String])
            #expect(page["href"] == url.absoluteString)
            #expect(page["origin"] == "http://\(server.address):8000")
            #expect(page["marker"] == server.marker)
            #expect(page["asset"] == "\(server.marker)-asset")
            #expect(page["rewrite"] == "http://\(server.address):8000/echo")
            #expect(panel.webView.url == url)

            let posted = try #require(try await panel.webView.callAsyncJavaScript("""
                try {
                const response = await fetch('/echo?source=browser', {
                  method: 'POST', body: 'body-from-' + document.body.dataset.machine,
                  signal: AbortSignal.timeout(5000)
                });
                const text = await response.text();
                try { return JSON.parse(text); } catch (e) { throw new Error('relative response ' + response.status + ': ' + text.slice(0, 200)); }
                } catch (e) { throw new Error('relative POST: ' + e.name + ': ' + e.message + ' at ' + location.href); }
                """, arguments: [:], in: nil, contentWorld: .page) as? [String: String])
            #expect(posted["machine"] == server.marker)
            #expect(posted["host"] == "\(server.address):8000")
            #expect(posted["body"] == "body-from-\(server.marker)")

            // The page's own localhost/0.0.0.0 links are rewritten to this VM's
            // private origin before WebKit's authenticated CONNECT proxy runs.
            let absoluteLoopback = try #require(try await panel.webView.callAsyncJavaScript("""
                try {
                const response = await fetch('http://localhost:8000/echo', {
                  method: 'POST', body: 'absolute-loopback',
                  signal: AbortSignal.timeout(5000)
                });
                const text = await response.text();
                try { return JSON.parse(text); } catch (e) { throw new Error('absolute response ' + response.status + ': ' + text.slice(0, 200)); }
                } catch (e) { throw new Error('absolute localhost POST: ' + e.name + ': ' + e.message + ' at ' + location.href); }
                """, arguments: [:], in: nil, contentWorld: .page) as? [String: String])
            #expect(absoluteLoopback["machine"] == server.marker)
            #expect(absoluteLoopback["host"] == "\(server.address):8000")
            #expect(absoluteLoopback["body"] == "absolute-loopback")
            #expect(server.requests.contains { $0.target == "/page?source=cmdclick" })
            #expect(server.requests.contains { $0.target == "/asset.js" })
            #expect(server.requests.contains { $0.target == "/echo?source=browser" && $0.method == "POST" })
            #expect(server.requests.allSatisfy { $0.host == "\(server.address):8000" })
            #expect(!server.authorizedTargets.isEmpty)
            let remoteTargets = server.authorizedTargets.filter { $0.hasSuffix(":8000") }
            #expect(!remoteTargets.isEmpty)
            #expect(remoteTargets.allSatisfy { $0 == "\(server.address):8000" })
        }

        // A second load of A after B's requests verifies that its route remains owned by A.
        try await firstNavigation.load(firstURL, in: firstPanel.webView)
        #expect(try await firstPanel.webView.evaluateJavaScript("document.body.dataset.machine") as? String == "vm-a")
        await firstModel.retire()
        await secondModel.retire()
    }

    @Test("the CONNECT fixture rejects an unauthenticated client that WebKit can authenticate")
    func proxyCredentialsAreRequired() async throws {
        let server = try CloudBrowserProxyTestServer(address: "10.16.0.9", marker: "auth")
        try await server.start()
        defer { server.stop() }
        let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: server.port)!, using: .tcp)
        defer { client.cancel() }
        try await client.startAndWaitUntilReady(queue: DispatchQueue(label: "cmux.tests.cloud-browser.unauthorized"))
        try await client.sendAll(Data("CONNECT 10.16.0.9:8000 HTTP/1.1\r\nHost: 10.16.0.9:8000\r\n\r\n".utf8))
        let response = try await client.receiveExactly(12)
        #expect(String(decoding: response, as: UTF8.self) == "HTTP/1.1 407")
        #expect(server.authorizedTargets.isEmpty)
        #expect(server.requests.isEmpty)
    }

    @Test("an exited carrier removes readiness and releases its WireGuard claim once")
    func childExitReleasesClaim() async throws {
        let gate = FileManager.default.temporaryDirectory.appendingPathComponent("cmux-browser-proxy-exit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: gate) }
        let releases = CloudBrowserProxyTestReleases()
        let process = CloudBrowserProxyProcess(addresses: ["10.16.0.7"])
        let readyJSON = "{\"host\":\"127.0.0.1\",\"port\":12345,\"username\":\"fixture\",\"password\":\"fixture-secret\"}"
        do {
            let endpoint = try await process.start(
                client: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf '%s\\n' \"$1\"; while [ ! -f \"$2\" ]; do sleep 0.05; done", "cmux-browser-proxy-test", readyJSON, gate.path],
                releaseHub: { await releases.release() }
            )
            #expect(endpoint.port == 12345)
            #expect(await process.readyEndpoint == endpoint)
            try Data().write(to: gate)
            let released = await releases.didRelease
            let observedRelease = await CloudBrowserProxyTestDeadline.value(released)
            #expect(observedRelease == 1)
            #expect(await process.readyEndpoint == nil)
            await process.stop()
            #expect(await releases.count == 1)
        } catch {
            await process.stop()
            throw error
        }
    }

    @Test("stopping a live carrier clears its endpoint and releases its claim once")
    func stoppingCarrierReleasesClaim() async throws {
        let releases = CloudBrowserProxyTestReleases()
        let process = CloudBrowserProxyProcess(addresses: ["10.16.0.7"])
        let readyJSON = "{\"host\":\"127.0.0.1\",\"port\":12345,\"username\":\"fixture\",\"password\":\"fixture-secret\"}"
        do {
            _ = try await process.start(
                client: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf '%s\\n' \"$1\"; exec /bin/sleep 60", "cmux-browser-proxy-test", readyJSON],
                releaseHub: { await releases.release() }
            )
            await process.stop()
            await process.stop()
            #expect(await process.readyEndpoint == nil)
            #expect(await releases.count == 1)
        } catch {
            await process.stop()
            throw error
        }
    }

    private func model(server: CloudBrowserProxyTestServer) -> CloudPortAccessModel {
        CloudPortAccessModel(
            target: CloudPortForwardTarget(host: server.address, port: 8000),
            coordinator: nil,
            wake: {},
            startForward: { _ in
                Issue.record("browser navigation must not create a localhost URL forward")
                return 1
            },
            stopForward: {},
            startBrowserProxy: { server.endpoint }
        )
    }

    private func prepare(panel: BrowserPanel, model: CloudPortAccessModel, server: CloudBrowserProxyTestServer) async throws -> URL {
        let remoteURL = try #require(URL(string: "http://\(server.address):8000/page?source=cmdclick#retained"))
        panel.cloudAccess.configure(model: model, url: remoteURL)
        panel.prepareCloudBrowserStore(machineID: server.marker)
        model.connectBrowser()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !model.isReady && ContinuousClock.now < deadline { await Task.yield() }
        #expect(model.tunnelState == .off)
        #expect(model.browserProxy == server.endpoint)
        let navigationURL = try #require(panel.cloudAccess.nextURL())
        panel.prepareCloudBrowserNavigation()
        #expect(panel.websiteDataStore.proxyConfigurations.count == 1)
        #expect(panel.websiteDataStore.proxyConfigurations.first?.allowFailover == false)
        #expect(navigationURL == remoteURL)
        return navigationURL
    }
}

private actor CloudBrowserProxyTestReleases {
    private(set) var count = 0
    let didRelease = CloudLinkFirstValue<Int>()

    func release() {
        count += 1
        didRelease.resolve(count)
    }
}

private enum CloudBrowserProxyTestDeadline {
    static func value<Value: Sendable>(_ first: CloudLinkFirstValue<Value>, timeout: Duration = .seconds(10)) async -> Value? {
        await withTaskGroup(of: Value?.self) { group in
            group.addTask { await first.result }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            defer { group.cancelAll() }
            return await group.next() ?? nil
        }
    }
}

@MainActor
private final class CloudBrowserProxyTestNavigation: NSObject, WKNavigationDelegate {
    private var result: CloudLinkFirstValue<Result<Void, any Error>>?
    var trustedFixtureCertificate: Data?

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let expected = trustedFixtureCertificate, let trust = challenge.protectionSpace.serverTrust,
              let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
              SecCertificateCopyData(leaf) as Data == expected else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }


    func load(_ url: URL, in webView: WKWebView) async throws {
        let first = CloudLinkFirstValue<Result<Void, any Error>>()
        result = first
        defer { result = nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        webView.load(request)
        guard let completed = await CloudBrowserProxyTestDeadline.value(first, timeout: .seconds(20)) else {
            webView.stopLoading()
            throw NSError(domain: "CloudBrowserProxyIntegrationTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "WebKit did not finish loading \(url)"])
        }
        try completed.get()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        result?.resolve(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        result?.resolve(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        result?.resolve(.failure(error))
    }
}

/// Each fixture accepts one VM address at port 8000 and requires Basic proxy auth.
/// After CONNECT it behaves as that VM's HTTP service, recording the unmodified Host.
private final class CloudBrowserProxyTestServer: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let target: String
        let host: String
        let body: String
    }

    let address: String
    let marker: String
    private let styles: CloudLinkFirstValue<Bool>?
    private let securePort: UInt16?
    private let listener: NWListener
    private let queue = DispatchQueue(label: "cmux.tests.cloud-browser-connect")
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var capturedRequests: [Request] = []
    private var capturedTargets: [String] = []
    private var stopped = false
    private(set) var port: UInt16 = 0
    var requests: [Request] { lock.withLock { capturedRequests } }
    var authorizedTargets: [String] { lock.withLock { capturedTargets } }
    private var capturedBridgeRequests: [String] = []
    var bridgeRequests: [String] { lock.withLock { capturedBridgeRequests } }
    var endpoint: CloudBrowserProxyEndpoint {
        CloudBrowserProxyEndpoint(host: "127.0.0.1", port: port, username: marker, password: "fixture-\(marker)", websocketToken: "ws-token")
    }

    init(address: String, marker: String, styles: CloudLinkFirstValue<Bool>? = nil, securePort: UInt16? = nil) throws {
        self.address = address
        self.marker = marker
        self.styles = styles
        self.securePort = securePort
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws {
        let ready = CloudLinkFirstValue<UInt16>()
        listener.stateUpdateHandler = { [listener] state in
            switch state {
            case .ready: ready.resolve(listener.port?.rawValue)
            case .failed, .cancelled: ready.resolve(nil)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            let accepted = self.lock.withLock {
                guard !self.stopped else { return false }
                self.connections[ObjectIdentifier(connection)] = connection
                return true
            }
            guard accepted else { connection.cancel(); return }
            Task { await self.serve(connection) }
        }
        listener.start(queue: queue)
        guard let bound = await CloudBrowserProxyTestDeadline.value(ready), bound != 0 else {
            stop()
            throw NSError(domain: "CloudBrowserProxyTestServer", code: 1)
        }
        port = bound
    }

    func stop() {
        let active = lock.withLock {
            stopped = true
            let active = Array(connections.values)
            connections.removeAll()
            return active
        }
        listener.cancel()
        for connection in active { connection.cancel() }
    }

    private func serve(_ connection: NWConnection) async {
        // A malformed client or an unused WebKit preconnect cannot leave this fixture parked.
        let timeout = Task {
            do {
                try await Task.sleep(for: .seconds(15))
                connection.cancel()
            } catch {}
        }
        defer {
            timeout.cancel()
            connection.cancel()
            _ = lock.withLock { connections.removeValue(forKey: ObjectIdentifier(connection)) }
        }
        do {
            try await connection.startAndWaitUntilReady(queue: queue)
            let first = try await connection.receiveExactly(1)
            var buffered = Data(first)
            if first[0] == UInt8(ascii: "G") {
                let bridge = try await readRequest(connection, buffered: &buffered)
                lock.withLock { capturedBridgeRequests.append(bridge.target + " | " + (bridge.headers["sec-websocket-protocol"] ?? "")) }
                guard bridge.target.hasPrefix("/__cmux_ws__/") else { return }
                guard bridge.headers["sec-websocket-protocol"]?.contains("cmux-proxy-ws-token") == true,
                      let key = bridge.headers["sec-websocket-key"] else { return }
                let acceptInput = Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)
                let accept = Data(Insecure.SHA1.hash(data: acceptInput)).base64EncodedString()
                try await connection.sendAll(Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Protocol: cmux-proxy-ws-token\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n".utf8))
                try await Task.sleep(for: .seconds(5))
                return
            }
            let connect = try await readRequest(connection, buffered: &buffered)
            let expected = "Basic " + Data("\(marker):fixture-\(marker)".utf8).base64EncodedString()
            guard connect.headers["proxy-authorization"] == expected else {
                try await connection.sendAll(Data("HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"cmux-test\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
                try await connection.finishSending()
                return
            }
            guard connect.method == "CONNECT" else {
                try await connection.sendAll(Data("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
                try await connection.finishSending()
                return
            }
            lock.withLock { capturedTargets.append(connect.target) }
            try await connection.sendAll(Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8))
            if connect.target.hasSuffix(":\(port)") {
                let bridge = try await readRequest(connection, buffered: &buffered)
                lock.withLock { capturedBridgeRequests.append(bridge.target + " | " + (bridge.headers["sec-websocket-protocol"] ?? "")) }
                guard bridge.target.hasPrefix("/__cmux_ws__/"),
                      bridge.headers["sec-websocket-protocol"]?.contains("cmux-proxy-ws-token") == true,
                      let key = bridge.headers["sec-websocket-key"] else { return }
                let acceptInput = Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)
                let accept = Data(Insecure.SHA1.hash(data: acceptInput)).base64EncodedString()
                try await connection.sendAll(Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Protocol: cmux-proxy-ws-token\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n".utf8))
                try await Task.sleep(for: .seconds(5))
                return
            }
            if connect.target == "\(address):8443", let securePort {
                let upstream = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: securePort)!, using: .tcp)
                defer { upstream.cancel() }
                try await upstream.startAndWaitUntilReady(queue: queue)
                if !buffered.isEmpty { try await upstream.sendAll(buffered) }
                await CloudPortForwardRelay.relay(connection, upstream)
                return
            }
            guard connect.target == "\(address):8000" else { return }
            var request = try await readRequest(connection, buffered: &buffered)
            if request.method == "OPTIONS" {
                try await connection.sendAll(Data("HTTP/1.1 204 No Content\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET,POST,OPTIONS\r\nAccess-Control-Allow-Headers: content-type\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n".utf8))
                request = try await readRequest(connection, buffered: &buffered)
            }
            let record = Request(method: request.method, target: request.target, host: request.headers["host"] ?? "", body: request.body)
            lock.withLock { capturedRequests.append(record) }
            let data: Data
            let contentType: String
            if request.target == "/delayed.css", let styles {
                guard await styles.result == true else { return }
                contentType = "text/css"
                data = Data("body { background: rgb(18, 20, 24); color: white; }".utf8)
            } else if request.target == "/unstyled" {
                contentType = "text/html"
                data = Data("<!doctype html><html><body>Unstyled page</body></html>".utf8)
            } else if styles != nil {
                contentType = "text/html"
                data = Data("<!doctype html><html><head><link rel='stylesheet' href='/delayed.css'></head><body>Ordinary website</body></html>".utf8)
            } else if request.target == "/asset.js" {
                contentType = "application/javascript"
                data = Data("window.cloudAsset = '\(marker)-asset';".utf8)
            } else if request.target == "/echo" || request.target.hasPrefix("/echo?") {
                contentType = "application/json"
                data = try JSONSerialization.data(withJSONObject: ["machine": marker, "host": record.host, "body": record.body])
            } else {
                contentType = "text/html; charset=utf-8"
                data = Data("<!doctype html><html><head><script src='/asset.js'></script><script>window.cloudWebSocketState='connecting';window.cloudWebSocket=new WebSocket('ws://'+location.host+'/_next/hmr?id=fixture');window.cloudWebSocket.onopen=()=>window.cloudWebSocketState='open';window.cloudWebSocket.onerror=(e)=>{window.cloudWebSocketState='error';window.cloudWebSocketError=String(e)};</script></head><body data-machine='\(marker)'>\(marker)</body></html>".utf8)
            }
            try await connection.sendAll(Data("HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(data.count)\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET,POST,OPTIONS\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8) + data)
            try await connection.finishSending()
        } catch {
            // A discarded WebKit preconnect is normal. Required requests are verified by
            // navigation, page content, and the recorded HTTP requests in the test itself.
        }
    }

    private struct ParsedRequest {
        let method: String
        let target: String
        let headers: [String: String]
        let body: String
    }

    private func readRequest(_ connection: NWConnection, buffered: inout Data) async throws -> ParsedRequest {
        let separator = Data("\r\n\r\n".utf8)
        while buffered.range(of: separator) == nil {
            guard buffered.count < 32_768 else { throw NSError(domain: "CloudBrowserProxyTestServer", code: 2) }
            let chunk = try await connection.receiveChunk(maximumLength: 16_384)
            if let bytes = chunk.data { buffered.append(bytes) }
            if chunk.isComplete && buffered.range(of: separator) == nil { throw NWConnection.StreamError.endedEarly }
        }
        guard let boundary = buffered.range(of: separator) else { throw NWConnection.StreamError.endedEarly }
        let text = String(decoding: buffered[..<boundary.lowerBound], as: UTF8.self)
        buffered.removeSubrange(..<boundary.upperBound)
        let lines = text.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ")
        guard first.count == 3 else { throw NSError(domain: "CloudBrowserProxyTestServer", code: 3) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).lowercased()] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        let count = Int(headers["content-length"] ?? "0") ?? 0
        guard count >= 0, count <= 65_536 else { throw NSError(domain: "CloudBrowserProxyTestServer", code: 4) }
        while buffered.count < count {
            let chunk = try await connection.receiveChunk(maximumLength: 65_536)
            if let bytes = chunk.data { buffered.append(bytes) }
            if chunk.isComplete && buffered.count < count { throw NWConnection.StreamError.endedEarly }
        }
        let body = String(decoding: buffered.prefix(count), as: UTF8.self)
        buffered.removeFirst(count)
        return ParsedRequest(method: String(first[0]), target: String(first[1]), headers: headers, body: body)
    }
}

/// Local TLS server; the delegate accepts only this ephemeral fixture certificate.
/// Neither the OS trust store nor production certificate verification is modified.
@MainActor
private final class CloudBrowserTLSTestServer {
    let directory: URL
    let process = Process()
    let certificate: Data

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-wss-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let key = directory.appendingPathComponent("key.pem").path
        let cert = directory.appendingPathComponent("cert.pem").path
        for arguments in [
            ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-keyout", key, "-out", cert, "-subj", "/CN=10.16.0.13"],
            ["x509", "-in", cert, "-outform", "DER", "-out", directory.appendingPathComponent("cert.der").path]
        ] {
            let openssl = Process()
            openssl.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            openssl.arguments = arguments
            openssl.standardOutput = FileHandle.nullDevice
            openssl.standardError = FileHandle.nullDevice
            try openssl.run()
            openssl.waitUntilExit()
            guard openssl.terminationStatus == 0 else { throw URLError(.cannotCreateFile) }
        }
        certificate = try Data(contentsOf: directory.appendingPathComponent("cert.der"))
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", #"""
        import socket, ssl, threading, hashlib, base64, sys
        context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(sys.argv[1],sys.argv[2])
        listener=socket.socket();listener.bind(('127.0.0.1',0));listener.listen()
        print(listener.getsockname()[1], flush=True)
        def serve(raw):
          try:
            with context.wrap_socket(raw,server_side=True) as s:
              data=b''
              while b'\r\n\r\n' not in data: data+=s.recv(4096)
              headers=dict(line.split(':',1) for line in data.decode().split('\r\n')[1:] if ':' in line)
              headers={k.lower():v.strip() for k,v in headers.items()}
              if headers.get('upgrade','').lower()=='websocket':
                accept=base64.b64encode(hashlib.sha1((headers['sec-websocket-key']+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest())
                s.sendall(b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: '+accept+b'\r\n\r\n'+b'\x81\x07echo-ok')
                s.recv(4096)
              else:
                body=b'<html><body data-ws="pending"><script>const ws=new WebSocket("wss://"+location.host+"/socket");ws.onmessage=e=>document.body.dataset.ws=e.data;ws.onerror=()=>document.body.dataset.ws="failed";</script></body></html>'
                s.sendall(b'HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: '+str(len(body)).encode()+b'\r\nConnection: close\r\n\r\n'+body)
          except Exception: raw.close()
        while True:
          raw,_=listener.accept();threading.Thread(target=serve,args=(raw,),daemon=True).start()
        """#, cert, key]
    }

    func start() async throws -> UInt16 {
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let ready = CloudLinkFirstValue<UInt16>()
        process.terminationHandler = { _ in ready.resolve(nil) }
        try process.run()
        let reader = Task {
            for await line in CloudLinkPipe.lines(from: output.fileHandleForReading) {
                if let port = UInt16(line) { ready.resolve(port); break }
            }
        }
        defer { reader.cancel() }
        return try #require(await CloudBrowserProxyTestDeadline.value(ready))
    }

    func stop() {
        if process.isRunning { process.terminate(); process.waitUntilExit() }
        try? FileManager.default.removeItem(at: directory)
    }
}
