// Checks whether WebKit sends loopback destinations through a per-data-store
// proxy (WKWebsiteDataStore.proxyConfigurations with an HTTP CONNECT
// nw_proxy_config), which remote localhost for WebKit tabs would need
// (plans/cmux-next/remote-localhost.md section 7).
//
//   swiftc -O scripts/cmux-next/webkit-loopback-proxy-probe.swift -o /tmp/wk-probe && /tmp/wk-probe
//
// It starts a proxy on 127.0.0.1 that demands Basic credentials, points a
// non-persistent store at it (failover off, loopback names as match
// domains), loads each URL in an off-screen WKWebView (no window, never
// activates), and prints one line per URL: `proxied` when the proxy saw its
// CONNECT, `direct` when WebKit bypassed it. Exit 0 when every loopback URL
// was proxied, 1 otherwise. Result on macOS 27.0 (26A428), 2026-09-30:
// localhost, localhost., 127.0.0.1 and [::1] direct; foo.localhost and
// example.com proxied.
import AppKit
import Network
import WebKit

final class Probe: NSObject, WKNavigationDelegate {
    private let listener: NWListener
    private(set) var port: UInt16 = 0
    private var seen: Set<String> = []
    private var onFinish: (() -> Void)?

    init(onReady: @escaping (UInt16) -> Void) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        super.init()
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            guard case .ready = state, let self, let port = self.listener.port?.rawValue else { return }
            self.port = port
            DispatchQueue.main.async { onReady(port) }
        }
        listener.start(queue: .main)
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            let head = String(decoding: data ?? Data(), as: UTF8.self)
            let line = head.split(separator: "\r\n").first.map(String.init) ?? ""
            guard head.contains("Proxy-Authorization") else {
                Self.send(connection, "HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"probe\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                return
            }
            let parts = line.split(separator: " ")
            if parts.count > 1 { self?.seen.insert(String(parts[1])) }
            let body = "<title>proxied</title>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            guard line.hasPrefix("CONNECT") else { return Self.send(connection, response) }
            connection.send(content: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8), completion: .contentProcessed { _ in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in Self.send(connection, response) }
            })
        }
    }

    private static func send(_ connection: NWConnection, _ text: String) {
        connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    func sawProxy(for url: URL) -> Bool {
        guard let host = url.host(percentEncoded: false) else { return false }
        let port = url.port ?? (url.scheme == "https" ? 443 : 80)
        let name = host.contains(":") ? "[\(host)]" : host
        return seen.contains("\(name):\(port)") || seen.contains { $0.hasPrefix("http://\(name):\(port)") }
    }

    func load(_ url: URL, in webView: WKWebView, then finish: @escaping () -> Void) {
        onFinish = finish
        webView.load(URLRequest(url: url, timeoutInterval: 5))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onFinish?() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { onFinish?() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { onFinish?() }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
// A closed high port: a direct connection fails fast (WebKit blocks low ports like 9 itself).
let loopback = ["http://localhost:47819/", "http://localhost.:47819/", "http://127.0.0.1:47819/", "http://[::1]:47819/", "http://foo.localhost:47819/"]
let control = ["http://example.com/"]
var remaining = (loopback + control).compactMap(URL.init(string:))
var failures = 0
var webView: WKWebView?
var probe: Probe?

func next() {
    guard let probe, let webView else { return }
    guard !remaining.isEmpty else { exit(failures == 0 ? 0 : 1) }
    let url = remaining.removeFirst()
    probe.load(url, in: webView) {
        let proxied = probe.sawProxy(for: url)
        if loopback.contains(url.absoluteString), !proxied { failures += 1 }
        print("\(proxied ? "proxied" : "direct ")  \(url.absoluteString)")
        DispatchQueue.main.async { next() }
    }
}

probe = try Probe { port in
    let store = WKWebsiteDataStore.nonPersistent()
    var proxy = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!))
    proxy.allowFailover = false
    proxy.applyCredential(username: "probe", password: "probe")
    proxy.matchDomains = ["localhost", "127.0.0.1", "::1", "example.com"]
    store.proxyConfigurations = [proxy]
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = store
    let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), configuration: configuration)
    view.navigationDelegate = probe
    webView = view
    next()
}
app.run()
