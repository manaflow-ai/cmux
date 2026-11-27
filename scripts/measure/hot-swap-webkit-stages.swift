// Times one .tsx save reaching a WKWebView through the webviews dev server, the way the Mac app loads
// it (no Playwright: a real WKWebView, its page served under cmux-agent://pane by a scheme handler
// that fetches each file from the dev server, as AgentPaneSchemeHandler+DevServer does). No window
// is shown: the page counts as hidden, which is the state WebKit's DOM timer throttling puts a
// visible page in when its app goes visually idle (PageClientImplMac isVisuallyIdle: the window
// server says the app's windows stopped changing, or the view is not visible). Page::
// updateDOMTimerAlignmentInterval then aligns every setTimeout to DOMTimer::hiddenPageAlignmentInterval
// (1 s). `--awake` turns that throttling off (WKPreferences hiddenPageDOMTimerThrottlingEnabled and
// pageVisibilityBasedProcessSuppressionEnabled), standing for an app that is not idle.
//
//   swiftc -O scripts/measure/hot-swap-webkit-stages.swift -o /tmp/hsw && \
//   /tmp/hsw --server http://127.0.0.1:4291/ --webviews webviews [--runs 10] [--awake] [--surface pane|settings]
//
// Stages (epoch ms; the page's clock is performance.timeOrigin + now(), the same wall clock):
//   save->received   the dev server's watcher, hot update and its socket message reach the page
//   received->fetched the changed module's request through the scheme handler (start of the update to its end)
//   fetched->dom     the module evaluated and React Fast Refresh committed (its debounce timer is here)
//   save->dom        the sum; rendering after it is not timed (a hidden page draws nothing)
// Prints a table and one `HOT_SWAP_WEBKIT {json}` line.
import AppKit
import Foundation
import WebKit

