import AppKit
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression coverage for the Sentry crash family "Attempted to read an unowned reference"
/// in `KeyViewProxy.nextResponder.getter` (CMUXTERM-MACOS-3Z73 and siblings). SwiftUI's
/// `KeyViewProxy` returns its `FocusBridge`'s unowned host as `nextResponder`, so walking a
/// proxy that outlived its `NSHostingView` aborts the app.
@MainActor
@Suite(.serialized) struct SwiftUIKeyViewProxyResponderGuardTests {
    private struct FocusableContent: View {
        @FocusState private var focused: Bool

        var body: some View {
            VStack {
                Text("a").focusable().focused($focused)
                Text("b").focusable()
            }
            .onAppear { focused = true }
        }
    }

    private func isKeyViewProxy(_ view: NSView) -> Bool {
        String(cString: class_getName(type(of: view))) == "SwiftUI.KeyViewProxy"
    }

    private func spinRunLoop(_ iterations: Int = 10) {
        for _ in 0..<iterations {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    /// Focuses a SwiftUI element, then frees its hosting view while something still holds the
    /// proxy, which is the state every crashing walker reached.
    private func makeProxyThatOutlivedItsHost() throws -> NSView {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        window.contentView = container

        var proxy: NSView?
        weak var weakHost: NSView?
        autoreleasepool {
            let host = NSHostingView(rootView: FocusableContent())
            host.frame = container.bounds
            container.addSubview(host)
            weakHost = host
            spinRunLoop()
            window.makeFirstResponder(host)
            spinRunLoop()
            window.selectNextKeyView(nil)
            spinRunLoop()
            proxy = window.firstResponder as? NSView
            host.removeFromSuperview()
        }
        spinRunLoop(20)

        let stale = try #require(proxy)
        try #require(isKeyViewProxy(stale))
        try #require(weakHost == nil)
        return stale
    }

    @Test func walkingAProxyThatOutlivedItsHostEndsTheChain() throws {
        AppDelegate.installWindowResponderSwizzlesForTesting()
        let proxy = try makeProxyThatOutlivedItsHost()

        #expect(proxy.superview == nil)
        #expect(proxy.nextResponder == nil)
    }

    @Test func attachedProxyStillForwardsToItsHost() throws {
        AppDelegate.installWindowResponderSwizzlesForTesting()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: FocusableContent())
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        window.contentView = host
        spinRunLoop()
        window.makeFirstResponder(host)
        spinRunLoop()
        window.selectNextKeyView(nil)
        spinRunLoop()

        let proxy = try #require(window.firstResponder as? NSView)
        try #require(isKeyViewProxy(proxy))
        #expect(proxy.nextResponder === host)
    }
}
