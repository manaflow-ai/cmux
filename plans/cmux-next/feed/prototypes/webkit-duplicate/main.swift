// WebKit tab-duplication prototype for feed.md section 10 (N12, FD3-FD5).
//
// Proves on WebKit: agent tab A in a non-default persistent data store,
// duplicate D in the same store with a fresh WKUserContentController,
// `D.interactionState = A.interactionState`, A's top-origin sessionStorage
// seeded into D by a document-start script in an app-private content world,
// sign-in in D, copy-back of D's sessionStorage into A, and A's GET
// navigation to D's final URL.
//
// Build and run: see README.md (./run.sh). Prints a JSON report and exits.
// Windows are borderless and offscreen; the app is an accessory app and never
// activates or takes key.

import AppKit
import Foundation
import WebKit

// MARK: - Report

struct Check: Codable {
    var id: String
    var name: String
    /// "check" is a pass/fail claim; "observe" records behavior without a
    /// claim (controls and open questions).
    var kind: String
    var pass: Bool?
    var expected: String
    var actual: String
}

@MainActor final class Report {
    var checks: [Check] = []
    var environment: [String: String] = [:]
    var notes: [String] = []

    func check(_ id: String, _ name: String, expected: String, actual: String, _ pass: Bool) {
        checks.append(Check(id: id, name: name, kind: "check", pass: pass, expected: expected, actual: actual))
        FileHandle.standardError.write(Data("[\(pass ? "PASS" : "FAIL")] \(id) \(name): \(actual)\n".utf8))
    }

    func observe(_ id: String, _ name: String, expected: String = "", actual: String) {
        checks.append(Check(id: id, name: name, kind: "observe", pass: nil, expected: expected, actual: actual))
        FileHandle.standardError.write(Data("[OBS ] \(id) \(name): \(actual)\n".utf8))
    }

    func json() -> String {
        struct Out: Codable {
            var environment: [String: String]
            var summary: [String: Int]
            var checks: [Check]
            var notes: [String]
        }
        let claims = checks.filter { $0.kind == "check" }
        let out = Out(
            environment: environment,
            summary: [
                "checks": claims.count,
                "passed": claims.filter { $0.pass == true }.count,
                "failed": claims.filter { $0.pass == false }.count,
                "observations": checks.count - claims.count,
            ],
            checks: checks,
            notes: notes
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(out)) ?? Data(), as: UTF8.self)
    }
}

// MARK: - Navigation waiting

/// Counts finished navigations (finish or fail) so a caller can read the
/// count, start a load, and wait for the next completion without a race.
@MainActor final class NavTracker: NSObject, WKNavigationDelegate {
    private(set) var completed = 0
    private(set) var lastOutcome = "none"
    private(set) var events: [String] = []
    private var waiters: [Int: (after: Int, cont: CheckedContinuation<String, Never>)] = [:]
    private var nextWaiter = 0
    /// Runs once on the next committed main-frame navigation.
    var onCommit: (() -> Void)?
    /// When true, main-frame POST navigations are cancelled (the guard a
    /// duplicate needs so restoring a POST entry cannot send it again).
    var refusePOST = false

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        let method = navigationAction.request.httpMethod ?? "?"
        let types: [WKNavigationType: String] = [
            .linkActivated: "link", .formSubmitted: "formSubmitted", .backForward: "backForward",
            .reload: "reload", .formResubmitted: "formResubmitted", .other: "other",
        ]
        let type = types[navigationAction.navigationType] ?? "\(navigationAction.navigationType.rawValue)"
        let main = navigationAction.targetFrame?.isMainFrame ?? false
        let cancel = refusePOST && main && method == "POST"
        events.append("policy \(method) \(type) \(navigationAction.request.url?.path ?? "?") main=\(main)\(cancel ? " CANCEL" : "")")
        decisionHandler(cancel ? .cancel : .allow)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        events.append("commit \(webView.url?.path ?? "?")")
        if let action = onCommit {
            onCommit = nil
            action()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        complete("finish \(webView.url?.path ?? "?")")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        complete("fail \((error as NSError).domain) \((error as NSError).code)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        complete("failProvisional \((error as NSError).domain) \((error as NSError).code)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        complete("webContentProcessTerminated")
    }

    private func complete(_ outcome: String) {
        completed += 1
        lastOutcome = outcome
        events.append(outcome)
        for (key, waiter) in waiters where completed > waiter.after {
            waiters[key] = nil
            waiter.cont.resume(returning: outcome)
        }
    }

    /// Waits for the first completion after `after`, or returns "timeout".
    func wait(after: Int, timeout: Double = 10) async -> String {
        if completed > after { return lastOutcome }
        let key = nextWaiter
        nextWaiter += 1
        return await withCheckedContinuation { cont in
            waiters[key] = (after, cont)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                if let waiter = self.waiters.removeValue(forKey: key) {
                    waiter.cont.resume(returning: "timeout")
                }
            }
        }
    }
}