let args = CommandLine.arguments
func opt(_ name: String, _ fallback: String) -> String {
    if let i = args.firstIndex(of: "--\(name)"), i + 1 < args.count { return args[i + 1] }
    return fallback
}
let server = URL(string: opt("server", "http://127.0.0.1:4291/"))!
let webviews = URL(fileURLWithPath: opt("webviews", "webviews"))
let runs = Int(opt("runs", "10"))!
let awake = args.contains("--awake")
let surface = opt("surface", "pane")
let file = webviews.appending(path: surface == "pane" ? "src/agent-session/acpmux/ComposerFoot.tsx" : "src/pages/settings/components/SettingsApp.tsx")
let anchor = #"className="acpmux-composer-bar acpmux-composer-foot""#
let original = try! String(contentsOf: file, encoding: .utf8)
signal(SIGINT) { _ in try? original.write(to: file, atomically: false, encoding: .utf8); exit(130) }
signal(SIGTERM) { _ in try? original.write(to: file, atomically: false, encoding: .utf8); exit(143) }
func epochMs() -> Double { Date().timeIntervalSince1970 * 1000 }
func edit(_ n: Int) -> String {
    if surface == "pane" { return original.replacingOccurrences(of: anchor, with: #"data-hot-swap-stage="\#(n)" "# + anchor) }
    guard let r = original.range(of: #"return \(\s*<\w+"#, options: .regularExpression) else { fatalError("no JSX return") }
    return original.replacingCharacters(in: r, with: String(original[r]) + #" data-hot-swap-stage="\#(n)""#)
}

/// The app's dev-server path: every request under the scheme is one uncached GET of the same path
/// on the server (the document is /agent-pane/index.html), answered after a main-actor hop.
final class DevSchemeHandler: NSObject, WKURLSchemeHandler {
    var active = Set<ObjectIdentifier>()
    var fetched: [String: (Double, Double)] = [:]
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let url = task.request.url!
        var base = server.absoluteString
        if base.hasSuffix("/") { base.removeLast() }
        let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let path = parts.percentEncodedPath
        let remote: URL
        if surface == "pane" {
            remote = URL(string: path == "/" || path.isEmpty || path == "/index.html" ? base + "/agent-pane/index.html"
                : base + path + (parts.percentEncodedQuery.map { "?" + $0 } ?? ""))!
        } else {
            remote = URL(string: path == "/" || path.isEmpty ? base + "/settings/" : base + path + (parts.percentEncodedQuery.map { "?" + $0 } ?? ""))!
        }
        let id = ObjectIdentifier(task)
        active.insert(id)
        let started = epochMs()
        Task { @MainActor in
            let request = URLRequest(url: remote, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            let result = try? await URLSession.shared.data(for: request)
            guard self.active.remove(id) != nil else { return }
            guard let (body, response) = result, let http = response as? HTTPURLResponse else {
                task.didFailWithError(URLError(.cannotConnectToHost)); return
            }
            if path.contains("t=") || (parts.percentEncodedQuery ?? "").contains("t=") { self.fetched[path] = (started, epochMs()) }
            let type = http.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
            let reply = HTTPURLResponse(url: url, statusCode: http.statusCode, httpVersion: "HTTP/1.1",
                                        headerFields: ["Content-Type": type, "Cache-Control": "no-store"])!
            task.didReceive(reply)
            task.didReceive(body)
            task.didFinish()
        }
    }
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) { active.remove(ObjectIdentifier(task)) }
}

final class Marks: NSObject, WKScriptMessageHandler {
    var values: [String: Double] = [:]
    var waiter: CheckedContinuation<Void, Never>?
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let name = body["name"] as? String, let at = body["at"] as? Double else { return }
        if name == "error" { FileHandle.standardError.write(("page error: \(body["text"] ?? "")\n").data(using: .utf8)!); return }
        values[name] = values[name] ?? at
        if name == "dom" { waiter?.resume(); waiter = nil }
    }
}

let probeScript = """
(() => {
  const at = () => performance.timeOrigin + performance.now();
  const post = (name) => window.webkit.messageHandlers.stage.postMessage({ name, at: at() });
  // Page errors go to stderr (a page that failed to start never shows the edit).
  {
    window.addEventListener("error", (e) => window.webkit.messageHandlers.stage.postMessage({ name: "error", at: at(), text: String(e.message) }));
    window.addEventListener("unhandledrejection", (e) => window.webkit.messageHandlers.stage.postMessage({ name: "error", at: at(), text: String(e.reason && (e.reason.stack || e.reason)) }));
    const warn = console.error.bind(console);
    console.error = (...a) => { window.webkit.messageHandlers.stage.postMessage({ name: "error", at: at(), text: a.map(String).join(" ") }); warn(...a); };
  }
  const Native = window.WebSocket;
  window.WebSocket = class extends Native {
    constructor(url, protocols) {
      super(url, protocols);
      this.addEventListener("message", (e) => {
        if (typeof e.data === "string" && e.data.includes('"type":"update"')) post("received");
      });
    }
  };
  window.__arm = (selector) => {
    const check = () => { if (document.querySelector(selector)) { observer.disconnect(); post("dom"); } };
    const observer = new MutationObserver(check);
    observer.observe(document, { subtree: true, childList: true, attributes: true });
    check();
  };
})();
"""

@MainActor func main() async {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let config = WKWebViewConfiguration()
    let handler = DevSchemeHandler()
    config.setURLSchemeHandler(handler, forURLScheme: "cmux-agent")
    let marks = Marks()
    config.userContentController.add(marks, name: "stage")
    config.userContentController.addUserScript(WKUserScript(source: probeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    if awake {
        for key in ["pageVisibilityBasedProcessSuppressionEnabled", "hiddenPageDOMTimerThrottlingEnabled"]
        where config.preferences.responds(to: NSSelectorFromString("_set\(key.prefix(1).uppercased())\(key.dropFirst()):")) {
            config.preferences.setValue(false, forKey: key)
        }
    }
    let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 980, height: 820), configuration: config)
    webView.load(URLRequest(url: URL(string: surface == "pane" ? "cmux-agent://pane/?mock" : "cmux-agent://pane/")!))
    let readySelector = surface == "pane" ? ".acpmux-composer-foot" : "#root *"
    for _ in 0..<600 {
        try? await Task.sleep(for: .milliseconds(100))
        if (try? await webView.evaluateJavaScript("!!document.querySelector('\(readySelector)')")) as? Bool == true { break }
    }
    try? await Task.sleep(for: .seconds(2))
    var rows: [[String: Double]] = []
    for n in 1...runs {
        marks.values = [:]
        handler.fetched = [:]
        _ = try? await webView.evaluateJavaScript("window.__arm('[data-hot-swap-stage=\"\(n)\"]')")
        let save = epochMs()
        try! edit(n).write(to: file, atomically: false, encoding: .utf8)
        let timeout = Task { try? await Task.sleep(for: .seconds(15)); marks.waiter?.resume(); marks.waiter = nil }
        await withCheckedContinuation { marks.waiter = $0 }
        timeout.cancel()
        var m = marks.values
        m["save"] = save
        if let f = handler.fetched.values.min(by: { $0.0 < $1.0 }) { m["fetchStart"] = f.0; m["fetchEnd"] = handler.fetched.values.map(\.1).max()! }
        func d(_ a: String, _ b: String) -> Double { (m[a] != nil && m[b] != nil) ? (m[b]! - m[a]!).rounded() : -1 }
        rows.append(["save->received": d("save", "received"), "received->fetched": d("received", "fetchEnd"),
                     "fetched->dom": d("fetchEnd", "dom"), "save->dom": d("save", "dom")])
        try! original.write(to: file, atomically: false, encoding: .utf8)
        try? await Task.sleep(for: .milliseconds(1200))
    }
    func pct(_ key: String, _ q: Double) -> Double {
        let v = rows.compactMap { $0[key] }.filter { $0 >= 0 }.sorted()
        guard !v.isEmpty else { return -1 }
        return v[max(1, Int((Double(v.count) * q / 100).rounded(.up))) - 1]
    }
    let keys = ["save->received", "received->fetched", "fetched->dom", "save->dom"]
    print("webkit \(surface) \(awake ? "awake" : "idle (hidden-page throttling)") n=\(rows.count)")
    for k in keys { print("  \(k.padding(toLength: 20, withPad: " ", startingAt: 0)) p50 \(Int(pct(k, 50)))  p95 \(Int(pct(k, 95)))") }
    let summary = Dictionary(uniqueKeysWithValues: keys.map { ($0, ["p50": pct($0, 50), "p95": pct($0, 95)]) })
    let json = try! JSONSerialization.data(withJSONObject: ["surface": surface, "awake": awake, "rows": rows, "summary": summary], options: [.sortedKeys])
    print("HOT_SWAP_WEBKIT " + String(decoding: json, as: UTF8.self))
    exit(0)
}
Task { @MainActor in await main() }
NSApplication.shared.run()
