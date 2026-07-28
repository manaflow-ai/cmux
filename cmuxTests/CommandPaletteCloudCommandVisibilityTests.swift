import CmuxCommandPalette
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Command palette cloud command visibility", .serialized)
struct CommandPaletteCloudCommandVisibilityTests {
    @Test func currentCloudVMCommandsRequireAnExactManagedCloudWorkspace() throws {
        try withCloudVMUIEnabled {
            let windowLevelCommandIDs: Set<String> = [
                ContentView.commandPaletteCloudOpenCommandId,
                ContentView.commandPaletteCloudRestoreCommandId,
            ]
            var context = CommandPaletteContextSnapshot()

            #expect(visibleCloudCommandIDs(context) == windowLevelCommandIDs)

            context.setBool(CommandPaletteContextKeys.hasWorkspace, true)
            #expect(visibleCloudCommandIDs(context) == windowLevelCommandIDs)

            context.setBool(CommandPaletteContextKeys.workspaceHasCloudVM, true)
            #expect(
                visibleCloudCommandIDs(context)
                    == Set(ContentView.commandPaletteCloudCommandContributions().map(\.commandId))
            )

            context.setBool(CommandPaletteContextKeys.hasWorkspace, false)
            #expect(visibleCloudCommandIDs(context) == windowLevelCommandIDs)
        }
    }

    private func visibleCloudCommandIDs(_ context: CommandPaletteContextSnapshot) -> Set<String> {
        Set(
            ContentView.commandPaletteCloudCommandContributions()
                .filter { $0.when(context) }
                .map(\.commandId)
        )
    }

    private func withCloudVMUIEnabled<T>(_ body: () throws -> T) throws -> T {
        let flags = CmuxFeatureFlags.shared
        let definition = try #require(
            CmuxFeatureFlags.allFlags.first { $0.key == "cloud-vm-ui-enabled-release" }
        )
        let previousOverride = flags.overrideValue(for: definition)
        flags.setOverride(true, for: definition)
        defer { flags.setOverride(previousOverride, for: definition) }
        #expect(flags.isCloudVMUIEnabled)
        return try body()
    }
}
