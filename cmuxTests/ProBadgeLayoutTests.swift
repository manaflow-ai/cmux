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
    func dismissRemainsAccessibleBeforePointerHover(style: ProBadgeStyle) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            try await Self.verifyBadge(style: style)
        }
    }

    private static func verifyBadge(style: ProBadgeStyle) async throws {
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

        // Window restoration can propose zero/narrow geometry before the
        // normal first frame. The actual button must retain its control size
        // rather than merely avoid a crash at the final window width.
        for width: CGFloat in [0, 1, 180] {
            host.setFrameSize(NSSize(width: width, height: 44))
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            #expect(host.bounds.width == width)
            #expect(host.fittingSize.height >= 22)
        }
        // Query accessibility once the host has usable bounds. An element
        // outside a zero-width host can legitimately be absent from AX.
        _ = try #require(CloudTreeHeaderActionsTests.accessibilityElement("ProBadgeButton", in: host))
        let dismiss = try #require(
            CloudTreeHeaderActionsTests.accessibilityElement("ProBadgeDismissButton", in: host)
        )
        let role = CloudTreeHeaderActionsTests.accessibilityAttribute(
            .role, getter: "accessibilityRole", of: dismiss
        ) as? String
        #expect(role == NSAccessibility.Role.button.rawValue)
        let frame = try Self.accessibilityFrame(of: dismiss)
        #expect(frame.width >= 14)
        #expect(frame.height >= 16)
        // Focus must reveal the real glyph without resizing its control. Crop
        // inside the button, excluding the surrounding keyboard focus ring.
        let slot = host.convert(window.convertFromScreen(frame), from: nil).insetBy(dx: 2, dy: 2)
        let unfocusedPixels = try #require(Self.pixels(in: slot, of: host))
        let focusSelector = NSSelectorFromString("setAccessibilityFocused:")
        try #require(dismiss.responds(to: focusSelector))
        typealias SetFocus = @convention(c) (AnyObject, Selector, ObjCBool) -> Void
        let setFocus = unsafeBitCast(dismiss.method(for: focusSelector), to: SetFocus.self)
        setFocus(dismiss, focusSelector, true)
        let glyphRendered = await AppKitTestEventPump().waitUntil(timeout: .seconds(5)) {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            guard let focusedPixels = Self.pixels(in: slot, of: host) else { return false }
            return focusedPixels != unfocusedPixels
        }
        #expect(glyphRendered, "Focusing the dismiss action must paint its glyph without pointer hover")
        #expect(try Self.accessibilityFrame(of: dismiss).size == frame.size)
        try #require(Self.press(dismiss))
        #expect(store.isDismissed)
    }

    private static func press(_ element: NSObject) -> Bool {
        let modern = NSSelectorFromString("accessibilityPerformPress")
        if element.responds(to: modern) {
            // NSObject.perform assumes an object return; this getter returns
            // BOOL. Call its IMP with the actual Objective-C signature.
            typealias Press = @convention(c) (AnyObject, Selector) -> ObjCBool
            let press = unsafeBitCast(element.method(for: modern), to: Press.self)
            return press(element, modern).boolValue
        }
        let legacy = NSSelectorFromString("accessibilityPerformAction:")
        guard element.responds(to: legacy) else { return false }
        _ = element.perform(legacy, with: NSAccessibility.Action.press.rawValue)
        return true
    }

    private static func accessibilityFrame(of element: NSObject) throws -> NSRect {
        let selector = NSSelectorFromString("accessibilityFrame")
        try #require(element.responds(to: selector))
        // NSRect is a struct return, not an object that NSObject.perform can
        // read. A typed IMP works on both arm64 and x86_64.
        typealias Frame = @convention(c) (AnyObject, Selector) -> NSRect
        let frame = unsafeBitCast(element.method(for: selector), to: Frame.self)
        return frame(element, selector)
    }

    private static func pixels(in rect: NSRect, of view: NSView) -> Data? {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
        view.cacheDisplay(in: rect, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }
}
