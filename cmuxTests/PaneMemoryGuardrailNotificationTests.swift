import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Covers the pure copy mapping that turns a guardrail threshold crossing into a
/// per-pane notification (issue #6313), and the guardrail's per-pane rate-limit
/// (one notification per pane per cooldown, with a bounded, pruned map).
@Suite
struct PaneMemoryGuardrailNotificationTests {
    private let gb: Int64 = 1024 * 1024 * 1024

    private func warning(
        workspaceId: UUID = UUID(),
        panelId: UUID = UUID(),
        paneTitle: String = "Terminal",
        memoryGB: Double,
        command: String?
    ) -> PaneMemoryWarning {
        PaneMemoryWarning(
            workspaceId: workspaceId,
            panelId: panelId,
            workspaceTitle: "Workspace",
            paneTitle: paneTitle,
            memoryBytes: Int64(memoryGB * Double(gb)),
            foregroundCommand: command
        )
    }

    // MARK: - Copy mapping

    @Test
    func subtitleNamesTheForegroundCommandAndMemory() {
        let w = warning(memoryGB: 14, command: "pytest")
        let memory = PaneMemoryWarning.formattedNotificationMemory(w.memoryBytes)
        let content = w.notificationContent
        #expect(content.subtitle.contains(memory))
        #expect(content.subtitle.contains("pytest"))
    }

    @Test
    func subtitleFallsBackToMemoryWhenCommandMissing() {
        let blankCommands: [String?] = [nil, "", "   "]
        for command in blankCommands {
            let w = warning(memoryGB: 9, command: command)
            let memory = PaneMemoryWarning.formattedNotificationMemory(w.memoryBytes)
            #expect(w.notificationContent.subtitle == memory, "blank command should leave just the memory size")
        }
    }

    @Test
    func bodyNamesThePaneAndMemory() {
        let w = warning(paneTitle: "api · pytest", memoryGB: 14, command: "pytest")
        let memory = PaneMemoryWarning.formattedNotificationMemory(w.memoryBytes)
        let content = w.notificationContent
        #expect(content.body.contains("api · pytest"))
        #expect(content.body.contains(memory))
        #expect(!content.title.isEmpty)
    }

    @Test
    func formattedMemoryIsHumanReadableAndNonNegative() {
        #expect(!PaneMemoryWarning.formattedNotificationMemory(8 * gb).isEmpty)
        // Never renders a negative size if a sample ever underflows.
        #expect(PaneMemoryWarning.formattedNotificationMemory(-5) ==
                PaneMemoryWarning.formattedNotificationMemory(0))
    }

    // MARK: - Per-pane rate limit (bounded, pruned)

    @Test
    func firstCrossingNotifiesAndRecordsTime() {
        let w = warning(memoryGB: 9, command: "pytest")
        var lastNotifiedAt: [PaneMemoryPaneKey: Date] = [:]
        let now = Date(timeIntervalSince1970: 1_000)
        let out = PaneMemoryGuardrail.runawayNotificationsToPresent(
            bannersToPresent: [w],
            liveKeys: [w.key],
            now: now,
            cooldown: 300,
            lastNotifiedAt: &lastNotifiedAt
        )
        #expect(out.map(\.panelId) == [w.panelId])
        #expect(lastNotifiedAt[w.key] == now)
    }

    @Test
    func reNotificationIsSuppressedWithinCooldownThenAllowedAfter() {
        let w = warning(memoryGB: 9, command: "pytest")
        var lastNotifiedAt: [PaneMemoryPaneKey: Date] = [:]
        let t0 = Date(timeIntervalSince1970: 1_000)

        _ = PaneMemoryGuardrail.runawayNotificationsToPresent(
            bannersToPresent: [w], liveKeys: [w.key], now: t0, cooldown: 300, lastNotifiedAt: &lastNotifiedAt
        )

        // Still inside the 300s window: suppressed, recorded time unchanged.
        let within = PaneMemoryGuardrail.runawayNotificationsToPresent(
            bannersToPresent: [w], liveKeys: [w.key], now: t0.addingTimeInterval(100), cooldown: 300, lastNotifiedAt: &lastNotifiedAt
        )
        #expect(within.isEmpty)
        #expect(lastNotifiedAt[w.key] == t0)

        // After the window: notifies again and advances the timestamp.
        let after = PaneMemoryGuardrail.runawayNotificationsToPresent(
            bannersToPresent: [w], liveKeys: [w.key], now: t0.addingTimeInterval(400), cooldown: 300, lastNotifiedAt: &lastNotifiedAt
        )
        #expect(after.map(\.panelId) == [w.panelId])
        #expect(lastNotifiedAt[w.key] == t0.addingTimeInterval(400))
    }

    @Test
    func closedPanesArePrunedSoTheMapStaysBounded() {
        let live = warning(memoryGB: 9, command: "pytest")
        let closedKey = PaneMemoryPaneKey(workspaceId: UUID(), panelId: UUID())
        var lastNotifiedAt: [PaneMemoryPaneKey: Date] = [
            live.key: Date(timeIntervalSince1970: 1),
            closedKey: Date(timeIntervalSince1970: 1),
        ]
        // No crossings this tick; only the live pane survives in the map.
        let out = PaneMemoryGuardrail.runawayNotificationsToPresent(
            bannersToPresent: [],
            liveKeys: [live.key],
            now: Date(timeIntervalSince1970: 2),
            cooldown: 300,
            lastNotifiedAt: &lastNotifiedAt
        )
        #expect(out.isEmpty)
        #expect(Set(lastNotifiedAt.keys) == [live.key], "closed pane's rate-limit entry must be pruned")
    }

    // MARK: - Engine → notification seam

    /// A single threshold crossing maps to exactly one notification for that
    /// pane, and staying high does not re-fire (engine edge-trigger).
    @Test
    func engineCrossingProducesExactlyOneNotificationPerPane() {
        var engine = PaneMemoryGuardrailEngine()
        let ws = UUID(), pane = UUID()
        let descriptor = PaneMemoryDescriptor(
            workspaceId: ws,
            panelId: pane,
            workspaceTitle: "Workspace",
            paneTitle: "Terminal",
            ttyName: "/dev/ttys003",
            foregroundPID: 99
        )
        let sample = PaneMemorySample(
            descriptor: descriptor,
            memoryBytes: 9 * gb,
            residentBytes: 9 * gb,
            memoryPressureProcessGroupIDs: [200],
            foregroundCommand: "pytest"
        )

        let crossing = engine.ingest(samples: [sample], thresholdBytes: 8 * gb)
        let contents = crossing.bannersToPresent.map(\.notificationContent)
        #expect(contents.count == 1)
        #expect(contents.first?.subtitle.contains("pytest") == true)

        // Edge-trigger: a pane that stays high does not produce a second notification.
        let stillHigh = engine.ingest(samples: [sample], thresholdBytes: 8 * gb)
        #expect(stillHigh.bannersToPresent.isEmpty)
    }
}
