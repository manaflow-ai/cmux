import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class DockControlsStoreTests: XCTestCase {
    func testReloadWithoutDockConfigKeepsDefaultTerminalSurface() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-dock-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let store = DockControlsStore()
        let workspaceId = UUID()
        defer {
            store.reload(rootDirectory: nil, workspaceId: nil)
            try? FileManager.default.removeItem(at: root)
        }

        store.reload(rootDirectory: root.path, workspaceId: workspaceId)
        let firstDefaultTerminal = try XCTUnwrap(store.defaultTerminal)
        let firstPanelId = firstDefaultTerminal.panel.id

        store.reload(rootDirectory: root.path, workspaceId: workspaceId)
        let secondDefaultTerminal = try XCTUnwrap(store.defaultTerminal)

        XCTAssertTrue(firstDefaultTerminal === secondDefaultTerminal)
        XCTAssertEqual(secondDefaultTerminal.panel.id, firstPanelId)
    }
}
