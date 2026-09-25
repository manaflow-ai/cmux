import AppKit
import CmuxAppKitSupportUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Sidebar scroll view configurator")
struct SidebarScrollViewConfiguratorTests {
    /// Counts every setter invocation, including same-value writes — a
    /// same-value `scrollerStyle`/scroller write still re-tiles AppKit's
    /// overlay scrollers and can cancel an in-flight fade, which is the
    /// stuck-knob mechanism this guards against.
    private final class SetterCountingScrollView: NSScrollView {
        var configPropertyWrites = 0

        override var hasHorizontalScroller: Bool {
            get { super.hasHorizontalScroller }
            set {
                configPropertyWrites += 1
                super.hasHorizontalScroller = newValue
            }
        }

        override var hasVerticalScroller: Bool {
            get { super.hasVerticalScroller }
            set {
                configPropertyWrites += 1
                super.hasVerticalScroller = newValue
            }
        }

        override var autohidesScrollers: Bool {
            get { super.autohidesScrollers }
            set {
                configPropertyWrites += 1
                super.autohidesScrollers = newValue
            }
        }

        override var scrollerStyle: NSScroller.Style {
            get { super.scrollerStyle }
            set {
                configPropertyWrites += 1
                super.scrollerStyle = newValue
            }
        }
    }

    @Test func firstApplyEstablishesOverlayConfiguration() {
        let scrollView = SetterCountingScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))

        scrollView.applySidebarOverlayScrollerConfiguration()

        #expect(!scrollView.hasHorizontalScroller)
        #expect(scrollView.hasVerticalScroller)
        #expect(scrollView.autohidesScrollers)
        #expect(scrollView.scrollerStyle == .overlay)
    }

    @Test func reapplyToConfiguredScrollViewWritesNothing() {
        // The resolver re-applies on every SwiftUI update of the sidebar. A
        // re-apply must be a pure no-op: any property write (same-value
        // included) re-tiles the overlay scrollers and can cancel an
        // in-flight knob fade without rescheduling it, leaving the knob
        // permanently visible.
        let scrollView = SetterCountingScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        scrollView.applySidebarOverlayScrollerConfiguration()

        scrollView.configPropertyWrites = 0
        scrollView.applySidebarOverlayScrollerConfiguration()

        #expect(scrollView.configPropertyWrites == 0)
    }

    @Test func resolverReassertsOverlayConfigurationAfterPreferredScrollerStyleChange() async {
        // AppKit resets every NSScrollView's `scrollerStyle` to the new
        // system preference when the preferred scroller style changes — a
        // mouse is connected/disconnected, or System Settings → Appearance →
        // "Show scroll bars" changes. That clobbers the sidebar's forced
        // overlay configuration with a legacy, space-reserving scrollbar
        // until some unrelated SwiftUI re-render happens to re-run the
        // resolver (#3241, sidebar scope of the reopen). The resolver must
        // re-apply the configuration when the style-change notification
        // fires, without waiting for a re-render.
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
        let documentView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 800))
        scrollView.documentView = documentView

        let resolver = SidebarScrollViewResolverView(frame: .zero)
        var resolveCount = 0
        resolver.onResolve = { resolved in
            resolveCount += 1
            guard let resolved else { return }
            resolved.applySidebarOverlayScrollerConfiguration()
        }
        documentView.addSubview(resolver)
        await yieldUntil { resolveCount > 0 }
        #expect(scrollView.scrollerStyle == .overlay)
        let resolvesBeforeStyleChange = resolveCount

        // Simulate AppKit's per-scroll-view reset that accompanies the
        // preferred-style change, then post the notification AppKit sends.
        scrollView.scrollerStyle = .legacy
        NotificationCenter.default.post(
            name: NSScroller.preferredScrollerStyleDidChangeNotification,
            object: nil
        )
        await yieldUntil { resolveCount > resolvesBeforeStyleChange }

        #expect(
            resolveCount > resolvesBeforeStyleChange,
            "a preferred-scroller-style change must re-resolve so the sidebar config is re-applied"
        )
        #expect(
            scrollView.scrollerStyle == .overlay,
            "the sidebar must re-assert overlay scrollers after a scroller-style change"
        )
    }

    /// Yields the main actor until `condition` holds (bounded, no wall-clock
    /// sleeps), so the resolver's deferred main-actor hop — enqueued
    /// synchronously by the lifecycle callback or notification under test —
    /// has run before the test continues. The bound keeps a regression a
    /// clean assertion failure instead of a hang.
    private func yieldUntil(_ condition: () -> Bool) async {
        for _ in 0..<1000 {
            if condition() { return }
            await Task.yield()
        }
    }
}
