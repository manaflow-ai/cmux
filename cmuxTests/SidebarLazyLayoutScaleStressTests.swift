import AppKit
import OSLog
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension SidebarLazyLayoutScaleTests {
    /// Churn variable-height content, scroll the table, and drive synthetic
    /// table-owned hover, then assert the run emitted zero SwiftUI/AppKit
    /// runtime faults. The #8004 hover-bridge loop and the #6707 scroll
    /// livelock both announced themselves through these exact log signatures
    /// before pegging the main thread.
    @Test
    @MainActor
    func testTableChurnScrollAndHoverEmitNoRuntimeFaults() async throws {
        let harness = try await Self.mountSidebar(workspaceCount: Self.workspaceCount)
        defer { harness.tearDown() }

        await Self.drainMainRunLoop(for: harness.window)
        let rootView = try #require(harness.window.contentView)
        let table = try #require(Self.tableView(in: rootView))
        let logStore = try OSLogStore(scope: .currentProcessIdentifier)
        let start = logStore.position(date: Date())

        for index in 0..<40 {
            let workspace = harness.tabManager.tabs[index % 8]
            harness.tabManager.setCustomTitle(
                tabId: workspace.id,
                title: String(repeating: "variable title \(index) ", count: (index % 5) + 1)
            )
            harness.unread.apply(
                totalUnreadCount: index + 1,
                summaries: [
                    workspace.id: SidebarWorkspaceUnreadSummary(
                        unreadCount: index + 1,
                        latestNotificationText: String(repeating: "update ", count: (index % 4) + 1)
                    )
                ],
                unreadSurfaceKeys: [],
                focusedReadIndicatorByWorkspaceId: [:],
                manualUnreadWorkspaceIds: []
            )
            table.scrollRowToVisible((index * 17) % Self.workspaceCount)
            table.setPointerWindowLocation(table.convert(
                NSPoint(x: 20, y: table.visibleRect.midY),
                to: nil
            ))
            await Self.drainMainRunLoop(for: harness.window, iterations: 2)
        }
        table.setPointerWindowLocation(nil)
        await Self.drainMainRunLoop(for: harness.window, iterations: 30)

        let faultNeedles = ["Modifying state during view update",
                            "Publishing changes from within view updates",
                            "laid out reentrantly"]
        let faults = try logStore.getEntries(at: start).compactMap { entry -> String? in
            guard let log = entry as? OSLogEntryLog else { return nil }
            return faultNeedles.contains { log.composedMessage.localizedCaseInsensitiveContains($0) }
                ? log.composedMessage : nil
        }
        #expect(faults.isEmpty, "Sidebar churn emitted runtime faults: \(faults)")
    }

    /// Harness self-test: prove the drain loop + body counter actually detect
    /// a layout feedback loop. This fixture reproduces the historical
    /// GeometryReader → @State row-height shape (#6556) in divergent form; if
    /// the harness cannot flag THIS, the tests above are vacuous.
    @Test
    @MainActor
    func testHarnessDetectsGeometryFeedbackLoopCanary() async throws {
        _ = NSApplication.shared

        let counter = RowBodyCounter()
        let rows = 8
        let root = VStack(spacing: 2) {
            ForEach(0..<rows, id: \.self) { _ in
                DivergentGeometryFeedbackRowFixture(onBody: { counter.workspaceRowBodies += 1 })
            }
        }
        .frame(width: 200)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer {
            window.contentView = nil
            window.close()
        }
        window.contentView = NSHostingView(rootView: root)

        await Self.drainMainRunLoop(for: window, iterations: 40)

        #expect(
            counter.workspaceRowBodies > rows * 3,
            """
            The divergent GeometryReader → @State fixture only produced \
            \(counter.workspaceRowBodies) body evaluations for \(rows) rows; the harness \
            can no longer observe layout feedback loops, so the lazy-contract tests above \
            are not protecting anything. Fix the harness before trusting them.
            """
        )
    }
}

/// Reproduces the #6556 anti-pattern in deliberately divergent form: a
/// GeometryReader writes measured height back into `@State` that feeds the
/// row's own frame, so every layout pass invalidates the next. Test fixture
/// only — this shape is banned in real sidebar rows by
/// `scripts/check-sidebar-lazy-layout.py`.
private struct DivergentGeometryFeedbackRowFixture: View {
    let onBody: () -> Void
    @State private var rowHeight: CGFloat = 20

    var body: some View {
        let _ = { onBody() }()
        Color.gray
            .frame(height: rowHeight)
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { rowHeight = proxy.size.height + 1 }
                        .onChange(of: proxy.size.height) { _, newHeight in
                            rowHeight = newHeight + 1
                        }
                }
            }
    }
}
