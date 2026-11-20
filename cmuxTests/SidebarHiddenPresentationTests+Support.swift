import AppKit
import Combine
import Foundation
@testable import cmux_DEV

/// Run loop and toggle helpers for `SidebarHiddenPresentationTests`.
extension SidebarHiddenPresentationTests {
    /// Waits for a toggle to land. The slide commits `isVisible` when its
    /// Core Animation spring reports it stopped; the instant path already
    /// has. Then drains, so the landing's follow-up updates apply.
    func awaitToggleLanding(of state: SidebarState, in window: NSWindow, drains: Int = 20) async {
        let target = state.requestedVisibility
        if state.isVisible != target {
            for await visible in state.$isVisible.values where visible == target { break }
        }
        await drainMainRunLoop(for: window, iterations: drains)
    }

    /// Names the known frames on the stack, for telling which host or
    /// observation drove a sidebar body pass.
    static func passOrigin() -> String {
        let markers = [
            "SidebarDockedPaneHost", "SidebarPeekPanel", "NSHostingView", "updateNSView", "ContentView",
            "ObservableObject", "objectWillChange", "FileExplorer", "Binding", "layoutSubtree",
            "displayIfNeeded", "__CFRunLoopDoObservers", "__CFRunLoopRun", "_dispatch_main_queue",
        ]
        var seen: [String] = []
        for frame in Thread.callStackSymbols {
            for marker in markers where frame.contains(marker) && !seen.contains(marker) {
                seen.append(marker)
            }
        }
        return seen.joined(separator: ">")
    }

    func drainMainRunLoop(for window: NSWindow, iterations: Int = 20) async {
        for _ in 0..<iterations {
            window.contentView?.layoutSubtreeIfNeeded()
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
            await Task.yield()
        }
    }
}