// MARK: - Tabs

@MainActor final class Tab {
    let name: String
    let webView: WKWebView
    let nav = NavTracker()
    let window: NSWindow

    init(name: String, configuration: WKWebViewConfiguration) {
        self.name = name
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        webView.navigationDelegate = nav
        // Borderless windows cannot become key; offscreen keeps the display
        // untouched. The window is never ordered front (see README).
        window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: 800, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.contentView = webView
        if ProcessInfo.processInfo.environment["PROTO_ORDER_FRONT"] == "1" {
            window.orderFrontRegardless()
        }
    }

    func load(_ url: URL) async -> String {
        let before = nav.completed
        webView.load(URLRequest(url: url))
        return await nav.wait(after: before)
    }

    func restore(_ state: Any?, timeout: Double = 10) async -> String {
        let before = nav.completed
        webView.interactionState = state
        return await nav.wait(after: before, timeout: timeout)
    }

    func reload() async -> String {
        let before = nav.completed
        webView.reload()
        return await nav.wait(after: before)
    }

    /// Runs an async function body and returns its string result.
    func js(_ body: String, world: WKContentWorld = .page) async -> String {
        do {
            let value = try await webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: world)
            if let string = value as? String { return string }
            if let number = value as? NSNumber { return number.stringValue }
            return value.map { "\($0)" } ?? "null"
        } catch {
            return "error: \(error.localizedDescription)"
        }
    }

    func close() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        window.contentView = nil
        window.close()
    }
}

// MARK: - Scripts

/// The app-private world. Pages and agent scripts cannot see its globals.
let appWorld = WKContentWorld.world(name: "cmux.duplicate")

let readSessionStorageBody = """
var o = {};
for (var i = 0; i < sessionStorage.length; i++) {
  var k = sessionStorage.key(i);
  o[k] = sessionStorage.getItem(k);
}
return JSON.stringify({origin: location.origin, items: o});
"""

struct SessionSnapshot: Codable {
    var origin: String
    var items: [String: String]
}

/// A document-start script that replaces the top origin's sessionStorage
/// with `snapshot.items`, only when the document is on `snapshot.origin`.
@MainActor func seedScript(_ snapshot: SessionSnapshot) -> WKUserScript {
    let payload = String(decoding: (try? JSONEncoder().encode(snapshot)) ?? Data(), as: UTF8.self)
    let source = """
    (function () {
      var seed = \(payload);
      if (location.origin !== seed.origin) { return; }
      try {
        sessionStorage.clear();
        Object.keys(seed.items).forEach(function (k) { sessionStorage.setItem(k, seed.items[k]); });
      } catch (e) {}
    })();
    """
    return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: appWorld)
}

/// WKUserContentController has no public per-script or per-world removal
/// (only removeAllUserScripts), so removing one script is remove-all plus
/// re-adding the others.
@MainActor func removeUserScript(_ script: WKUserScript, from controller: WKUserContentController) {
    let keep = controller.userScripts.filter { $0 !== script }
    controller.removeAllUserScripts()
    keep.forEach(controller.addUserScript)
}

/// What the agent installs on its own tab A.
@MainActor func makeAgentShimScript() -> WKUserScript {
    WKUserScript(source: "window.__agentShim = 1;", injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
}

// MARK: - Server

@MainActor final class TestServer {
    let process = Process()
    let port: Int

    init(scriptURL: URL) throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", scriptURL.path]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle(forWritingAtPath: "/dev/null")
        if ProcessInfo.processInfo.environment["PROTO_SERVER_LOG"] == "1" {
            process.standardError = FileHandle.standardError
        }
        try process.run()
        var buffer = Data()
        while !buffer.contains(UInt8(ascii: "\n")) {
            let chunk = out.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
        }
        guard let line = String(data: buffer, encoding: .utf8)?.split(separator: "\n").first,
              let port = Int(line.trimmingCharacters(in: .whitespaces)) else {
            process.terminate()
            throw NSError(domain: "proto", code: 1, userInfo: [NSLocalizedDescriptionKey: "server gave no port"])
        }
        self.port = port
    }

    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(port)\(path)")! }

    func stats() async -> [String: Int] {
        var request = URLRequest(url: url("/stats"))
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let counts = try? JSONDecoder().decode([String: Int].self, from: data) else { return [:] }
        return counts
    }

    func stop() {
        if process.isRunning { process.terminate() }
    }
}

