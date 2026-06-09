import AppKit
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
func cmuxMakeWindowKeyForTesting(_ window: NSWindow) {
    let deadline = Date(timeIntervalSinceNow: 1.0)
    repeat {
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        window.makeMain()
        window.makeKey()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
    } while !window.isKeyWindow && Date() < deadline
}

@MainActor
func cmuxContainsWebViewForTesting(_ view: NSView?) -> Bool {
    guard let view else { return false }
    if view is WKWebView { return true }
    return view.subviews.contains { cmuxContainsWebViewForTesting($0) }
}

@MainActor
func cmuxWaitForBrowserBackgroundColorForTesting(_ panel: BrowserPanel, matching expected: NSColor) -> NSColor? {
    let deadline = Date(timeIntervalSinceNow: 1.0)
    var actual = panel.webView.underPageBackgroundColor?.usingColorSpace(.sRGB)
    while actual != nil, Date() < deadline {
        if abs((actual?.redComponent ?? 0) - expected.redComponent) < 0.005,
           abs((actual?.greenComponent ?? 0) - expected.greenComponent) < 0.005,
           abs((actual?.blueComponent ?? 0) - expected.blueComponent) < 0.005,
           abs((actual?.alphaComponent ?? 0) - expected.alphaComponent) < 0.005 {
            return actual
        }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        actual = panel.webView.underPageBackgroundColor?.usingColorSpace(.sRGB)
    }
    return actual
}
