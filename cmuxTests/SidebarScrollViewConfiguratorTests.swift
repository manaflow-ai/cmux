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
  /// Counts every native-scroller setter invocation so sidebar re-renders do
  /// not churn AppKit state after the overlay scroller is configured.
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

  @Test func firstApplyKeepsInteractiveVerticalOverlayScroller() {
    let scrollView = SetterCountingScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
    scrollView.hasHorizontalScroller = true

    scrollView.applySidebarScrollIndicatorConfiguration()

    #expect(!scrollView.hasHorizontalScroller)
    #expect(scrollView.hasVerticalScroller)
    #expect(!scrollView.autohidesScrollers)
    #expect(scrollView.scrollerStyle == .overlay)
    #expect(scrollView.verticalScroller != nil)
  }

  @Test func reapplyToConfiguredScrollViewWritesNothing() {
    // The resolver re-applies on every SwiftUI update of the sidebar. Once
    // the native scroller is configured, re-apply must not write its state.
    let scrollView = SetterCountingScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 400))
    scrollView.applySidebarScrollIndicatorConfiguration()

    scrollView.configPropertyWrites = 0
    scrollView.applySidebarScrollIndicatorConfiguration()

    #expect(scrollView.configPropertyWrites == 0)
  }
}
