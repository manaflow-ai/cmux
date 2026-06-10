import AppKit
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

        SidebarScrollViewConfigurator.apply(to: scrollView)

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
        SidebarScrollViewConfigurator.apply(to: scrollView)

        scrollView.configPropertyWrites = 0
        SidebarScrollViewConfigurator.apply(to: scrollView)

        #expect(scrollView.configPropertyWrites == 0)
    }
}
