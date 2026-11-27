@preconcurrency import XCTest
import AppKit
import SwiftUI

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class MainWindowHitTestMutationMonitorTests: XCTestCase {
    func testReportsOnlyRemovalsInsideAWalkAndOnlyOnce() {
        var reports: [MainWindowHitTestMutationMonitor.Mutation] = []
        let monitor = MainWindowHitTestMutationMonitor { reports.append($0) }
        let subview = NSView()

        monitor.subviewWillBeRemoved(subview, subviewCount: 3, eventType: .mouseMoved)
        XCTAssertTrue(reports.isEmpty, "A removal outside a hit-test walk is ordinary layout")

        monitor.walk {
            monitor.walk {
                monitor.subviewWillBeRemoved(subview, subviewCount: 142, eventType: .mouseMoved)
            }
            monitor.subviewWillBeRemoved(subview, subviewCount: 141, eventType: .mouseMoved)
        }
        XCTAssertEqual(reports, [
            MainWindowHitTestMutationMonitor.Mutation(
                removedSubviewType: "NSView",
                subviewCountBeforeRemoval: 142,
                eventType: NSEvent.EventType.mouseMoved.rawValue
            ),
        ])
    }

    /// AppKit's `-[NSView hitTest:]` walks the root's subviews by index; a
    /// child whose hitTest removes a sibling is the re-entrant mutation behind
    /// CMUXTERM-MACOS-41RH. The main window host must report it.
    func testMainWindowHostReportsSiblingRemovedFromChildHitTest() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        let host = MainWindowHostingView(rootView: AnyView(Color.clear))
        var reports: [MainWindowHitTestMutationMonitor.Mutation] = []
        host.hitTestMutationMonitor = MainWindowHitTestMutationMonitor { reports.append($0) }
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 200)

        let victim = VictimView(frame: host.bounds)
        let remover = SiblingRemovingView(frame: host.bounds)
        host.addSubview(victim)
        host.addSubview(remover)
        remover.victim = victim

        victim.removeFromSuperview()
        host.addSubview(victim, positioned: .below, relativeTo: remover)
        XCTAssertTrue(reports.isEmpty, "Removals outside hit testing must not report")

        _ = host.hitTest(NSPoint(x: 100, y: 100))

        XCTAssertGreaterThan(remover.hitTestCount, 0, "The walk must reach the child")
        XCTAssertNil(victim.superview)
        XCTAssertEqual(reports.map(\.removedSubviewType), ["VictimView"])
    }
}

private final class VictimView: NSView {}

private final class SiblingRemovingView: NSView {
    weak var victim: NSView?
    private(set) var hitTestCount = 0

    override func hitTest(_ point: NSPoint) -> NSView? {
        hitTestCount += 1
        victim?.removeFromSuperview()
        return nil
    }
}
