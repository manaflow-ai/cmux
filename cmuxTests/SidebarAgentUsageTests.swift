import CMUXAgentLaunch
import CmuxAgentChat
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

    private static func makeDefaults(enabled: Bool) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "SidebarAgentUsageTests.\(UUID().uuidString)")!
        defaults.set(enabled, forKey: SidebarWorkspaceDetailDefaults.showAgentUsageKey)
        return defaults
    }

    private static func statusEntry(key: String, value: String) -> SidebarStatusEntry {
        SidebarStatusEntry(key: key, value: value, icon: "bolt.fill", color: "#4C8DFF", priority: 5, timestamp: Date(timeIntervalSince1970: 10))
    }

    private static func claudeTranscript(contextTokens: Int, in directory: URL, name: String) throws -> String {
        let line = """
        {"type":"assistant","isSidechain":false,"message":{"id":"msg_\(name)","model":"claude-opus-4-8","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":\(contextTokens),"output_tokens":1}}}

        """
        let url = directory.appendingPathComponent("\(name).jsonl")
        try Data(line.utf8).write(to: url)
        return url.path
    }

    private static func event(
        _ name: WorkstreamEvent.HookEventName,
        session: String,
        workspace: UUID,
        transcript: String?,
        at seconds: TimeInterval,
        source: String = "claude",
        workspaceIdPadding: String = ""
    ) -> WorkstreamEvent {
        WorkstreamEvent(
            sessionId: session,
            hookEventName: name,
            source: source,
            workspaceId: workspace.uuidString + workspaceIdPadding,
            transcriptPath: transcript,
            receivedAt: Date(timeIntervalSince1970: seconds)
        )
    }

    // MARK: Formatting

    @Test func summaryShowsModelContextPercentAndEstimatedCost() {
        let formatter = SidebarAgentUsageFormatter(locale: Locale(identifier: "en_US"))
        #expect(formatter.summary(for: Self.usage) == "Opus 4.8 · 42% · ~$1.20")
        let partial = SidebarAgentUsage(modelName: "Opus 4.8", contextFraction: nil, estimatedCostUSD: 1.2, costIsLowerBound: true)
        #expect(formatter.summary(for: partial) == "Opus 4.8 · ~$1.20+")
    }

    @Test func summaryOmitsUnknownWindowAndPrice() {
        let formatter = SidebarAgentUsageFormatter(locale: Locale(identifier: "en_US"))
        let usage = SidebarAgentUsage(modelName: "gpt-6-astra", contextFraction: nil, estimatedCostUSD: nil)
        #expect(formatter.summary(for: usage) == "gpt-6-astra")
    }

    @Test func decorationExtendsOnlyTheMatchingAgentEntryAndExplainsTheCost() {
        let formatter = SidebarAgentUsageFormatter(locale: Locale(identifier: "en_US"))
        let claude = Self.statusEntry(key: "claude_code", value: "Running")
        let other = Self.statusEntry(key: "build", value: "Passing")

        let decorated = formatter.decorate([claude, other], usageByStatusKey: ["claude_code": Self.usage])

        #expect(decorated[0].value == "Running · Opus 4.8 · 42% · ~$1.20")
        #expect(decorated[0].helpText == SidebarAgentUsageFormatter.costHelpText)
        #expect(decorated[0].sidebarHelpText.hasSuffix(SidebarAgentUsageFormatter.costHelpText))
        #expect(decorated[0].icon == claude.icon)
        #expect(decorated[0].color == claude.color)
        #expect(decorated[0].priority == claude.priority)
        #expect(decorated[1] == other)
        #expect(formatter.decorate([claude], usageByStatusKey: [:]) == [claude])
    }

    @Test func settingIsOffByDefaultAndHiddenByHideAllDetails() {
        let defaults = UserDefaults(suiteName: "SidebarAgentUsageTests.\(UUID().uuidString)")!
        #expect(!SidebarTabItemSettingsSnapshot(defaults: defaults).visibleAuxiliaryDetails.showsAgentUsage)

        defaults.set(true, forKey: SidebarWorkspaceDetailDefaults.showAgentUsageKey)
        #expect(SidebarTabItemSettingsSnapshot(defaults: defaults).visibleAuxiliaryDetails.showsAgentUsage)

        defaults.set(true, forKey: SidebarCatalogSection().hideAllDetails.userDefaultsKey)
        #expect(!SidebarTabItemSettingsSnapshot(defaults: defaults).visibleAuxiliaryDetails.showsAgentUsage)
    }

    @Test func eachPartSettingDropsOnlyItsComponent() {
        // A reporter tooltip, so dropping the cost must visibly keep it.
        let claude = SidebarStatusEntry(key: "claude_code", value: "Running", timestamp: Date(timeIntervalSince1970: 10), helpText: "Reporter tooltip")
        func shown(_ parts: SidebarAgentUsage.Parts) -> SidebarStatusEntry {
            SidebarAgentUsageFormatter(locale: Locale(identifier: "en_US"), shownParts: parts)
                .decorate([claude], usageByStatusKey: ["claude_code": Self.usage])[0]
        }

        #expect(shown([.context, .cost]).value == "Running · 42% · ~$1.20")
        #expect(shown([.model, .cost]).value == "Running · Opus 4.8 · ~$1.20")
        #expect(shown([.model, .context]).value == "Running · Opus 4.8 · 42%")
        #expect(shown([.model, .context]).helpText == "Reporter tooltip")
        #expect(shown([.cost]).helpText == SidebarAgentUsageFormatter.costHelpText)
        #expect(shown([]) == claude)
    }

    @Test func partSettingsAreOnByDefaultAndEachFollowsItsKey() {
        let defaults = UserDefaults(suiteName: "SidebarAgentUsageTests.\(UUID().uuidString)")!
        func parts() -> SidebarAgentUsage.Parts {
            SidebarTabItemSettingsSnapshot(defaults: defaults).visibleAuxiliaryDetails.agentUsageParts
        }
        #expect(parts() == .all)

        defaults.set(false, forKey: SidebarWorkspaceDetailDefaults.showAgentModelKey)
        #expect(parts() == [.context, .cost])
        defaults.set(false, forKey: SidebarWorkspaceDetailDefaults.showAgentCostKey)
        #expect(parts() == [.context])
        defaults.set(false, forKey: SidebarWorkspaceDetailDefaults.showAgentContextKey)
        #expect(parts() == [])
    }

    // MARK: Coordinator

    @Test func rowShowsTheMostRecentlyActiveSessionAndPanesDoNotClearEachOther() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pathA = try Self.claudeTranscript(contextTokens: 100_000, in: directory, name: "a")
        let pathB = try Self.claudeTranscript(contextTokens: 300_000, in: directory, name: "b")
        let workspaceID = UUID()
        let metadata = WorkspaceSidebarMetadataModel(limitProvider: UnlimitedSidebarLog())
        let coordinator = SidebarAgentUsageCoordinator(
            defaults: Self.makeDefaults(enabled: true),
            coalesceInterval: .zero
        ) { id in id == workspaceID ? metadata : nil }
        func shownFraction() -> Double? { metadata.agentUsageByStatusKey["claude_code"]?.contextFraction }

        coordinator.noteHookEvent(Self.event(.preToolUse, session: "A", workspace: workspaceID, transcript: pathA, at: 1))
        await coordinator.waitUntilIdle()
        #expect(shownFraction() == 0.1)

        // Pane B starts: the row follows B, and A's record survives.
        coordinator.noteHookEvent(Self.event(.sessionStart, session: "B", workspace: workspaceID, transcript: pathB, at: 2))
        await coordinator.waitUntilIdle()
        #expect(shownFraction() == 0.3)

        coordinator.noteHookEvent(Self.event(.postToolUse, session: "A", workspace: workspaceID, transcript: pathA, at: 3))
        await coordinator.waitUntilIdle()
        #expect(shownFraction() == 0.1)

        // B ending does not clear A's usage.
        coordinator.noteHookEvent(Self.event(.sessionEnd, session: "B", workspace: workspaceID, transcript: pathB, at: 4))
        await coordinator.waitUntilIdle()
        #expect(shownFraction() == 0.1)

        // Unsupported agents are ignored.
        coordinator.noteHookEvent(Self.event(.sessionStart, session: "G", workspace: workspaceID, transcript: nil, at: 5, source: "gemini"))
        #expect(shownFraction() == 0.1)
    }

    @Test func togglingTheSettingClearsAndResamplesWithoutAHookEvent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = try Self.claudeTranscript(contextTokens: 200_000, in: directory, name: "a")
        let workspaceID = UUID()
        let defaults = Self.makeDefaults(enabled: false)
        let metadata = WorkspaceSidebarMetadataModel(limitProvider: UnlimitedSidebarLog())
        let coordinator = SidebarAgentUsageCoordinator(defaults: defaults, coalesceInterval: .zero) { id in
            id == workspaceID ? metadata : nil
        }

        // Off: the event is recorded but nothing is read or shown. An empty
        // `agentUsageByStatusKey` alone would also hold if the transcript were
        // read and the result discarded, so assert no sample was even
        // scheduled: with the setting off the feature must touch no file.
        coordinator.noteHookEvent(Self.event(.preToolUse, session: "A", workspace: workspaceID, transcript: path, at: 1))
        await coordinator.waitUntilIdle()
        #expect(metadata.agentUsageByStatusKey.isEmpty)
        #expect(coordinator.scheduledFlushCount == 0)

        defaults.set(true, forKey: SidebarWorkspaceDetailDefaults.showAgentUsageKey)
        coordinator.settingsDidChange()
        await coordinator.waitUntilIdle()
        #expect(metadata.agentUsageByStatusKey["claude_code"]?.contextFraction == 0.2)
        #expect(coordinator.scheduledFlushCount > 0)

        // Hiding metadata rows also stops (and clears) agent usage.
        defaults.set(false, forKey: SidebarCatalogSection().showCustomMetadata.userDefaultsKey)
        coordinator.settingsDidChange()
        #expect(metadata.agentUsageByStatusKey.isEmpty)
    }

    @Test func turningOffEveryPartStopsSampling() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = try Self.claudeTranscript(contextTokens: 200_000, in: directory, name: "a")
        let workspaceID = UUID()
        let defaults = Self.makeDefaults(enabled: true)
        for key in [
            SidebarWorkspaceDetailDefaults.showAgentModelKey,
            SidebarWorkspaceDetailDefaults.showAgentContextKey,
            SidebarWorkspaceDetailDefaults.showAgentCostKey,
        ] {
            defaults.set(false, forKey: key)
        }
        let metadata = WorkspaceSidebarMetadataModel(limitProvider: UnlimitedSidebarLog())
        let coordinator = SidebarAgentUsageCoordinator(defaults: defaults, coalesceInterval: .zero) { id in
            id == workspaceID ? metadata : nil
        }

        coordinator.noteHookEvent(Self.event(.preToolUse, session: "A", workspace: workspaceID, transcript: path, at: 1))
        await coordinator.waitUntilIdle()
        #expect(coordinator.scheduledFlushCount == 0)

        // One part back on resamples without waiting for a hook event.
        defaults.set(true, forKey: SidebarWorkspaceDetailDefaults.showAgentContextKey)
        coordinator.settingsDidChange()
        await coordinator.waitUntilIdle()
        #expect(metadata.agentUsageByStatusKey["claude_code"]?.contextFraction == 0.2)
    }

    @Test func snapshotRowLeavesOutADisabledPart() {
        let defaults = Self.makeDefaults(enabled: true)
        defaults.set(false, forKey: SidebarWorkspaceDetailDefaults.showAgentModelKey)
        let workspace = Workspace()
        workspace.statusEntries["claude_code"] = Self.statusEntry(key: "claude_code", value: "Running")
        workspace.sidebarMetadata.updateAgentUsage(Self.usage, forStatusKey: "claude_code")

        let snapshot = SidebarWorkspaceSnapshotFactory(
            workspace: workspace, settings: SidebarTabItemSettingsSnapshot(defaults: defaults), showsAgentActivity: false
        ).makeSnapshot()
        // The percent and currency follow `Locale.current`, so assert the
        // model is gone and the rest is still appended rather than exact text.
        let row = snapshot.metadataEntries.first { $0.key == "claude_code" }?.value
        #expect(row?.hasPrefix("Running" + SidebarAgentUsageFormatter.separator) == true)
        #expect(row?.contains("Opus 4.8") == false)
    }

    @Test func resumingTheSameTranscriptKeepsUsageAndPaddedWorkspaceIdsResolve() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = try Self.claudeTranscript(contextTokens: 100_000, in: directory, name: "a")
        let workspaceID = UUID()
        let metadata = WorkspaceSidebarMetadataModel(limitProvider: UnlimitedSidebarLog())
        let coordinator = SidebarAgentUsageCoordinator(
            defaults: Self.makeDefaults(enabled: true),
            coalesceInterval: .zero
        ) { id in id == workspaceID ? metadata : nil }
        func shownFraction() -> Double? { metadata.agentUsageByStatusKey["claude_code"]?.contextFraction }

        coordinator.noteHookEvent(Self.event(.preToolUse, session: "A", workspace: workspaceID, transcript: path, at: 1, workspaceIdPadding: "\n"))
        await coordinator.waitUntilIdle()
        #expect(shownFraction() == 0.1)

        // A SessionStart for the same transcript (resume, compaction) does not blank the row.
        coordinator.noteHookEvent(Self.event(.sessionStart, session: "A", workspace: workspaceID, transcript: path, at: 2))
        #expect(shownFraction() == 0.1)
        await coordinator.waitUntilIdle()
        #expect(shownFraction() == 0.1)

        // End then resume with the same id and transcript: the forget is ordered before the new read.
        coordinator.noteHookEvent(Self.event(.sessionEnd, session: "A", workspace: workspaceID, transcript: path, at: 3))
        coordinator.noteHookEvent(Self.event(.sessionStart, session: "A", workspace: workspaceID, transcript: path, at: 4))
        await coordinator.waitUntilIdle()
        #expect(shownFraction() == 0.1)
    }
}
