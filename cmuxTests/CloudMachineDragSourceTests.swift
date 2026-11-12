import CmuxCloud
import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct CloudMachineDragSourceTests {
    @Test("A machine header exports only an internal reorder identity")
    func machineHeaderIsAnInternalDragSource() throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        let coordinator = fixture.coordinator
        coordinator.apply(nodes: fixture.nodes())
        let outline = try #require(coordinator.outlineView)
        let machine = try #require(coordinator.nodes.first)
        let writer = try #require(coordinator.outlineView(outline, pasteboardWriterForItem: machine))
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        #expect(board.writeObjects([writer]))
        #expect(board.types == [.cloudSidebarRow])
        #expect(board.string(forType: .cloudSidebarRow) == machine.id)
        #expect(fixture.transferRegistry.resolve(from: board) == nil)
        #expect(fixture.provider.moved.isEmpty && fixture.provider.projected.isEmpty)
        #expect(fixture.provider.refreshCount == 0)
    }
}
