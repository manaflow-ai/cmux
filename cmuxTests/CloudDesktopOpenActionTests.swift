import CmuxCloud
import AppKit
import Bonsplit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Desktop sidebar placement", .serialized, .timeLimit(.minutes(1)))
struct CloudDesktopOpenActionTests {
    @Test("A queued Desktop click retains its same-VM destination like a drop",
          arguments: [false, true], [false, true])
    func capturesClickDestination(hasRemoteView: Bool, menu: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try CloudDesktopOpenFixture(hasRemoteView: hasRemoteView)
            defer { fixture.close() }
            let row = try fixture.poolNode()
            try fixture.activate(row, menu: menu)
            // The native action returns before its Task starts. Navigation in this gap
            // must not send the captured Desktop to another machine's selected workspace.
            fixture.selectedID = fixture.other.id
            await fixture.waitForOpen()
            #expect(fixture.failures.isEmpty)
            #expect(fixture.completions == 1)
            let clicked = fixture.catalog.projections(of: fixture.display.id)
            #expect(clicked.count == 1)
            #expect(clicked.first?.workspaceID == fixture.owner.id)
            #expect(fixture.provider.destinations == [.workspace(id: fixture.owner.id, placement: .split)])

            // Exercise the actual workspace drop action, including commit and focus.
            try await fixture.drop(row, into: fixture.owner)
            #expect(fixture.catalog.projections(of: fixture.display.id).count == 2)
            #expect(fixture.owner.cloudVMBinding?.vmID == fixture.provider.machine.rawValue)
            #expect(fixture.other.panels.count == 1)
        }
    }

    @Test("Click and drag reject the other VM even when labels and daemon IDs match",
          arguments: ["desktop-a", "desktop-b"], [false, true])
    func foreignDestination(ownerID: String, navigateBeforeTask: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try CloudDesktopOpenFixture(ownerID: ownerID)
            defer { fixture.close() }
            let row = try fixture.poolNode()
            let original = fixture.other.bonsplitController.treeSnapshot()
            fixture.selectedID = fixture.other.id
            try fixture.activate(row)
            if navigateBeforeTask { fixture.selectedID = fixture.owner.id }
            await fixture.waitForOpen()
            #expect(fixture.failures == [SurfaceTransferRejection.cloudMachineMismatch.message])
            #expect(fixture.provider.destinations.isEmpty)
            let pane = try #require(fixture.other.bonsplitController.allPaneIds.first)
            #expect(!fixture.other.handleSurfaceResourceDrop(group: try #require(row.dragGroup),
                destination: .split(targetPane: pane, orientation: .horizontal, insertFirst: false),
                catalog: fixture.catalog))
            #expect(fixture.other.bonsplitController.treeSnapshot() == original)
            #expect(fixture.catalog.projections.isEmpty)
            #expect(fixture.other.cloudVMID != fixture.owner.cloudVMID)
        }
    }

    @Test("Cold open and repeated clicks retain split geometry and reuse", arguments: [false, true])
    func repeatOpen(hasRemoteView: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try CloudDesktopOpenFixture(hasRemoteView: hasRemoteView)
            defer { fixture.close() }
            let row = try fixture.poolNode()
            try fixture.activate(row)
            await fixture.waitForOpen()
            #expect(fixture.failures.isEmpty)
            let first = try #require(fixture.catalog.projections(of: fixture.display.id).first)
            let layout = fixture.owner.bonsplitController.treeSnapshot()
            #expect(fixture.owner.bonsplitController.allPaneIds.count == 2)
            try fixture.activate(row, menu: true)
            await fixture.waitForOpen()
            #expect(fixture.catalog.projections(of: fixture.display.id) == [first])
            #expect(fixture.owner.bonsplitController.treeSnapshot() == layout)
            #expect(fixture.owner.focusedPanelId == first.panelID)
            #expect(fixture.provider.destinations.count == 1)
        }
    }

    @Test("Workspace-nested Desktop creates and reuses only that same-VM workspace's view", arguments: [false, true])
    func nestedViews(hasRemoteView: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try CloudDesktopOpenFixture(hasRemoteView: hasRemoteView)
            defer { fixture.close() }
            let row = try fixture.poolNode()
            try fixture.activate(row)
            await fixture.waitForOpen()
            fixture.other.cloudVMBinding = WorkspaceCloudVMBinding(vmID: fixture.provider.machine.rawValue,
                isBase: false, remoteWorkspaceID: "ws-second")
            let nested = CloudTreeNode(id: "nested-desktop", kind: .display(fixture.display,
                openIn: fixture.other.id, remoteView: fixture.display.remoteViews?.first))
            try fixture.activate(nested)
            await fixture.waitForOpen()
            let projections = fixture.catalog.projections(of: fixture.display.id)
            #expect(projections.count == 2)
            #expect(Set(projections.map(\.workspaceID)) == [fixture.owner.id, fixture.other.id])
            let layout = fixture.other.bonsplitController.treeSnapshot()
            try fixture.activate(nested, menu: true)
            await fixture.waitForOpen()
            #expect(fixture.catalog.projections(of: fixture.display.id) == projections)
            #expect(fixture.other.bonsplitController.treeSnapshot() == layout)
            #expect(fixture.failures.isEmpty)
        }
    }

    @Test("Machine Open Desktop keeps the same captured-destination contract")
    func machineMenu() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try CloudDesktopOpenFixture()
            defer { fixture.close() }
            let machine = MachineSnapshot(id: fixture.provider.machine.rawValue, provider: "freestyle",
                image: "cmux-devbox", isDesktop: true, activity: .ready, createdAt: nil, label: "same machine label")
            let item = try #require(fixture.coordinator.machineMenuItems(machine).first {
                $0.title == String(localized: "machines.menu.openDesktop", defaultValue: "Open Desktop")
            })
            let action = try #require(item.action)
            #expect(NSApp.sendAction(action, to: item.target, from: item))
            fixture.selectedID = fixture.other.id
            await fixture.waitForOpen()
            #expect(fixture.failures.isEmpty)
            #expect(fixture.catalog.projections(of: fixture.display.id).first?.workspaceID == fixture.owner.id)
        }
    }

    @Test("Unknown and stale Desktop rows fail before creating a pane", arguments: [false, true])
    func staleRow(unknown: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try CloudDesktopOpenFixture()
            defer { fixture.close() }
            let row = try fixture.poolNode()
            try fixture.activate(row)
            if unknown {
                fixture.catalog.remove(fixture.display.id)
            } else {
                var changed = fixture.display
                changed.remoteViews = []
                fixture.catalog.upsert(changed)
            }
            await fixture.waitForOpen()
            #expect(fixture.failures.count == 1)
            #expect(fixture.provider.destinations.isEmpty)
            #expect(fixture.catalog.projections.isEmpty)
            #expect(fixture.owner.panels.count == 1)
        }
    }

    @Test("Awaited Desktop opens recheck destination and provider authority",
          arguments: ["navigate", "rebind", "retire"])
    func delayedMaterialization(change: String) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try CloudDesktopOpenFixture()
            defer { fixture.close() }
            let started = CloudLinkFirstValue<Bool>()
            let release = CloudLinkFirstValue<Bool>()
            fixture.provider.beforeMaterialization = {
                started.resolve(true)
                _ = await release.result
            }
            try fixture.activate(try fixture.poolNode())
            _ = await started.result
            let panels = Set(fixture.owner.panels.keys)
            let panes = fixture.owner.bonsplitController.allPaneIds
            if change == "navigate" { fixture.selectedID = fixture.other.id }
            if change == "rebind" { fixture.owner.cloudVMBinding = fixture.other.cloudVMBinding }
            if change == "retire" { fixture.catalog.unregister(machine: fixture.provider.machine) }
            release.resolve(true)
            await fixture.waitForOpen()
            if change == "navigate" {
                #expect(fixture.catalog.projections(of: fixture.display.id).first?.workspaceID == fixture.owner.id)
                #expect(fixture.failures.isEmpty)
            } else {
                if change == "retire" { _ = await fixture.provider.didDiscard.result }
                #expect(fixture.catalog.projections.isEmpty)
                #expect(Set(fixture.owner.panels.keys) == panels)
                #expect(fixture.owner.bonsplitController.allPaneIds == panes)
                #expect(fixture.provider.discarded.count == 1)
            }
        }
    }
}
