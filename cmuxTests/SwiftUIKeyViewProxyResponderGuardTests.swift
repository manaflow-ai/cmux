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

    /// Identifies the private proxy class so the fixture cannot silently test a different responder.
    private func isKeyViewProxy(_ view: NSView) -> Bool {
        String(cString: class_getName(type(of: view))) == "SwiftUI.KeyViewProxy"
    }

    /// Requests keyboard focus before waiting for SwiftUI's lazily created focus proxy.
    private func focusProxy(in window: NSWindow, host: NSView) async throws -> NSView {
        host.layoutSubtreeIfNeeded()
        // SwiftUI can create its proxy lazily when keyboard focus is requested.
        try #require(window.makeFirstResponder(host))
        window.selectNextKeyView(nil)
        let proxyFocused = await AppKitTestEventPump().waitUntil(timeout: .seconds(5)) {
            guard let responder = window.firstResponder as? NSView else { return false }
            return isKeyViewProxy(responder)
        }
        try #require(proxyFocused, "Keyboard focus should reach a SwiftUI focus proxy")
        return try #require(window.firstResponder as? NSView)
    }

    /// Focuses a SwiftUI element, then frees its hosting view while something still holds the
    /// proxy, which is the state every crashing walker reached.
    private func makeProxyThatOutlivedItsHost() async throws -> NSView {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer {
            window.contentView = nil
            window.close()
        }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        window.contentView = container

        var host: NSHostingView<FocusableContent>? = NSHostingView(rootView: FocusableContent())
        weak var weakHost = host
        autoreleasepool {
            host?.frame = container.bounds
            if let host { container.addSubview(host) }
        }
        let proxy = try await focusProxy(in: window, host: #require(host))
        autoreleasepool {
            host?.removeFromSuperview()
            host = nil
        }
        let hostReleased = await AppKitTestEventPump().waitUntil(timeout: .seconds(5)) {
            weakHost == nil
        }

        try #require(hostReleased, "The proxy must outlive its host to exercise the crash")
        return proxy
    }

    /// Exercises responder-chain access only after the proxy's unowned host has deallocated.
    @Test func walkingAProxyThatOutlivedItsHostEndsTheChain() async throws {
        AppDelegate.installWindowResponderSwizzlesForTesting()
        let proxy = try await makeProxyThatOutlivedItsHost()

        #expect(proxy.superview == nil)
        #expect(proxy.nextResponder == nil)
    }

    /// Verifies that the guard preserves responder forwarding while the hosting view is alive.
    @Test func attachedProxyStillForwardsToItsHost() async throws {
        AppDelegate.installWindowResponderSwizzlesForTesting()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer {
            window.contentView = nil
            window.close()
        }
        let host = NSHostingView(rootView: FocusableContent())
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        window.contentView = host
        let proxy = try await focusProxy(in: window, host: host)
        #expect(proxy.nextResponder === host)
    }
}
