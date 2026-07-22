import CmuxCommandPalette
import CmuxSettings
import Foundation
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

@MainActor
@Suite("Command palette workspace todo action outcomes", .serialized)
struct CommandPaletteWorkspaceTodoActionOutcomeTests {
    @Test func checklistInsertionReportsRejectedAndSuccessfulOutcomes() throws {
        let defaults = UserDefaults.standard
        let key = BetaFeaturesCatalogSection().workspaceTodoControls.userDefaultsKey
        let previousValue = defaults.object(forKey: key)
        defaults.set(true, forKey: key)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        let tabManager = TabManager()
        let workspace = try #require(tabManager.selectedWorkspace)
        let contribution = try #require(
            WorkspaceTodoPaletteCommands.contributions(workspaceSubtitle: { _ in "" }).first {
                $0.arguments.map(\.name) == ["text"]
            }
        )
        var registry = CommandPaletteHandlerRegistry()
        WorkspaceTodoPaletteCommands.registerHandlers(in: &registry, tabManager: tabManager)
        let handler = try #require(registry.handler(for: contribution.commandId))

        let initialCount = workspace.todoState.checklist.count
        let rejected = handler(CmuxActionInvocation(
            source: .automation,
            arguments: ["text": "  \n\t  "]
        ))
        #expect(rejected == .failed(
            code: "action_failed",
            message: String(
                localized: "action.error.checklistItemAddFailed",
                defaultValue: "The checklist item could not be added."
            )
        ))
        #expect(workspace.todoState.checklist.count == initialCount)

        let completed = handler(CmuxActionInvocation(
            source: .automation,
            arguments: ["text": "  Ship the palette action  "]
        ))
        #expect(completed == .completed)
        #expect(workspace.todoState.checklist.count == initialCount + 1)
        #expect(workspace.todoState.checklist.last?.text == "Ship the palette action")
    }
}

@MainActor
@Suite("Command palette inline VS Code outcome")
struct CommandPaletteInlineVSCodeOutcomeTests {
    @Test func acceptedAsynchronousOpenReportsQueued() {
        #expect(ContentView.commandPaletteInlineVSCodeOpenResult(didQueue: true) == .queued)
    }

    @Test func rejectedOpenReportsFailure() {
        #expect(
            ContentView.commandPaletteInlineVSCodeOpenResult(didQueue: false)
                == .failed(
                    code: "open_failed",
                    message: String(
                        localized: "action.error.inlineVSCodeOpenFailed",
                        defaultValue: "VS Code (Inline) could not open the directory."
                    )
                )
        )
    }
}
