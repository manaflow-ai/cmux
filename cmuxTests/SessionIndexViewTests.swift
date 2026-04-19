import AppKit
import SwiftUI
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class SessionIndexViewTests: XCTestCase {
    func testSectionPopoverHostCoordinatorSkipsHiddenRefreshes() {
        let harness = makeHarness()
        let coordinator = harness.host.makeCoordinator()

        coordinator.update(
            section: harness.section,
            search: harness.search,
            loadSnapshot: harness.loadSnapshot,
            onResume: nil
        )
        coordinator.update(
            section: harness.section,
            search: harness.search,
            loadSnapshot: harness.loadSnapshot,
            onResume: nil
        )

        XCTAssertEqual(coordinator.debugRefreshContentCallCount, 0)
    }

    func testSectionPopoverHostCoordinatorRefreshesOnceWhenPresented() {
        let harness = makeHarness(isPresented: true)
        let coordinator = harness.host.makeCoordinator()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let anchor = NSView(frame: NSRect(x: 20, y: 20, width: 160, height: 80))
        window.contentView?.addSubview(anchor)
        coordinator.anchorView = anchor

        defer {
            coordinator.dismiss()
            pumpRunLoop()
            window.orderOut(nil)
        }

        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        pumpRunLoop()

        coordinator.update(
            section: harness.section,
            search: harness.search,
            loadSnapshot: harness.loadSnapshot,
            onResume: nil
        )
        XCTAssertEqual(coordinator.debugRefreshContentCallCount, 0)

        coordinator.present()
        pumpRunLoop()

        XCTAssertTrue(coordinator.debugIsPopoverShown)
        XCTAssertEqual(coordinator.debugRefreshContentCallCount, 1)

        coordinator.update(
            section: harness.section,
            search: harness.search,
            loadSnapshot: harness.loadSnapshot,
            onResume: nil
        )

        XCTAssertEqual(coordinator.debugRefreshContentCallCount, 1)
    }

    private func makeHarness(isPresented: Bool = false) -> SessionPopoverHarness {
        var isPresented = isPresented
        let binding = Binding(
            get: { isPresented },
            set: { isPresented = $0 }
        )
        let section = IndexSection(
            key: .directory("/tmp"),
            title: "tmp",
            icon: .folder
        )
        let search: SessionSearchFn = { _, _, _, _ in
            SessionIndexStore.SearchOutcome(entries: [], errors: [])
        }
        let loadSnapshot: DirectorySnapshotFn = { cwd in
            DirectorySnapshot(cwd: cwd ?? "", entries: [], errors: [])
        }
        let host = SectionPopoverHost(
            isPresented: binding,
            section: section,
            search: search,
            loadSnapshot: loadSnapshot,
            onResume: nil
        )
        return SessionPopoverHarness(host: host, section: section, search: search, loadSnapshot: loadSnapshot)
    }

    private func pumpRunLoop() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
}

private struct SessionPopoverHarness {
    let host: SectionPopoverHost
    let section: IndexSection
    let search: SessionSearchFn
    let loadSnapshot: DirectorySnapshotFn
}