// MARK: - Prototype

@MainActor final class Prototype {
    let report = Report()
    let server: TestServer
    let store: WKWebsiteDataStore
    let storeID = UUID()

    init(server: TestServer) {
        self.server = server
        // Non-default persistent store, like the agent profile in
        // WebKitProfileStore.
        store = WKWebsiteDataStore(forIdentifier: storeID)
    }

    /// The production configuration path: the profile's store, a fresh
    /// controller (WebKitEngine.prepare does the same for every tab).
    func freshConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        configuration.userContentController = WKUserContentController()
        return configuration
    }

    func agentConfiguration() -> WKWebViewConfiguration {
        let configuration = freshConfiguration()
        configuration.userContentController.addUserScript(makeAgentShimScript())
        return configuration
    }

    func cookies() async -> [HTTPCookie] {
        await store.httpCookieStore.allCookies()
    }

    func decode(_ json: String) -> [String: String] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for (key, value) in object { out[key] = "\(value)" }
        return out
    }

    func snapshot(_ tab: Tab) async -> SessionSnapshot? {
        let raw = await tab.js(readSessionStorageBody, world: appWorld)
        return try? JSONDecoder().decode(SessionSnapshot.self, from: Data(raw.utf8))
    }

    func whoami(_ tab: Tab) async -> String {
        await tab.js("const r = await fetch('/whoami', {cache: 'no-store', credentials: 'same-origin'}); return (await r.json()).cookie;")
    }

    func settle() async {
        // A short fixed pause so WebKit can push scroll and form state to the
        // UI process and apply restored scroll after load. Prototype only.
        try? await Task.sleep(for: .milliseconds(600))
    }

    func run() async {
        report.environment["os"] = ProcessInfo.processInfo.operatingSystemVersionString
        report.environment["webkit"] = Bundle(for: WKWebView.self).infoDictionary?["CFBundleVersion"] as? String ?? "?"
        report.environment["store"] = "WKWebsiteDataStore(forIdentifier:) \(storeID.uuidString)"
        report.environment["orderFront"] = ProcessInfo.processInfo.environment["PROTO_ORDER_FRONT"] ?? "0"

        // 1. Agent tab A: cookies (incl. HttpOnly), localStorage,
        //    sessionStorage, typed input, scroll, agent document-start shim.
        let a = Tab(name: "A", configuration: agentConfiguration())
        let pageURL = server.url("/page")
        let aLoad = await a.load(pageURL)
        report.check("A0", "agent tab A loads /page", expected: "finish /page", actual: aLoad, aLoad == "finish /page")
        let aShim = await a.js("return String(window.__agentShim)")
        report.check("A1", "agent shim runs in A", expected: "1", actual: aShim, aShim == "1")
        let setup = await a.js("""
        localStorage.setItem('lsKey', 'agent-ls');
        sessionStorage.setItem('ssKey', 'agent-ss');
        const q = document.getElementById('q');
        q.focus();
        q.value = 'typed by agent';
        q.dispatchEvent(new Event('input', {bubbles: true}));
        q.blur();
        window.scrollTo(0, 1234);
        return JSON.stringify({scrollY: window.scrollY, value: q.value, cookie: document.cookie});
        """)
        report.observe("A2", "state set in A (page world)", actual: setup)
        let aWho = await whoami(a)
        report.check("A3", "A sends HttpOnly sid and pref", expected: "sid=agent-session; pref=dark",
                     actual: aWho, aWho.contains("sid=agent-session") && aWho.contains("pref=dark"))
        await settle()
        let aBackCount = a.webView.backForwardList.backList.count
        let cookiesBefore = await cookies()
        let statsBefore = await server.stats()

        // 2. Controls.
        // C1: interactionState alone (no seed) — does it carry sessionStorage?
        let c1 = Tab(name: "C1", configuration: freshConfiguration())
        let c1Load = await c1.restore(a.webView.interactionState)
        let c1HeadSS = await c1.js("return window.__headSS")
        repo