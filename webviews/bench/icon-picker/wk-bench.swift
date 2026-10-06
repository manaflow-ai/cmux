// Icon picker latency bench in a real WKWebView (GUI host only: cmux-lawrence-2, never the laptop).
//   swiftc -O -parse-as-library wk-bench.swift -o /tmp/wk-bench && /tmp/wk-bench <index.html> <page-bench.js>
// Prints one JSON object:
//   coldMs:       new WKWebView + load the bundled page -> page reports its first committed frame
//   warmRevealMs: page loaded in a hidden window for 3 s, then shown + a session opened -> next rAF
//   page:         page-bench.js results (open, keystroke, scroll; milliseconds)
// The window is a small accessory panel; the app never activates and never takes focus.
import AppKit
import WebKit

@MainActor
final class Bench: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let html: String
    let script: String
    let symbols: [String]
    var loaded: CheckedContinuation<Void, Never>?
    var ready: CheckedContinuation<Double, Never>?

    init(html: String, script: String, symbols: [String]) {
        self.html = html
        self.script = script
        self.symbols = symbols
    }

    func makeWindow() -> (NSWindow, WKWebView) {
        let config = WKWebViewConfiguration()
        let marker = WKUserScript(
            source: "requestAnimationFrame(() => requestAnimationFrame(() => webkit.messageHandlers.bench.postMessage(performance.now())))",
            injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        config.userContentController.addUserScript(marker)
        config.userContentController.add(self, name: "bench")
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 352, height: 420), configuration: config)
        web.navigationDelegate = self
        let window = NSPanel(contentRect: NSRect(x: 40, y: 40, width: 352, height: 420),
                             styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        window.contentView = web
        return (window, web)
    }

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            ready?.resume(returning: 0)
            ready = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            loaded?.resume()
            loaded = nil
        }
    }

    func load(_ web: WKWebView) async {
        _ = await withCheckedContinuation { (continuation: CheckedContinuation<Double, Never>) in
            ready = continuation
            web.loadHTMLString(html, baseURL: URL(string: "https://bench.invalid/icon-picker/"))
        }
    }

    func cold() async -> Double {
        let start = CACurrentMediaTime()
        let (window, web) = makeWindow()
        window.orderFrontRegardless()
        await load(web)
        let ms = (CACurrentMediaTime() - start) * 1000
        window.orderOut(nil)
        return ms
    }

    func symbolsJSON() -> String {
        String(data: try! JSONSerialization.data(withJSONObject: symbols), encoding: .utf8)!
    }

    func warmReveal() async throws -> (Double, WKWebView, NSWindow) {
        let (window, web) = makeWindow()
        window.orderFrontRegardless()
        await load(web)
        window.orderOut(nil)
        try await Task.sleep(for: .seconds(3))
        let start = CACurrentMediaTime()
        window.orderFrontRegardless()
        _ = try await web.callAsyncJavaScript(
            "cmuxIconPicker.open({id: 'reveal', symbols: \(symbolsJSON())}); await new Promise(r => requestAnimationFrame(r)); return 0",
            contentWorld: .page)
        return ((CACurrentMediaTime() - start) * 1000, web, window)
    }

    /// A blank page host (WebContent process running, about:blank loaded, idle 3 s), then
    /// navigated to the picker page: the cost when one shared blank host is claimed.
    func blankThenLoad() async throws -> Double {
        let (window, web) = makeWindow()
        window.orderFrontRegardless()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            loaded = continuation
            web.loadHTMLString("<!doctype html><html><body></body></html>", baseURL: URL(string: "https://bench.invalid/blank/"))
        }
        try await Task.sleep(for: .seconds(3))
        let start = CACurrentMediaTime()
        await load(web)
        let ms = (CACurrentMediaTime() - start) * 1000
        let marks = try await web.callAsyncJavaScript(
            "return JSON.stringify(Object.fromEntries(performance.getEntriesByType('mark').map(m => [m.name, m.startTime])).concat ? 0 : Object.fromEntries(performance.getEntriesByType('mark').map(m => [m.name, Math.round(m.startTime)])))",
            contentWorld: .page) as? String ?? ""
        FileHandle.standardError.write("blank->load marks \(marks) total \(String(format: "%.1f", ms))\n".data(using: .utf8)!)
        window.orderOut(nil)
        return ms
    }

    func run() async throws -> String {
        var blank: [Double] = []
        for _ in 0..<5 { blank.append(try await blankThenLoad()) }
        var cold: [Double] = []
        for _ in 0..<5 { cold.append(await self.cold()) }
        var warm: [Double] = []
        var last: (WKWebView, NSWindow)?
        for _ in 0..<5 {
            let (ms, web, window) = try await warmReveal()
            warm.append(ms)
            last?.1.orderOut(nil)
            last = (web, window)
        }
        let (web, _) = last!
        let body = "const SYMBOLS = \(symbolsJSON()); const MAX_EMOJI = 170;\n" + script
        let page = try await web.callAsyncJavaScript(body, contentWorld: .page) as? String ?? "null"
        func fmt(_ values: [Double]) -> String { "[" + values.map { String(format: "%.1f", $0) }.joined(separator: ",") + "]" }
        return "{\"blankThenLoadMs\":\(fmt(blank)),\"coldMs\":\(fmt(cold)),\"warmRevealMs\":\(fmt(warm)),\"symbols\":\(symbols.count),\"page\":\(page)}"
    }
}

/// SF Symbol names the OS draws (the same source the app's host uses).
func systemSymbolNames() -> [String] {
    let path = "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/name_availability.plist"
    guard let plist = NSDictionary(contentsOfFile: path), let symbols = plist["symbols"] as? [String: Any] else { return [] }
    return symbols.keys.sorted()
}

@main
struct Main {
    static func main() {
        let args = CommandLine.arguments
        guard args.count == 3, let html = try? String(contentsOfFile: args[1], encoding: .utf8),
              let script = try? String(contentsOfFile: args[2], encoding: .utf8) else {
            FileHandle.standardError.write("usage: wk-bench <index.html> <page-bench.js>\n".data(using: .utf8)!)
            exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        MainActor.assumeIsolated {
            let bench = Bench(html: html, script: script, symbols: systemSymbolNames())
            Task { @MainActor in
                do {
                    print(try await bench.run())
                    exit(0)
                } catch {
                    FileHandle.standardError.write("bench failed: \(error)\n".data(using: .utf8)!)
                    exit(1)
                }
            }
        }
        app.run()
    }
}
