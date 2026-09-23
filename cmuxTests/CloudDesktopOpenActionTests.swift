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

            // Positive drag control goes through the same group used by the real row,
            // the drop destination mapper, catalog, and native factory (no reuse).
            let pane = try #require(fixture.owner.bonsplitController.allPaneIds.first)
            let destination = SurfaceDestination.dropDestination(workspaceID: fixture.owner.id,
                destination: .split(targetPane: pane, orientation: .vertical, insertFirst: false))
            let dropped = try await fixture.catalog.projectGroup(try #require(row.dragGroup), into: destination, focus: false)
            #expect(dropped.count == 1 && dropped[0].workspaceID == fixture.owner.id)
            #expect(fixture.catalog.projections(of: fixture.display.id).count == 2)
            #expect(fixture.owner.cloudVMBinding?.vmID == fixture.provider.machine.rawValue)
            #expect(fixture.other.panels.count == 1)
        }
    }
}
