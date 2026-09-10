import AppKit
import OSLog
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Reporter-shaped coverage for #9612 on macOS 15. A real cmux main window is
/// required: workspace selection updates both the AppKit sidebar and the
/// window-level terminal portal around SwiftUI's root hosting view.
@MainActor
@Suite("Sidebar workspace switching layout", .serialized)
struct SidebarWorkspaceSwitchLayoutFaultTests {
    @Test
    func switchingWorkspacesDoesNotReenterHostingViewLayout() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let appDelegate = try #require(AppDelegate.shared)
            let windowId = appDelegate.createMainWindow(shouldActivate: false)
            defer { appDelegate.discardMainWindowWithoutClosedHistory(windowId: windowId) }

            let window = try #require(appDelegate.mainWindow(for: windowId))
            let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
            while manager.tabs.count < 4 {
                _ = manager.addWorkspace(
                    select: false,
                    autoWelcomeIfNeeded: false,
                    autoRefreshMetadata: false
                )
            }

            window.makeKeyAndOrderFront(nil)
            await flushDeferredLayoutPasses(window: window)

            // Exclude startup/mount diagnostics. Only faults emitted after
            // the real workspace-switch workload starts belong to this test.
            let logStart = Date.now
            let targets = Array(manager.tabs.prefix(4))
            for iteration in 0..<12 {
                manager.selectTab(targets[iteration % targets.count])
                await flushDeferredLayoutPasses(window: window)
            }

            // A log sentinel is the completion signal for the unified-log
            // query: once it is readable, every earlier layout fault from the
            // workload is readable too. This avoids sleeping for log flushes.
            let sentinel = "cmux.issue-9612.layout-workload-complete.\(UUID().uuidString)"
            Logger(subsystem: "com.cmuxterm.tests", category: "layout").notice(
                "\(sentinel, privacy: .public)"
            )
            let observedSentinel = try await Self.waitForLogMessage(sentinel, since: logStart)
            try #require(observedSentinel, "Timed out waiting for the unified-log completion sentinel")

            let faults = try await Self.viewUpdateFaultMessages(since: logStart)
            #expect(
                faults.isEmpty,
                """
                Workspace switching emitted \(faults.count) SwiftUI/AppKit layout faults:\n\
                \(faults.joined(separator: "\n"))
                """
            )
        }
    }

    private func flushDeferredLayoutPasses(window: NSWindow) async {
        // Portal reconciliation intentionally takes up to two main-queue hops
        // and can enqueue one geometry-notification follow-up. Four FIFO
        // barriers execute those bounded stages without wall-clock pacing.
        for _ in 0..<4 {
            window.displayIfNeeded()
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    @concurrent
    private nonisolated static func waitForLogMessage(_ expected: String, since startDate: Date) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        let predicate = NSPredicate(
            format: "subsystem == %@ AND category == %@ AND composedMessage == %@",
            "com.cmuxterm.tests",
            "layout",
            expected
        )
        while clock.now < deadline {
            // OSLogStore instances are fixed snapshots, and log buffers can
            // become queryable out of timestamp order. Recreate the snapshot
            // without advancing past an unseen sentinel; the exact predicate
            // keeps each poll scoped to this test's single completion record.
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let entries = try store.getEntries(
                at: store.position(date: startDate),
                matching: predicate
            )
            if entries.contains(where: { entry in
                entry.date >= startDate &&
                    (entry as? OSLogEntryLog)?.composedMessage == expected
            }) {
                return true
            }
            try await clock.sleep(for: .milliseconds(25))
        }
        return false
    }

    @concurrent
    private nonisolated static func viewUpdateFaultMessages(since startDate: Date) async throws -> [String] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let entries = try store.getEntries(at: store.position(date: startDate))
        let faultFragments = [
            "Modifying state during view update",
            "Publishing changes from within view updates",
            "laid out reentrantly",
        ]
        return entries.compactMap { entry in
            guard entry.date >= startDate,
                  let message = (entry as? OSLogEntryLog)?.composedMessage,
                  faultFragments.contains(where: {
                      message.range(of: $0, options: .caseInsensitive) != nil
                  }) else {
                return nil
            }
            return message
        }
    }
}
