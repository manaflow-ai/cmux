import CmuxCommandPalette
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Command palette cloud action arguments")
struct CommandPaletteCloudActionArgumentsTests {
    @Test func restoreDeclaresSnapshotIdentifier() throws {
        let restore = try #require(
            ContentView.commandPaletteCloudCommandContributions().first {
                $0.commandId == ContentView.commandPaletteCloudRestoreCommandId
            }
        )

        #expect(restore.arguments == [CmuxActionArgumentDefinition(name: "snapshot_id")])
    }
}
