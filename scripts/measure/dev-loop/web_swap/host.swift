// The page host for web_swap on macOS: the agent pane in a WKWebView (WebKit, the app's engine) in a small
// non-activating panel, the way webviews/bench/icon-picker/wk-bench.swift hosts its page. Fleet Macs take no
// Playwright (scripts/measure/browser-use-perf.sh). It loads the URL and runs until measure.mjs stops it;
// everything it measures goes back over Vite's HMR socket from inside the page (page.ts).
//   swiftc -O -parse-as-library host.swift -o host && ./host http://127.0.0.1:PORT/agent-pane/?mock
import AppKit
import WebKit

@main
@MainActor
enum Host {
    static var window: NSPanel?

    static func main() {
        guard CommandLine.arguments.count > 1, let url = URL(string: CommandLine.arguments[1]) else {
            FileHandle.standardError.write(Data("usage: host URL\n".utf8))
            exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let config = WKWebViewConfiguration()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 980, height: 820), configuration: config)
        let panel = NSPanel(contentRect: NSRect(x: 40, y: 40, width: 980, height: 820),
                            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "dev-loop web_swap"
        panel.contentView = web
        // On screen (not key): a hidden or occluded page gets no animation frames.
        panel.orderFrontRegardless()
        window = panel
        web.load(URLRequest(url: url))
        signal(SIGTERM) { _ in exit(0) }
        app.run()
    }
}
