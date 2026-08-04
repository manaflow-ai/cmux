import AppKit
import OSLog
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

extension SidebarLazyLayoutScaleTests {
    private static func mouseMovedEvent(at pointInWindow: NSPoint, window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: pointInWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ))
    }

    fileprivate static func viewUpdateFaultMessages(since startDate: Date) throws -> [String] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let entries = try store.getEntries(at: store.position(date: startDate))
        let faultFragments = [
            "Publishing changes from within view updates",
            "laid out reentrantly",
        ]
        return entries.compactMap { entry in
            guard entry.date >= startDate,
                  let message = (entry as? OSLogEntryLog)?.composedMessage,
                  faultFragments.contains(where: message.localizedCaseInsensitiveContains) else {
                return nil
            }
            return message
        }
    }

    /// A stationary pointer must continue to resolve to exactly one native
    /// row while table snapshots, scrolling, and appearance all change.
    @Test
    @MainActor
    func stationaryPointerChurnConvergesWithoutLayoutFaults() async throws {
        let logStart = Date()
        let harness = await Harness(workspaceCount: 300)
        defer { harness.tearDown() }

        let table = harness.container.tableView
        let visibleRows = table.rows(in: table.visibleRect)
        let hoveredIndex = try #require(
            visibleRows.location == NSNotFound ? nil : visibleRows.location
        )
        let hoveredRect = table.rect(ofRow: hoveredIndex)
        let pointerInWindow = table.convert(
            NSPoint(x: hoveredRect.midX, y: hoveredRect.midY),
            to: nil
        )

        harness.reconfigurationCount = 0
        table.mouseMoved(with: try Self.mouseMovedEvent(
            at: pointerInWindow,
            window: harness.window
        ))
        await harness.settleLayout()
        #expect(
            (1 ... 2).contains(harness.reconfigurationCount),
            "One pointer transition must reconfigure only its old and new native rows."
        )

        for iteration in 1 ... 40 {
            var rows = harness.rows
            let targetIndex = iteration % min(3, rows.count)
            rows[targetIndex] = Harness.makeRow(
                workspaceId: harness.workspaceIds[targetIndex],
                revision: iteration
            )
            harness.apply(rows)
            await Harness.flushStagedTableMutations()

            let maximumOffset = max(
                0,
                table.bounds.height - harness.container.clipView.bounds.height
            )
            let requestedOffset = CGFloat((iteration % 8) * 36)
            harness.container.clipView.scroll(
                to: NSPoint(x: 0, y: min(maximumOffset, requestedOffset))
            )
            harness.container.scrollView.reflectScrolledClipView(harness.container.clipView)
            harness.window.appearance = NSAppearance(
                named: iteration.isMultiple(of: 2) ? .darkAqua : .aqua
            )
            await harness.settleLayout(iterations: 2)
        }

        let faultMessages = try Self.viewUpdateFaultMessages(since: logStart)
        #expect(
            faultMessages.isEmpty,
            "Native sidebar pointer churn emitted layout faults:\n\(faultMessages.joined(separator: "\n"))"
        )

        harness.reconfigurationCount = 0
        await harness.settleLayout(iterations: 30)
        #expect(
            harness.reconfigurationCount == 0,
            "The native sidebar continued reconfiguring cells after pointer churn ended."
        )
    }
}

/// Exercises snapshot churn beyond the table viewport so every scroll cycle
/// realizes and retires native cells.
@Suite(.serialized)
final class SidebarOverflowingScrollContentChurnTests {
    @Test
    @MainActor
    func overflowingScrollWithContentChurnConvergesWithoutLayoutFaults() async throws {
        let harness = await SidebarLazyLayoutScaleTests.Harness(workspaceCount: 120)
        defer { harness.tearDown() }

        let table = harness.container.tableView
        let logStart = Date()
        for iteration in 0 ..< 32 {
            let targetIndex = 112 + (iteration % 8)
            var rows = harness.rows
            rows[targetIndex] = SidebarLazyLayoutScaleTests.Harness.makeRow(
                workspaceId: harness.workspaceIds[targetIndex],
                revision: iteration + 1
            )
            harness.apply(rows)
            await SidebarLazyLayoutScaleTests.Harness.flushStagedTableMutations()

            let maximumOffset = max(
                0,
                table.bounds.height - harness.container.clipView.bounds.height
            )
            let phase = CGFloat(iteration % 8) / 7
            let requestedOffset = iteration.isMultiple(of: 2)
                ? maximumOffset * phase
                : maximumOffset * (1 - phase)
            harness.container.clipView.scroll(to: NSPoint(x: 0, y: requestedOffset))
            harness.container.scrollView.reflectScrolledClipView(harness.container.clipView)
            await harness.settleLayout(iterations: 2)
        }

        let faultMessages = try SidebarLazyLayoutScaleTests.viewUpdateFaultMessages(since: logStart)
        #expect(
            faultMessages.isEmpty,
            "Native sidebar scrolling and content churn emitted layout faults:\n\(faultMessages.joined(separator: "\n"))"
        )

        harness.reconfigurationCount = 0
        await harness.settleLayout(iterations: 40)
        #expect(
            harness.reconfigurationCount == 0,
            "The native sidebar continued reconfiguring cells after scrolling ended."
        )
        #expect(
            harness.loadedCells().count < 150,
            "The native sidebar retained too many cells after overflowing scroll churn."
        )
    }
}
