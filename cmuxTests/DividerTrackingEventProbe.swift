import AppKit
import ObjectiveC.runtime
import Testing

/// Observes native tracking without replacing it, and bounds its event fetches.
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

    func dispatch(_ down: NSEvent, release: NSEvent, splitView: NSSplitView, window: NSWindow) throws {
        let deadline = Date(timeIntervalSinceNow: 1)
        let nextSelector = #selector(NSWindow.nextEvent(matching:until:inMode:dequeue:))
        var restorations: [() -> Void] = []
        defer { for restore in restorations.reversed() { restore() } }

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

        window.sendEvent(down)
        #expect(!timedOut, "Divider tracking exceeded its one-second deadline")
    }
}
