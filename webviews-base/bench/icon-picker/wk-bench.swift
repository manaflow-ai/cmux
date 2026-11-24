// Icon picker latency bench in a real WKWebView (GUI host only: cmux-lawrence-2, never the laptop).
//   swiftc -O -parse-as-library wk-bench.swift -o /tmp/wk-bench && /tmp/wk-bench <index.html> <page-bench.js>
//   /tmp/wk-bench --dump-catalog <out.json>      # the system catalog as the host sends it (no window)
// Prints one JSON object:
//   blankThenLoadMs: a blank host (WebContent running, idle 3 s) navigated to the page -> first frame
//   coldMs:       new WKWebView + load the bundled page -> page reports its first committed frame
//   warmRevealMs: page loaded in a hidden window, the catalog sent once, then shown + a session
//                 opened -> next rAF (the warm picker's second open, IconPickerService)
//   page:         page-bench.js results (open, keystroke, scroll fps, jumps; milliseconds)
// The page loads from a cmuxbench:// scheme handler that serves index.html and draws the SF Symbol
// images like the app's host (IconPickerSymbols): __symbol/<name>.png (black template) and
// __symbol/{hierarchical,multicolor}/<name>.png, so scrolling pays for real image requests.
// The window is a small accessory panel; the app never activates and never takes focus.
import AppKit
import WebKit

let resources = URL(fileURLWithPath: "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources")

/// The system SF Symbol catalog in the session's shape (IconPickerSymbolCatalog in the app):
/// names in symbol_order, keywords and categories with a dotted-prefix fallback.
func systemCatalog() -> [String: Any] {
    func plist(_ name: String) -> Any? {
        guard let data = try? Data(contentsOf: resources.appendingPathComponent("\(name).plist")) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil)
    }
    func lookup<V>(_ name: String, _ table: [String: V]) -> V? {
        var parts = name.split(separator: ".")
        while !parts.isEmpty {
            if let value = table[parts.joined(separator: ".")] { return value }
            parts.removeLast()
        }
        return nil
    }
    let available = Set(((plist("name_availability") as? [String: Any])?["symbols"] as? [String: Any])?.keys.map { $0 } ?? [])
    var names: [String] = []
    var placed = Set<String>()
    for name in plist("symbol_order") as? [String] ?? [] where available.contains(name) {
        if placed.insert(name).inserted { names.append(name) }
    }
    names += available.subtracting(placed).sorted()
    let search = plist("symbol_search") as? [String: [String]] ?? [:]
    let memberships = plist("symbol_categories") as? [String: [String]] ?? [:]
    var members: [String: [Int]] = [:]
    for (index, name) in names.enumerated() {
        for key in lookup(name, memberships) ?? [] { members[key, default: []].append(index) }
    }
    let categories: [[String: Any]] = (plist("categories") as? [[String: Any]] ?? []).compactMap { entry in
        guard let key = entry["key"] as? String, let icon = entry["icon"] as? String else { return nil }
        return ["key": key, "icon": icon, "members": members[key] ?? []]
    }
    return [
        "symbols": names,
        "symbolKeywords": names.map { lookup($0, search)?.joined(separator: " ") ?? "" },
        "symbolCategories": categories,
    ]
}

/// The app host's drawing (IconPickerSymbols.png): 48 pt, 60 px square, black template or a mode.
@MainActor
func symbolPNG(_ name: String, mode: String) -> Data? {
    var config = NSImage.SymbolConfiguration(pointSize: 48, weight: .regular)
    if mode == "hierarchical" { config = config.applying(NSImage.SymbolConfiguration(hierarchicalColor: .black)) }
    if mode == "multicolor" { config = config.applying(.preferringMulticolor()) }
    guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config),
          let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 60, pixelsHigh: 60, bitsPerSample: 8, samplesPerPixel: 4,
                                        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let size = symbol.size
    let scale = min(60 / size.width, 60 / size.height)
    symbol.draw(in: NSRect(x: (60 - size.width * scale) / 2, y: (60 - size.height * scale) / 2,
                           width: size.width * scale, height: size.height * scale))
    return bitmap.representation(using: .png, properties: [:])
}

/// Serves cmuxbench://bench/icon-picker/index.html and its __symbol images.
@MainActor
final class BenchScheme: NSObject, WKURLSchemeHandler {
    let html: Data
    private(set) var symbolRequests = 0

    init(html: Data) {
        self.html = html
    }

