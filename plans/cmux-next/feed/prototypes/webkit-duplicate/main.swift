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
        report.observe("C1", "control: interactionState alone carries sessionStorage?",
                       expected: "unknown", actual: "load=\(c1Load) headSS=\(c1HeadSS)")
        c1.close()

        // C2: naive duplicate by copying A's configuration.
        let naiveConfig = a.webView.configuration.copy() as! WKWebViewConfiguration
        let sharedController = naiveConfig.userContentController === a.webView.configuration.userContentController
        let c2 = Tab(name: "C2", configuration: naiveConfig)
        _ = await c2.restore(a.webView.interactionState)
        let c2Shim = await c2.js("return String(window.__headShim)")
        report.observe("C2", "control: configuration.copy() keeps the agent's controller and shim",
                       expected: "shim leaks (the trap a fresh controller avoids)",
                       actual: "sameController=\(sharedController) headShim=\(c2Shim)")
        c2.close()

        // 3. Duplicate D: same store, fresh controller, interactionState,
        //    seed A's top-origin sessionStorage in the app world.
        let aSession = await snapshot(a)
        report.check("D0", "read A's top-origin sessionStorage from the app world",
                     expected: "ssKey=agent-ss", actual: aSession.map { "\($0.origin) \($0.items)" } ?? "nil",
                     aSession?.items["ssKey"] == "agent-ss")
        let dConfig = freshConfiguration()
        let dSeed = aSession.map(seedScript)
        if let dSeed { dConfig.userContentController.addUserScript(dSeed) }
        let d = Tab(name: "D", configuration: dConfig)
        // One-shot seed: drop it once the first document committed, so a
        // later reload in D does not overwrite what the site changed.
        d.nav.onCommit = { [weak d] in
            if let d, let dSeed { removeUserScript(dSeed, from: d.webView.configuration.userContentController) }
        }
        let statsBeforeD = await server.stats()
        let dLoad = await d.restore(a.webView.interactionState)
        await settle()
        let statsAfterD = await server.stats()
        report.check("D1", "D restores A's current entry", expected: "finish /page, url == A.url",
                     actual: "\(dLoad) url=\(d.webView.url?.absoluteString ?? "nil")",
                     dLoad == "finish /page" && d.webView.url == a.webView.url)
        let pageHits = (statsAfterD["GET /page"] ?? 0) - (statsBeforeD["GET /page"] ?? 0)
        report.observe("D1n", "restore in D hits the network for /page", actual: "GET /page requests during restore: \(pageHits)")
        report.check("D2", "D history matches A (back list count)", expected: "\(aBackCount)",
                     actual: "\(d.webView.backForwardList.backList.count)", d.webView.backForwardList.backList.count == aBackCount)
        let dWho = await whoami(d)
        report.check("D3", "D sends A's cookies incl. HttpOnly sid", expected: "sid=agent-session; pref=dark",
                     actual: dWho, dWho.contains("sid=agent-session") && dWho.contains("pref=dark"))
        let dDocCookie = await d.js("return document.cookie")
        report.check("D3h", "sid is HttpOnly (absent from document.cookie in D)", expected: "no sid",
                     actual: dDocCookie, !dDocCookie.contains("sid=") && dDocCookie.contains("pref=dark"))
        let dLS = await d.js("return String(localStorage.getItem('lsKey'))")
        report.check("D4", "D sees A's localStorage", expected: "agent-ls", actual: dLS, dLS == "agent-ls")
        let dHeadSS = decode(await d.js("return window.__headSS"))
        report.check("D5", "seeded sessionStorage visible to D's inline head script (document-start ran first)",
                     expected: "ssKey=agent-ss at head", actual: "\(dHeadSS)", dHeadSS["ssKey"] == "agent-ss")
        let dSS = await d.js("return String(sessionStorage.getItem('ssKey'))")
        report.check("D6", "D sessionStorage after load", expected: "agent-ss", actual: dSS, dSS == "agent-ss")
        let dForm = await d.js("return document.getElementById('q').value")
        // Not a pass/fail claim: WebKit saves form state into a history item
        // only when the document is torn down (F1-F4), so the current entry's
        // values never reach interactionState.
        report.observe("D7", "D form value of the current entry", expected: "typed by agent (if WebKit carried it)", actual: "'\(dForm)'")
        let dScroll = await d.js("return String(window.scrollY)")
        report.check("D8", "D scroll offset restored", expected: "1234", actual: dScroll, dScroll == "1234")
        let dShim = await d.js("return JSON.stringify({head: window.__headShim, now: typeof window.__agentShim})")
        report.check("D9", "agent shim absent in D", expected: "head null, now undefined", actual: dShim,
                     dShim == #"{"head":null,"now":"undefined"}"#)
        let dSeedGone = d.webView.configuration.userContentController.userScripts.isEmpty
        report.check("D10", "seed script removed after first commit", expected: "no user scripts in D",
                     actual: "userScripts=\(d.webView.configuration.userContentController.userScripts.count)", dSeedGone)

        // One-shot: a site change in D survives a reload.
        _ = await d.js("sessionStorage.setItem('ssKey', 'changed-in-D'); return 'ok'")
        let dReload = await d.reload()
        let dAfterReload = await d.js("return String(sessionStorage.getItem('ssKey'))")
        report.check("D11", "site change in D survives reload (seed is one-shot)", expected: "changed-in-D",
                     actual: "\(dReload) ssKey=\(dAfterReload)", dAfterReload == "changed-in-D")

        // 4. Sign-in in D: the site's script sets sessionStorage and a JS
        //    cookie and posts the login form; the server sets a new HttpOnly
        //    session and redirects (303) to /home.
        let signInBefore = d.nav.completed
        _ = await d.js("""
        sessionStorage.setItem('authToken', 'tok-123');
        document.cookie = 'js_login=1; Path=/; SameSite=Lax';
        document.getElementById('loginform').submit();
        return 'submitted';
        """)
        let dSignIn = await d.nav.wait(after: signInBefore)
        report.check("S1", "sign-in in D ends on /home", expected: "finish /home", actual: dSignIn, dSignIn == "finish /home")
        let dWho2 = await whoami(d)
        report.check("S2", "D has the new session cookie", expected: "sid=user-session; js_login=1", actual: dWho2,
                     dWho2.contains("sid=user-session") && dWho2.contains("js_login=1"))
        report.observe("S3", "D history after sign-in (POST+303 leaves no /login entry)",
                       actual: (d.webView.backForwardList.backList.map { $0.url.path } + [d.webView.url?.path ?? "?"]).joined(separator: " > "))

        // FD3 input: the cookies that changed during D's lifetime.
        let cookiesAfter = await cookies()
        func key(_ c: HTTPCookie) -> String { "\(c.name)|\(c.domain)|\(c.path)" }
        let beforeByKey = Dictionary(cookiesBefore.map { (key($0), $0.value) }, uniquingKeysWith: { a, _ in a })
        let changed = cookiesAfter.filter { beforeByKey[key($0)] != $0.value }
            .map { "\($0.name)\($0.isHTTPOnly ? " (HttpOnly)" : "")" }.sorted()
        report.check("S4", "cookie diff across D's lifetime names the sign-in cookies (FD3 hide list)",
                     expected: "[js_login, sid (HttpOnly)]", actual: "\(changed)",
                     changed == ["js_login", "sid (HttpOnly)"])

        // 5. Copy-back: D's top-origin sessionStorage into A, close D, GET A
        //    to D's final URL.
        let dSession = await snapshot(d)
        let finalURL = d.webView.url
        d.close()
        let aSeed = dSession.map(seedScript)
        if let aSeed { a.webView.configuration.userContentController.addUserScript(aSeed) }
        a.nav.onCommit = { [weak a] in
            if let a, let aSeed { removeUserScript(aSeed, from: a.webView.configuration.userContentController) }
        }
        let aNav = finalURL.map { $0 } ?? server.url("/home")
        let aGo = await a.load(aNav)
        report.check("B1", "A navigates by GET to D's final URL", expected: "finish /home", actual: aGo, aGo == "finish /home")
        let aWho2 = await whoami(a)
        report.check("B2", "A sees the new session cookie", expected: "sid=user-session; js_login=1", actual: aWho2,
                     aWho2.contains("sid=user-session") && aWho2.contains("js_login=1"))
        let aHeadSS = decode(await a.js("return window.__headSS"))
        report.check("B3", "A's inline head script sees D's sessionStorage (new key and D's change)",
                     expected: "authToken=tok-123, ssKey=changed-in-D", actual: "\(aHeadSS)",
                     aHeadSS["authToken"] == "tok-123" && aHeadSS["ssKey"] == "changed-in-D")
        let aShim2 = await a.js("return String(window.__agentShim)")
        report.check("B4", "A keeps its agent shim; only the app-world seed was removed", expected: "1, 1 user script left",
                     actual: "shim=\(aShim2) userScripts=\(a.webView.configuration.userContentController.userScripts.count)",
                     aShim2 == "1" && a.webView.configuration.userContentController.userScripts.count == 1)
        let aHistory = a.webView.backForwardList.backList.map { $0.url.path } + [a.webView.url?.path ?? "?"]
        report.check("B5", "A's history holds no /login entry", expected: "/page > /home",
                     actual: aHistory.joined(separator: " > "), !aHistory.contains("/login"))

        // 6. POST entry: A2's current entry is a POST result (no redirect).
        let a2 = Tab(name: "A2", configuration: agentConfiguration())
        _ = await a2.load(server.url("/form"))
        let postBefore = a2.nav.completed
        _ = await a2.js("document.getElementById('f').submit(); return 'ok'")
        let a2Post = await a2.nav.wait(after: postBefore)
        let a2Count = await a2.js("return String(window.__postCount)")
        report.observe("P0", "A2 current entry is a POST result", actual: "\(a2Post) postCount=\(a2Count)")
        await settle()
        let postStatsBefore = await server.stats()
        let d2 = Tab(name: "D2", configuration: freshConfiguration())
        let d2Load = await d2.restore(a2.webView.interactionState, timeout: 8)
        await settle()
        let postStatsAfter = await server.stats()
        let reposts = (postStatsAfter["POST /posted"] ?? 0) - (postStatsBefore["POST /posted"] ?? 0)
        let d2Count = await d2.js("return String(window.__postCount)")
        let d2Text = await d2.js("return document.body ? document.body.innerText.slice(0, 80) : '(no body)'")
        report.observe("P1", "restoring a POST entry in D2 (no guard)",
                       actual: "outcome=\(d2Load) url=\(d2.webView.url?.absoluteString ?? "nil") POSTs sent during restore=\(reposts) postCount=\(d2Count) body=\(d2Text) events=\(d2.nav.events)")
        report.observe("P2", "restoring a POST entry with no guard", expected: "no re-POST",
                       actual: "POSTs sent: \(reposts)")
        d2.close()

        // P3: the same restore with a policy guard that cancels main-frame
        // POSTs in the duplicate.
        let d2b = Tab(name: "D2b", configuration: freshConfiguration())
        d2b.nav.refusePOST = true
        let guardBefore = await server.stats()
        let d2bLoad = await d2b.restore(a2.webView.interactionState, timeout: 8)
        await settle()
        let guardAfter = await server.stats()
        let guardedPosts = (guardAfter["POST /posted"] ?? 0) - (guardBefore["POST /posted"] ?? 0)
        let d2bHistory = d2b.webView.backForwardList.backList.map { $0.url.path }
        report.check("P3", "a POST-cancelling policy in D stops the re-POST", expected: "0 POSTs",
                     actual: "POSTs=\(guardedPosts) outcome=\(d2bLoad) url=\(d2b.webView.url?.path ?? "nil") back=\(d2bHistory) events=\(d2b.nav.events)",
                     guardedPosts == 0)
        d2b.close()
        a2.close()

        // F: form state of a back entry (not the current one). A3 types on
        // /page, then navigates to /home; D5 restores and goes back.
        let a3 = Tab(name: "A3", configuration: agentConfiguration())
        _ = await a3.load(server.url("/page"))
        _ = await a3.js("""
        document.getElementById('q').value = 'typed then left';
        const q2 = document.getElementById('q2');
        q2.focus();
        document.execCommand('insertText', false, 'inserted then left');
        q2.blur();
        window.scrollTo(0, 777);
        return 'ok';
        """)
        await settle()
        _ = await a3.load(server.url("/home"))
        await settle()
        let d5 = Tab(name: "D5", configuration: freshConfiguration())
        _ = await d5.restore(a3.webView.interactionState)
        let backBefore = d5.nav.completed
        d5.webView.goBack()
        let d5Back = await d5.nav.wait(after: backBefore)
        await settle()
        let formState = "return JSON.stringify({q: document.getElementById('q').value, q2: document.getElementById('q2').value, scrollY: window.scrollY, persisted: window.__persisted === undefined ? null : window.__persisted})"
        let d5Form = await d5.js(formState)
        report.observe("F1", "form values and scroll of a BACK entry in D after restore + goBack",
                       expected: "q='typed then left', q2='inserted then left', 777", actual: "\(d5Back) \(d5Form)")
        d5.close()
        // Control: the same goBack inside A3 itself (no interactionState).
        let a3BackBefore = a3.nav.completed
        a3.webView.goBack()
        let a3Back = await a3.nav.wait(after: a3BackBefore)
        await settle()
        let a3Form = await a3.js(formState)
        report.observe("F2", "control: goBack inside A3 itself", actual: "\(a3Back) \(a3Form)")
        a3.close()

        // F3/F4: the same with A4's back/forward cache off (control only,
        // private preference), so A4's own goBack must reload the page and
        // restore form state from its history item.
        let a4Config = agentConfiguration()
        if a4Config.preferences.responds(to: NSSelectorFromString("_setUsesPageCache:")) {
            a4Config.preferences.setValue(false, forKey: "usesPageCache")
        } else {
            report.notes.append("F4: WKPreferences has no _setUsesPageCache:; the control keeps the back/forward cache")
        }
        let a4 = Tab(name: "A4", configuration: a4Config)
        _ = await a4.load(server.url("/page"))
        _ = await a4.js("""
        document.getElementById('q').value = 'typed then left';
        const q2 = document.getElementById('q2');
        q2.focus();
        document.execCommand('insertText', false, 'inserted then left');
        q2.blur();
        window.scrollTo(0, 777);
        return 'ok';
        """)
        await settle()
        _ = await a4.load(server.url("/home"))
        await settle()
        let a4State = a4.webView.interactionState
        let d6 = Tab(name: "D6", configuration: freshConfiguration())
        _ = await d6.restore(a4State)
        let d6BackBefore = d6.nav.completed
        d6.webView.goBack()
        let d6Back = await d6.nav.wait(after: d6BackBefore)
        await settle()
        let d6Form = await d6.js(formState)
        report.observe("F3", "A4 (no back/forward cache): form values of a BACK entry in D6 after restore + goBack",
                       expected: "q='typed then left', q2='inserted then left', 777", actual: "\(d6Back) \(d6Form)")
        d6.close()
        let a4BackBefore = a4.nav.completed
        a4.webView.goBack()
        let a4Back = await a4.nav.wait(after: a4BackBefore)
        await settle()
        let a4Form = await a4.js(formState)
        report.observe("F4", "control: goBack inside A4 itself with the back/forward cache off", actual: "\(a4Back) \(a4Form)")
        a4.close()

        // 7. Service workers: a worker the agent registered controls D in the
        //    same store; removing the origin's registrations stops that.
        let swReg = await a.js("""
        if (!navigator.serviceWorker) { return 'no navigator.serviceWorker'; }
        try {
          await navigator.serviceWorker.register('/sw.js', {scope: '/'});
          await navigator.serviceWorker.ready;
          return 'registered';
        } catch (e) { return 'error: ' + e; }
        """)
        report.observe("W0", "agent registers a service worker in A", actual: swReg)
        if swReg == "registered" {
            let d3 = Tab(name: "D3", configuration: freshConfiguration())
            _ = await d3.load(server.url("/page"))
            let d3Controlled = await d3.js("return String(window.__headSWController)")
            report.check("W1", "agent's service worker controls a new tab in the same store", expected: "true",
                         actual: d3Controlled, d3Controlled == "true")
            d3.close()
            let swType: Set<String> = [WKWebsiteDataTypeServiceWorkerRegistrations]
            let records = await store.dataRecords(ofTypes: swType)
            let local = records.filter { $0.displayName.contains("127.0.0.1") || $0.displayName.contains("localhost") }
            report.observe("W2", "service-worker data records", actual: records.map(\.displayName).joined(separator: ", "))
            await store.removeData(ofTypes: swType, for: local)
            let d4 = Tab(name: "D4", configuration: freshConfiguration())
            _ = await d4.load(server.url("/page"))
            let d4Controlled = await d4.js("return String(window.__headSWController)")
            report.check("W3", "after removing the origin's registrations a new tab is not controlled", expected: "false",
                         actual: d4Controlled, d4Controlled == "false")
            d4.close()
        }

        a.close()
        report.notes.append("Requests per method and path over the whole run: \(await server.stats().sorted { $0.key < $1.key })")
        report.notes.append("GET /page requests before D: \(statsBefore["GET /page"] ?? 0)")
    }

    func clearData() async {
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    /// Call after the last reference to the store is gone; WebKit refuses
    /// while a WKWebsiteDataStore object for the identifier is alive.
    static func removeStore(_ storeID: UUID) async {
        do {
            try await WKWebsiteDataStore.remove(forIdentifier: storeID)
            FileHandle.standardError.write(Data("cleanup: removed store \(storeID)\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("cleanup: store \(storeID) not removed: \(error.localizedDescription)\n".utf8))
        }
    }
}

// MARK: - Main

@MainActor func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let here = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
    let reportPath = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil

    Task { @MainActor in
        // Watchdog: a hung step must not leave the process running.
        try? await Task.sleep(for: .seconds(120))
        FileHandle.standardError.write(Data("watchdog: timeout\n".utf8))
        exit(2)
    }
    Task { @MainActor in
        let server: TestServer
        do {
            server = try TestServer(scriptURL: here.appendingPathComponent("server.py"))
        } catch {
            FileHandle.standardError.write(Data("server: \(error)\n".utf8))
            exit(3)
        }
        // The network process keeps this run's store busy until exit, so
        // each run removes the (empty) stores earlier runs left behind. They
        // live under this binary's own name in ~/Library/WebKit.
        for oldID in await WKWebsiteDataStore.allDataStoreIdentifiers {
            await Prototype.removeStore(oldID)
        }
        var prototype: Prototype? = Prototype(server: server)
        await prototype!.run()
        let json = prototype!.report.json()
        print(json)
        if let reportPath {
            try? json.write(toFile: reportPath, atomically: true, encoding: .utf8)
        }
        let failed = prototype!.report.checks.contains { $0.pass == false }
        let storeID = prototype!.storeID
        await prototype!.clearData()
        prototype = nil
        await Prototype.removeStore(storeID)
        server.stop()
        exit(failed ? 1 : 0)
    }
    app.run()
}

MainActor.assumeIsolated { main() }
