import AppKit
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Double-clicking the sidebar's empty area must create a workspace the same
/// way the `+` button and File → New Workspace do: through the shared
/// new-workspace action path, so a configured `ui.newWorkspace.action` default
/// layout applies. Without a configured default it still appends a plain
/// workspace after the last row.
/// https://github.com/manaflow-ai/cmux/issues/10043
@MainActor
final class SidebarEmptyAreaNewWorkspaceActionTests: XCTestCase {
    private var configRoot: URL?

    override func tearDown() {
        if let configRoot {
            try? FileManager.default.removeItem(at: configRoot)
        }
        configRoot = nil
        super.tearDown()
    }

    func testEmptyAreaDoubleClickAppliesConfiguredNewWorkspaceLayout() throws {
        let appDelegate = try XCTUnwrap(AppDelegate.shared)
        let store = try makeConfigStore(globalJSON: """
        {
          "actions": {
            "empty-area-layout": {
              "type": "workspace",
              "title": "Empty Area Layout",
              "workspace": { "name": "EmptyAreaLayout" }
            }
          },
          "ui": { "newWorkspace": { "action": "empty-area-layout" } }
        }
        """)

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }
        let manager = try XCTUnwrap(appDelegate.tabManagerFor(windowId: windowId))
        let context = try XCTUnwrap(
            appDelegate.mainWindowContexts.values.first { $0.windowId == windowId }
        )
        context.cmuxConfigStore = store

        let initialCount = manager.tabs.count
        appDelegate.performSidebarEmptyAreaNewWorkspaceAction(tabManager: manager)
        spinRunLoop()

        XCTAssertEqual(manager.tabs.count, initialCount + 1, "Expected exactly one new workspace")
        XCTAssertTrue(
            manager.tabs.contains { $0.customTitle == "EmptyAreaLayout" },
            "Empty-area double-click must honor ui.newWorkspace.action, got titles "
                + "\(manager.tabs.map { $0.customTitle ?? "<none>" })"
        )
    }

    func testEmptyAreaDoubleClickWithoutConfiguredActionAppendsPlainWorkspace() throws {
        let appDelegate = try XCTUnwrap(AppDelegate.shared)
        let store = try makeConfigStore(globalJSON: "{}")

        let windowId = appDelegate.createMainWindow()
        defer { closeWindow(withId: windowId) }
        let manager = try XCTUnwrap(appDelegate.tabManagerFor(windowId: windowId))
        let context = try XCTUnwrap(
            appDelegate.mainWindowContexts.values.first { $0.windowId == windowId }
        )
        context.cmuxConfigStore = store

        // Select the first workspace so "after the selected one" and "at the end"
        // are distinguishable positions.
        let first = try XCTUnwrap(manager.tabs.first)
        manager.addWorkspace(placementOverride: .end)
        manager.selectWorkspace(first)
        let countBeforeDoubleClick = manager.tabs.count

        appDelegate.performSidebarEmptyAreaNewWorkspaceAction(tabManager: manager)
        spinRunLoop()

        XCTAssertEqual(manager.tabs.count, countBeforeDoubleClick + 1)
        XCTAssertNotEqual(
            manager.tabs.last?.id,
            first.id,
            "A plain empty-area workspace still lands after the last row"
        )
        XCTAssertEqual(
            manager.tabs.last?.id,
            manager.selectedTabId,
            "The appended workspace is the selected one"
        )
    }

    // MARK: - Helpers

    private func makeConfigStore(globalJSON: String) throws -> CmuxConfigStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-sidebar-empty-area-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        configRoot = root
        let globalConfigURL = root.appendingPathComponent("cmux.json")
        try globalJSON.write(to: globalConfigURL, atomically: true, encoding: .utf8)
        let store = CmuxConfigStore(
            globalConfigPath: globalConfigURL.path,
            localConfigPath: nil,
            startFileWatchers: false
        )
        store.loadAll()
        return store
    }

    private func spinRunLoop() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }

    private func window(withId windowId: UUID) -> NSWindow? {
        let identifier = "cmux.main.\(windowId.uuidString)"
        // The SwiftUI-hosted main window registers in `NSApp.windows` on a later
        // run-loop turn, so poll briefly instead of racing a cold start.
        let deadline = Date().addingTimeInterval(3.0)
        repeat {
            if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == identifier }) {
                return window
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        } while Date() < deadline
        return nil
    }

    private func closeWindow(withId windowId: UUID) {
        window(withId: windowId)?.close()
        spinRunLoop()
    }
}
