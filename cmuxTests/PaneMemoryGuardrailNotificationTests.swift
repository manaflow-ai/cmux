import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Covers the pure copy/cooldown mapping that turns a guardrail threshold
/// crossing into a per-pane notification (issue #6313), plus the engine →
/// notification seam so a crossing produces exactly one notification per pane.
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

    @Test
    func cooldownKeyIsStablePerPanel() {
        let panelId = UUID()
        let content = PaneMemoryGuardrailNotification.content(
            for: warning(panelId: panelId, memoryGB: 14, command: "pytest")
        )
        #expect(content.cooldownKey == "paneMemoryGuardrail.\(panelId.uuidString)")
        #expect(
            PaneMemoryGuardrailNotification.cooldownKey(forPanelId: panelId) == content.cooldownKey
        )
    }

    @Test
    func differentPanesGetDifferentCooldownKeys() {
        let a = PaneMemoryGuardrailNotification.cooldownKey(forPanelId: UUID())
        let b = PaneMemoryGuardrailNotification.cooldownKey(forPanelId: UUID())
        #expect(a != b)
    }

    @Test
    func subtitleNamesTheForegroundCommandAndMemory() {
        let w = warning(memoryGB: 14, command: "pytest")
        let memory = PaneMemoryGuardrailNotification.formattedMemory(w.memoryBytes)
        let content = PaneMemoryGuardrailNotification.content(for: w)
        #expect(content.subtitle.contains(memory))
        #expect(content.subtitle.contains("pytest"))
    }

    @Test
    func subtitleFallsBackToMemoryWhenCommandMissing() {
        let blankCommands: [String?] = [nil, "", "   "]
        for command in blankCommands {
            let w = warning(memoryGB: 9, command: command)
            let memory = PaneMemoryGuardrailNotification.formattedMemory(w.memoryBytes)
            let content = PaneMemoryGuardrailNotification.content(for: w)
            #expect(content.subtitle == memory, "blank command should leave just the memory size")
        }
    }

    @Test
    func bodyNamesThePaneAndMemory() {
        let w = warning(paneTitle: "api · pytest", memoryGB: 14, command: "pytest")
        let memory = PaneMemoryGuardrailNotification.formattedMemory(w.memoryBytes)
        let content = PaneMemoryGuardrailNotification.content(for: w)
        #expect(content.body.contains("api · pytest"))
        #expect(content.body.contains(memory))
        #expect(!content.title.isEmpty)
    }

    @Test
    func formattedMemoryIsHumanReadableAndNonNegative() {
        #expect(!PaneMemoryGuardrailNotification.formattedMemory(8 * gb).isEmpty)
        // Never renders a negative size if a sample ever underflows.
        #expect(PaneMemoryGuardrailNotification.formattedMemory(-5) ==
                PaneMemoryGuardrailNotification.formattedMemory(0))
    }

    /// The behavioral seam: a single threshold crossing in the engine maps to
    /// exactly one notification for that pane, and staying high does not re-fire.
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
        let contents = crossing.bannersToPresent.map(PaneMemoryGuardrailNotification.content(for:))
        #expect(contents.count == 1)
        #expect(contents.first?.cooldownKey == "paneMemoryGuardrail.\(pane.uuidString)")
        #expect(contents.first?.subtitle.contains("pytest") == true)

        // Edge-trigger: a pane that stays high does not produce a second notification.
        let stillHigh = engine.ingest(samples: [sample], thresholdBytes: 8 * gb)
        #expect(stillHigh.bannersToPresent.isEmpty)
    }
}
