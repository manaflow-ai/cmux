import AppKit
import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Opt-in visible fixture for remote computer-use recording. It hosts the real
/// outline and catalog actions with test resources, so recordings need no VM.
@MainActor
@Suite("Cloud sidebar recorded interaction", .serialized)
struct CloudSidebarInteractionTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CMUX_SIDEBAR_RECORDING_FIFO"] != nil))
    func recordNativeInteraction() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["CMUX_SIDEBAR_RECORDING_FIFO"])
        #expect(path.hasPrefix("/tmp/") || path.hasPrefix("/private/tmp/"))
        try #require(mkfifo(path, S_IRUSR | S_IWUSR) == 0)
        defer { unlink(path) }
        // O_RDWR opens the FIFO without blocking the UI while the controller
        // connects, and keeps it alive between separate command writes.
        let descriptor = open(path, O_RDWR)
        try #require(descriptor >= 0)
        let commands = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? commands.close() }
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close(); fixture.window.orderOut(nil) }
        let initial = fixture.snapshot(titles: ["workspace-1", "workspace-2", "workspace-3"])
        _ = fixture.catalog.replaceResources(initial.resources, on: fixture.machine, info: initial.machines[0], from: fixture.provider)
        fixture.window.title = "Cloud sidebar verification"
        fixture.window.setContentSize(NSSize(width: 380, height: 560))
        fixture.coordinator.apply(nodes: fixture.nodes(titles: ["workspace-1", "workspace-2", "workspace-3"]))
        fixture.window.center()
        fixture.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        print("CLOUD_SIDEBAR_FIXTURE_READY \(path)")

        for try await line in commands.bytes.lines {
            let command = try JSONDecoder().decode(Command.self, from: Data(line.utf8))
            if command.finish == true { break }
            if let titles = command.titles {
                let snapshot = fixture.snapshot(titles: titles)
                _ = fixture.catalog.replaceResources(
                    snapshot.resources, on: fixture.machine, info: snapshot.machines[0], from: fixture.provider
                )
                fixture.coordinator.apply(nodes: fixture.nodes(unread: Set(command.unread ?? []), titles: titles))
            }
            if let width = command.width { fixture.window.setContentSize(NSSize(width: width, height: 560)) }
            let outline = try #require(fixture.coordinator.outlineView)
            if let pinned = command.pinned {
                _ = fixture.coordinator.organize(pinned ? .pin : .unpin, nodeID: fixture.folderID("ws_2"))
            }
            let folder = try #require(CloudTreeNodeBuilder.flattened(fixture.coordinator.nodes).first {
                $0.id == fixture.folderID("ws_2")
            })
            if let collapsed = command.collapsed {
                if collapsed { outline.collapseItem(folder) } else { outline.expandItem(folder) }
            }
            let row = outline.row(forItem: folder)
            if let selected = command.selected {
                if selected { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
                else { outline.deselectAll(nil) }
            }
            fixture.container.layoutSubtreeIfNeeded()
            if let hovered = command.hovered,
               let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? CloudTreeCellView {
                cell.setHovered(hovered)
            }
            if let capture = command.capture { try fixture.attachScreenshot(named: capture) }
            let order = CloudSidebarOrganizationTree(nodes: fixture.coordinator.nodes).parent(of: folder.id)?.children.map(\.id) ?? []
            print("CLOUD_SIDEBAR_FIXTURE_STATE \(order)")
        }
        #expect(!fixture.coordinator.isDragging)
        #expect(fixture.provider.moved.isEmpty && fixture.provider.projected.isEmpty)
    }

    private struct Command: Decodable {
        var width: Double?
        var titles: [String]?
        var unread: [String]?
        var pinned: Bool?
        var collapsed: Bool?
        var selected: Bool?
        var hovered: Bool?
        var capture: String?
        var finish: Bool?
    }
}
