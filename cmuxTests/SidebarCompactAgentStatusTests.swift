import AppKit
import CmuxSidebar
import Testing
@testable import cmux_DEV

/// `sidebar.compactAgentStatus`: agent hook status entries move from their
/// own metadata row onto the workspace title line as a tinted glyph.
@Suite
@MainActor
struct SidebarCompactAgentStatusTests {
    private static func entry(
        _ key: String,
        _ value: String,
        icon: String? = "bolt.fill",
        color: String? = "#4C8DFF"
    ) -> SidebarStatusEntry {
        SidebarStatusEntry(key: key, value: value, icon: icon, color: color)
    }

    private static func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "SidebarCompactAgentStatusTests.\(UUID().uuidString)")!
    }

    @Test
    func offKeepsEveryStatusEntryAsARow() {
        let entries = [Self.entry("claude_code", "Running"), Self.entry("deploy", "green")]
        let result = SidebarAgentStatusTitleGlyph.partition(entries, compacts: false)

        #expect(result.glyphs.isEmpty)
        #expect(result.rows == entries)
    }

    @Test
    func onMovesOnlyAgentKeysToTheTitleLine() {
        let custom = Self.entry("deploy", "green", icon: "checkmark", color: nil)
        let result = SidebarAgentStatusTitleGlyph.partition(
            [
                Self.entry("claude_code", "Running"),
                custom,
                Self.entry("codex", "Needs input", icon: "bell.fill"),
            ],
            compacts: true
        )

        #expect(result.rows == [custom])
        #expect(result.glyphs.map(\.id) == ["claude_code", "codex"])
        #expect(result.glyphs.map(\.symbolName) == ["bolt.fill", "bell.fill"])
        #expect(result.glyphs.first?.colorHex == "#4C8DFF")
        #expect(result.glyphs.first?.tooltip.contains("Claude Code") == true)
        #expect(result.glyphs.first?.tooltip.contains("Running") == true)
        #expect(result.glyphs.last?.tooltip.contains("Codex") == true)
    }

    @Test
    func titleLineIsCappedWithoutReturningExtrasToRows() {
        let agents = ["claude_code", "codex", "gemini", "opencode"].map { Self.entry($0, "Running") }
        let result = SidebarAgentStatusTitleGlyph.partition(agents, compacts: true)

        #expect(result.glyphs.count == SidebarAgentStatusTitleGlyph.maxVisible)
        #expect(result.glyphs.map(\.id) == ["claude_code", "codex", "gemini"])
        #expect(result.rows.isEmpty)
    }

    @Test
    func iconsNormalizeAndFallBackToADot() {
        let result = SidebarAgentStatusTitleGlyph.partition(
            [
                Self.entry("claude_code", "Needs input", icon: "sf:bell.fill"),
                Self.entry("codex", "Running", icon: "emoji:⚡"),
                Self.entry("gemini", "Running", icon: nil),
            ],
            compacts: true
        )

        #expect(result.glyphs.map(\.symbolName) == [
            "bell.fill",
            SidebarAgentStatusTitleGlyph.fallbackSymbolName,
            SidebarAgentStatusTitleGlyph.fallbackSymbolName,
        ])
    }

    @Test
    func agentDisplayNamesUseBuiltInDefinitions() {
        #expect(SidebarAgentStatusTitleGlyph.agentDisplayName(forStatusKey: "claude_code") == "Claude Code")
        #expect(SidebarAgentStatusTitleGlyph.agentDisplayName(forStatusKey: "codex") == "Codex")
        #expect(SidebarAgentStatusTitleGlyph.agentDisplayName(forStatusKey: "hermes-agent") == "Hermes Agent")
        #expect(SidebarAgentStatusTitleGlyph.agentDisplayName(forStatusKey: "future_agent") == "Future Agent")
    }

    @Test
    func settingDefaultsOffAndInvalidatesCachedSnapshots() {
        let defaultsOff = Self.makeDefaults()
        let off = SidebarTabItemSettingsSnapshot(defaults: defaultsOff)
        #expect(!off.compactsAgentStatus)

        let defaultsOn = Self.makeDefaults()
        defaultsOn.set(true, forKey: "sidebarCompactAgentStatus")
        let on = SidebarTabItemSettingsSnapshot(defaults: defaultsOn)
        #expect(on.compactsAgentStatus)

        #expect(
            SidebarWorkspaceSnapshotFactory.presentationKey(settings: off, showsAgentActivity: true)
                != SidebarWorkspaceSnapshotFactory.presentationKey(settings: on, showsAgentActivity: true)
        )
    }

    @Test
    func appKitRowDrawsTheGlyphBeforeTheTitleAndDropsTheStatusRow() throws {
        let running = Self.entry("claude_code", "Running")
        let asRow = SidebarAppKitRowCellTests.makeModel(metadataEntries: [running])
        let partitioned = SidebarAgentStatusTitleGlyph.partition([running], compacts: true)
        let compact = SidebarAppKitRowCellTests.makeModel(
            metadataEntries: partitioned.rows,
            titleAgentStatuses: partitioned.glyphs
        )

        let rowCell = SidebarAppKitRowCellTests.configuredCell(model: asRow)
        let compactCell = SidebarAppKitRowCellTests.configuredCell(model: compact)
        let rowHeight = rowCell.layoutContent(model: asRow, width: 280, apply: false)
        compactCell.frame = NSRect(x: 0, y: 0, width: 280, height: 60)
        let compactHeight = compactCell.layoutContent(model: compact, width: 280, apply: true)

        #expect(compactHeight < rowHeight)

        let tooltip = try #require(partitioned.glyphs.first?.tooltip)
        let glyphView = try #require(
            SidebarAppKitRowCellTests.descendants(of: compactCell)
                .compactMap { $0 as? NSImageView }
                .first { !$0.isHidden && $0.toolTip == tooltip }
        )
        let titleView = try #require(
            SidebarAppKitRowCellTests.descendants(of: compactCell)
                .compactMap { $0 as? SidebarRowTextView }
                .first { !$0.isHidden && $0.stringValue == compact.snapshot.title }
        )
        #expect(glyphView.image != nil)
        #expect(glyphView.frame.maxX <= titleView.frame.minX)
        #expect(abs(glyphView.frame.midY - titleView.frame.minY) < titleView.frame.height)
    }
}
