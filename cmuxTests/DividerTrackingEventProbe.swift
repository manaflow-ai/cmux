import AppKit
import ObjectiveC.runtime
import Testing

/// Supplies synthetic pointer context, observes native tracking, and bounds its event fetches.
/// Install only around synchronous dispatch under AppContextSerialGate.
@MainActor
final class DividerTrackingEventProbe {
    private typealias NextEvent = @convention(c) (
        AnyObject, Selector, UInt64, NSDate?, NSString, Bool
    ) -> NSEvent?
    private typealias MouseDown = @convention(c) (NSSplitView, Selector, NSEvent) -> Void

    private(set) var nativeTrackingCount = 0
    private(set) var firstNativeQueuedEvent: NSEvent?
    private(set) var timedOut = false
    private var currentPointerEvent: NSEvent?

    private func noteDequeuedPointerEvent(_ event: NSEvent) {
        if event.windowNumber == currentPointerEvent?.windowNumber,
           [.leftMouseDown, .leftMouseDragged, .leftMouseUp].contains(event.type) {
            currentPointerEvent = event
        }
    }

    func dispatch(_ down: NSEvent, release: NSEvent, splitView: NSSplitView, window: NSWindow) throws {
        let deadline = Date(timeIntervalSinceNow: 1)
        let nextSelector = #selector(NSWindow.nextEvent(matching:until:inMode:dequeue:))
        var restorations: [() -> Void] = []
        defer { for restore in restorations.reversed() { restore() } }

        // window.sendEvent does not establish NSApplication's current event,
        // and NSEvent.mouseEvent does not press a physical mouse button. Supply
        // the context that the real event loop and device provide, without
        // changing hit testing, mouseDown, or NSSplitView's native tracking.
        currentPointerEvent = down
        let currentEventMethod = try #require(class_getInstanceMethod(
            NSApplication.self, #selector(getter: NSApplication.currentEvent)
        ))
        let currentEventIMP = method_getImplementation(currentEventMethod)
        let currentEventBlock: @convention(block) (AnyObject) -> NSEvent? = { _ in
            MainActor.assumeIsolated { self.currentPointerEvent }
        }
        let currentEventReplacement = imp_implementationWithBlock(currentEventBlock)
        method_setImplementation(currentEventMethod, currentEventReplacement)
        restorations.append {
            method_setImplementation(currentEventMethod, currentEventIMP)
            imp_removeBlock(currentEventReplacement)
        }

        let buttonsMethod = try #require(class_getClassMethod(
            NSEvent.self, #selector(getter: NSEvent.pressedMouseButtons)
        ))
        let buttonsIMP = method_getImplementation(buttonsMethod)
        let buttonsBlock: @convention(block) (AnyObject) -> UInt = { _ in
            MainActor.assumeIsolated { self.currentPointerEvent?.type == .leftMouseUp ? 0 : 1 }
        }
        let buttonsReplacement = imp_implementationWithBlock(buttonsBlock)
        method_setImplementation(buttonsMethod, buttonsReplacement)
        restorations.append {
            method_setImplementation(buttonsMethod, buttonsIMP)
            imp_removeBlock(buttonsReplacement)
        }

        // Both entrypoints are bounded: Bonsplit asks the window, while AppKit
        // may ask NSApplication directly inside native divider tracking.
        for owner in [NSWindow.self, NSApplication.self] as [AnyClass] {
            let method = try #require(class_getInstanceMethod(owner, nextSelector))
            let originalIMP = method_getImplementation(method)
            let original = unsafeBitCast(originalIMP, to: NextEvent.self)
            let block: @convention(block) (
                AnyObject, UInt64, NSDate?, NSString, Bool
            ) -> NSEvent? = { receiver, mask, until, mode, dequeue in
                var result: NSEvent?
                MainActor.assumeIsolated {
                    let tracksRelease = NSEvent.EventTypeMask(rawValue: mask).contains(.leftMouseUp)
                    let bounded = tracksRelease ? min(until as Date? ?? deadline, deadline) : until as Date?
                    result = original(receiver, nextSelector, mask, bounded as NSDate?, mode, dequeue)
                    if result == nil, tracksRelease, Date() >= deadline {
                        self.timedOut = true
                        // Unwind native tracking on a regression instead of
                        // leaving a blocked main thread. This always fails below.
                        result = release
                    }
                    if dequeue, let result { self.noteDequeuedPointerEvent(result) }
                }
                return result
            }
            let replacement = imp_implementationWithBlock(block)
            method_setImplementation(method, replacement)
            restorations.append {
                method_setImplementation(method, originalIMP)
                imp_removeBlock(replacement)
            }
        }

        let mouseSelector = #selector(NSSplitView.mouseDown(with:))
        let mouseMethod = try #require(class_getInstanceMethod(NSSplitView.self, mouseSelector))
        let mouseIMP = method_getImplementation(mouseMethod)
        let nativeMouseDown = unsafeBitCast(mouseIMP, to: MouseDown.self)
        let mouseBlock: @convention(block) (NSSplitView, NSEvent) -> Void = { view, event in
            MainActor.assumeIsolated {
                if view === splitView {
                    self.nativeTrackingCount += 1
                    self.firstNativeQueuedEvent = NSApp.nextEvent(
                        matching: [.leftMouseDragged, .leftMouseUp], until: .now,
                        inMode: .eventTracking, dequeue: false
                    )
                }
                nativeMouseDown(view, mouseSelector, event)
            }
        }
        let mouseReplacement = imp_implementationWithBlock(mouseBlock)
        method_setImplementation(mouseMethod, mouseReplacement)
        restorations.append {
            method_setImplementation(mouseMethod, mouseIMP)
            imp_removeBlock(mouseReplacement)
        }

        // Include the terminal/browser portal siblings above the content view.
        // NSView.hitTest takes SUPER view coordinates, even for a flipped
        // NSHostingView. A content-local point mirrors Y and hits a pane.
        let content = try #require(window.contentView)
        let root = try #require(content.superview)
        let reference = root.superview ?? root
        let hit = root.hitTest(reference.convert(down.locationInWindow, from: nil))
        try #require(hit === splitView, "The divider center must route through the window tree to the managed split")
        window.sendEvent(down)
        #expect(!timedOut, "Divider tracking exceeded its one-second deadline")
    }
}
