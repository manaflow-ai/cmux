import CMUXAgentLaunch
import CmuxSettings
import CmuxSidebar
import Foundation
import Testing
@testable import cmux_DEV

private struct UnlimitedSidebarLog: SidebarLogEntryLimitProviding {
    let configuredMaxSidebarLogEntries: Int? = nil
}

@MainActor
@Suite("SidebarAgentUsage")
struct SidebarAgentUsageTests {
    private static let usage = SidebarAgentUsage(modelName: "Opus 4.8", contextFraction: 0.4213, estimatedCostUSD: 1.2)

    private static func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "SidebarAgentUsageTests.\(UUID().uuidString)")!
    }

    private static func statusEntry(key: String, value: String) -> SidebarStatusEntry {
        SidebarStatusEntry(key: key, value: value, icon: "bolt.fill", color: "#4C8DFF", priority: 5, timestamp: Date(timeIntervalSince1970: 10))
    }

    @Test func summaryShowsModelContextPercentAndEstimatedCost() {
        let formatter = SidebarAgentUsageFormatter(locale: Locale(identifier: "en_US"))
        #expect(formatter.summary(for: Self.usage) == "Opus 4.8 · 42% · ~$1.20")
    }

    @Test func summaryOmitsUnknownWindowAndPrice() {
        let formatter = SidebarAgentUsageFormatter(locale: Locale(identifier: "en_US"))
        let usage = SidebarAgentUsage(modelName: "gpt-6-astra", contextFraction: nil, estimatedCostUSD: nil)
        #expect(formatter.summary(for: usage) == "gpt-6-astra")
    }

    @Test func decorationExtendsOnlyTheMatchingAgentEntry() {
        let formatter = SidebarAgentUsageFormatter(locale: Locale(identifier: "en_US"))
        let claude = Self.statusEntry(key: "claude_code", value: "Running")
        let other = Self.statusEntry(key: "build", value: "Passing")

        let decorated = formatter.decorate([claude, other], usageByStatusKey: ["claude_code": Self.usage])

        #expect(decorated[0].value == "Running · Opus 4.8 · 42% · ~$1.20")
        #expect(decorated[0].icon == claude.icon)
        #expect(decorated[0].color == claude.color)
        #expect(decorated[0].priority == claude.priority)
        #expect(decorated[1] == other)
        #expect(formatter.decorate([claude], usageByStatusKey: [:]) == [claude])
    }

    @Test func settingIsOffByDefaultAndHiddenByHideAllDetails() {
        let defaults = Self.makeDefaults()
        #expect(!SidebarTabItemSettingsSnapshot(defaults: defaults).visibleAuxiliaryDetails.showsAgentUsage)

        defaults.set(true, forKey: SidebarWorkspaceDetailDefaults.showAgentUsageKey)
        #expect(SidebarTabItemSettingsSnapshot(defaults: defaults).visibleAuxiliaryDetails.showsAgentUsage)

        defaults.set(true, forKey: SidebarCatalogSection().hideAllDetails.userDefaultsKey)
        #expect(!SidebarTabItemSettingsSnapshot(defaults: defaults).visibleAuxiliaryDetails.showsAgentUsage)
    }

    @Test func sessionStartClearsUsageAndOtherAgentsAreIgnored() {
        let defaults = Self.makeDefaults()
        let workspaceID = UUID()
        let metadata = WorkspaceSidebarMetadataModel(limitProvider: UnlimitedSidebarLog())
        let coordinator = SidebarAgentUsageCoordinator(defaults: defaults) { id in
            id == workspaceID ? metadata : nil
        }
        metadata.updateAgentUsage(Self.usage, forStatusKey: "claude_code")

        // Enabled: a session start clears the previous session's numbers.
        defaults.set(true, forKey: SidebarWorkspaceDetailDefaults.showAgentUsageKey)
        coordinator.noteHookEvent(WorkstreamEvent(
            sessionId: "s1",
            hookEventName: .sessionStart,
            source: "claude",
            workspaceId: workspaceID.uuidString,
            transcriptPath: "/nonexistent/s1.jsonl"
        ))
        #expect(metadata.agentUsageByStatusKey["claude_code"] == nil)

        // Unsupported agents are ignored entirely.
        metadata.updateAgentUsage(Self.usage, forStatusKey: "claude_code")
        coordinator.noteHookEvent(WorkstreamEvent(
            sessionId: "s2",
            hookEventName: .sessionStart,
            source: "gemini",
            workspaceId: workspaceID.uuidString
        ))
        #expect(metadata.agentUsageByStatusKey["claude_code"] == Self.usage)
    }
}
