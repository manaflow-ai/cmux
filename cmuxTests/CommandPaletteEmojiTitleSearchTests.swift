import CmuxCommandPalette
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct CommandPaletteEmojiTitleSearchTests {
    @Test func searchPrefersEmojiPrefixedFullTitleWordsOverPartialTitlePrefix() {
        let entries = [
            CommandPaletteSearchCorpusEntry(
                payload: "workspace.fullTitleMatch",
                rank: 20,
                title: "🧪 Command Palette",
                searchableTexts: ["🧪 Command Palette", "Workspace", "workspace", "switch", "go"]
            ),
            CommandPaletteSearchCorpusEntry(
                payload: "workspace.partialTitlePrefix",
                rank: 0,
                title: "Command Palette Archive",
                searchableTexts: ["Command Palette Archive", "Workspace", "workspace", "switch", "go"]
            ),
        ]

        let results = CommandPaletteSearchEngine(entries: entries).search(
            query: "command palette",
            resultLimit: 5
        ) { _, _ in 0 }

        #expect(results.first?.payload == "workspace.fullTitleMatch")
    }

    @Test func searchPrefersEmojiPrefixedTitleWordPrefixOverHiddenTokenMatches() {
        let entries = [
            CommandPaletteSearchCorpusEntry(
                payload: "workspace.titlePrefixMatch",
                rank: 20,
                title: "🧪 Command Palette Archive",
                searchableTexts: ["🧪 Command Palette Archive", "Workspace", "workspace", "switch", "go"]
            ),
            CommandPaletteSearchCorpusEntry(
                payload: "workspace.hiddenTokenMatches",
                rank: 0,
                title: "Other Workspace",
                searchableTexts: ["Other Workspace", "Workspace", "workspace", "switch", "go", "command", "palette"]
            ),
        ]

        let results = CommandPaletteSearchEngine(entries: entries).search(
            query: "command palette",
            resultLimit: 5
        ) { _, _ in 0 }

        #expect(results.first?.payload == "workspace.titlePrefixMatch")
    }

    @Test func searchPrefersEmojiPrefixedFullTitleWordsWithRepeatedQuerySpaces() {
        let entries = [
            CommandPaletteSearchCorpusEntry(
                payload: "workspace.fullTitleMatch",
                rank: 20,
                title: "🧪 Command Palette",
                searchableTexts: ["🧪 Command Palette", "Workspace", "workspace", "switch", "go"]
            ),
            CommandPaletteSearchCorpusEntry(
                payload: "workspace.hiddenTokenMatches",
                rank: 0,
                title: "Other Workspace",
                searchableTexts: ["Other Workspace", "Workspace", "command", "palette"]
            ),
        ]

        let results = CommandPaletteSearchEngine(entries: entries).search(
            query: "command  palette",
            resultLimit: 5
        ) { _, _ in 0 }

        #expect(results.first?.payload == "workspace.fullTitleMatch")
    }

    @MainActor
    @Test func commandPaletteWorkspaceNameUsesRenamedGroupAnchorTitle() throws {
        let manager = TabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let groupId = try #require(manager.createWorkspaceGroup(name: "Group 1", childWorkspaceIds: [manager.tabs[0].id]))
        let group = try #require(manager.workspaceGroups.first { $0.id == groupId })
        let anchor = try #require(manager.tabs.first { $0.id == group.anchorWorkspaceId })

        manager.renameWorkspaceGroup(groupId: groupId, name: "AUSTIN GENERAL INTELLIGENCE")

        #expect(ContentView.commandPaletteWorkspaceDisplayName(
            customTitle: anchor.customTitle,
            resolvedTitle: manager.resolvedWorkspaceDisplayTitle(for: anchor)
        ) == "AUSTIN GENERAL INTELLIGENCE")
    }
}