    nonisolated func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        MainActor.assumeIsolated {
            guard let url = task.request.url else { return }
            let parts = url.path.split(separator: "/").map(String.init)
            var body = html
            var type = "text/html"
            if let at = parts.firstIndex(of: "__symbol") {
                let rest = Array(parts[(at + 1)...])
                let file = rest.last ?? ""
                let name = String(file.dropLast(4)).removingPercentEncoding ?? ""
                symbolRequests += 1
                body = symbolPNG(name, mode: rest.count == 2 ? rest[0] : "monochrome") ?? Data()
                type = "image/png"
            }
            task.didReceive(URLResponse(url: url, mimeType: type, expectedContentLength: body.count, textEncodingName: nil))
            task.didReceive(body)
            task.didFinish()
        }
    }

    nonisolated func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

@MainActor
final class Bench: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    let scheme: BenchScheme
    let script: String
    let catalog: [String: Any]
    var loaded: CheckedContinuation<Void, Never>?
    var ready: CheckedContinuation<Double, Never>?
    static let pageURL = URL(string: "cmuxbench://bench/icon-picker/index.html")!

    init(html: Data, script: String, catalog: [String: Any]) {
        scheme = BenchScheme(html: html)
        self.script = script
        self.catalog = catalog
    }

    func makeWindow() -> (NSWindow, WKWebView) {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(scheme, forURLScheme: "cmuxbench")
        let marker = WKUserScript(
            source: "requestAnimationFrame(() => requestAnimationFrame(() => webkit.messageHandlers.bench.postMessage(performance.now())))",
            injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        config.userContentController.addUserScript(marker)
        config.userContentController.add(self, name: "bench")
        // The app's picker size (IconPickerService.size).
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 420, height: 460), configuration: config)
        web.navigationDelegate = self
        let window = NSPanel(contentRect: NSRect(x: 40, y: 40, width: 420, height: 460),
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
            web.load(URLRequest(url: Self.pageURL))
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

    func catalogJSON() -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: catalog) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    /// The warm picker: loaded hidden, primed with the catalog (the provider's first event), then
    /// each open is order front + a session without the catalog -> next rAF.
    func warmReveal(opens: Int) async throws -> ([Double], WKWebView) {
        let (window, web) = makeWindow()
        window.orderFrontRegardless()
        await load(web)
        _ = try await web.callAsyncJavaScript("cmuxIconPicker.open(Object.assign({id: ''}, \(catalogJSON()))); return 0",
                                              contentWorld: .page)
        window.orderOut(nil)
        var times: [Double] = []
        for open in 0..<opens {
            try await Task.sleep(for: .seconds(1))
            let start = CACurrentMediaTime()
            window.orderFrontRegardless()
            _ = try await web.callAsyncJavaScript(
                "cmuxIconPicker.open({id: 'reveal-\(open)', symbolStyle: 'bench'}); await new Promise(r => requestAnimationFrame(r)); return 0",
                contentWorld: .page)
            times.append((CACurrentMediaTime() - start) * 1000)
            if open < opens - 1 { window.orderOut(nil) }
        }
        return (times, web)
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
        window.orderOut(nil)
        return ms
    }

    func run() async throws -> String {
        var blank: [Double] = []
        for _ in 0..<5 { blank.append(try await blankThenLoad()) }
        var cold: [Double] = []
        for _ in 0..<5 { cold.append(await self.cold()) }
        let (warm, web) = try await warmReveal(opens: 10)
        let before = scheme.symbolRequests
        let body = "const CATALOG = \(catalogJSON()); const MAX_EMOJI = 180;\n" + script
        let page = try await web.callAsyncJavaScript(body, contentWorld: .page) as? String ?? "null"
        func fmt(_ values: [Double]) -> String { "[" + values.map { String(format: "%.1f", $0) }.joined(separator: ",") + "]" }
        let symbols = (catalog["symbols"] as? [String])?.count ?? 0
        return "{\"blankThenLoadMs\":\(fmt(blank)),\"coldMs\":\(fmt(cold)),\"warmRevealMs\":\(fmt(warm)),"
            + "\"symbols\":\(symbols),\"symbolImageRequests\":\(scheme.symbolRequests - before),\"page\":\(page)}"
    }
}

@main
struct Main {
    static func main() {
        let args = CommandLine.arguments
        if args.count == 3, args[1] == "--dump-catalog" {
            guard let data = try? JSONSerialization.data(withJSONObject: systemCatalog()),
                  (try? data.write(to: URL(fileURLWithPath: args[2]))) != nil else { exit(1) }
            exit(0)
        }
        guard args.count == 3, let html = FileManager.default.contents(atPath: args[1]),
              let script = try? String(contentsOfFile: args[2], encoding: .utf8) else {
            FileHandle.standardError.write("usage: wk-bench <index.html> <page-bench.js> | wk-bench --dump-catalog <out.json>\n".data(using: .utf8)!)
            exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        MainActor.assumeIsolated {
            let bench = Bench(html: html, script: script, catalog: systemCatalog())
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
