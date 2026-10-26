import AppKit
import CmuxProductAnalytics
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Pro badge initial layout", .serialized)
struct ProBadgeLayoutTests {
    @Test(arguments: ProBadgeStyle.allCases)
    func dismissRemainsAccessibleBeforePointerHover(style: ProBadgeStyle) throws {
        let store = ProBadgeStyleStore.shared
        let previousStyle = store.current
        let previousDismissed = store.isDismissed
        let defaults = UserDefaults.standard
        let savedStyle = defaults.object(forKey: "debug.proBadgeStyle")
        let savedDismissed = defaults.object(forKey: "proBadge.dismissed")
        defer {
            store.current = previousStyle
            store.isDismissed = previousDismissed
            if let savedStyle {
                defaults.set(savedStyle, forKey: "debug.proBadgeStyle")
            } else {
                defaults.removeObject(forKey: "debug.proBadgeStyle")
            }
            if let savedDismissed {
                defaults.set(savedDismissed, forKey: "proBadge.dismissed")
            } else {
                defaults.removeObject(forKey: "proBadge.dismissed")
            }
        }
        store.current = style
        store.isDismissed = false

        // Exercise the first layout without a pointer hover. In #7200 the
        // hidden xmark crashed CoreUI; removing its entire Button also removed
        // the dismiss action from the accessibility tree.
        let host = NSHostingView(rootView: ProBadgeView(
            actions: ProBadgeActions(analytics: .disabled, openPricing: { _ in })
        ).environment(\.accessibilityEnabled, true))
        host.frame = NSRect(x: 0, y: 0, width: 180, height: 44)
        let window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: 180, height: 44),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        _ = try #require(CloudTreeHeaderActionsTests.accessibilityElement("ProBadgeButton", in: host))
        let dismiss = try #require(
            CloudTreeHeaderActionsTests.accessibilityElement("ProBadgeDismissButton", in: host)
        )
        let role = CloudTreeHeaderActionsTests.accessibilityAttribute(
            .role, getter: "accessibilityRole", of: dismiss
        ) as? String
        #expect(role == NSAccessibility.Role.button.rawValue)
        let frame = try #require(
            CloudTreeHeaderActionsTests.accessibilityAttribute(
                .frame, getter: "accessibilityFrame", of: dismiss
            ) as? NSValue
        )
        #expect(frame.rectValue.width > 0)
        try #require(Self.press(dismiss))
        #expect(store.isDismissed)
    }

    private static func press(_ element: NSObject) -> Bool {
        let modern = NSSelectorFromString("accessibilityPerformPress")
        if element.responds(to: modern) {
            _ = element.perform(modern)
            return true
        }
        let legacy = NSSelectorFromString("accessibilityPerformAction:")
        guard element.responds(to: legacy) else { return false }
        _ = element.perform(legacy, with: NSAccessibility.Action.press.rawValue)
        return true
    }
}
