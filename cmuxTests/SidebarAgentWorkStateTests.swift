import AppKit
import CmuxControlSocket
import CmuxSidebar
import Testing
@testable import cmux_DEV

/// The two richer running states an agent hook can report through
/// `set_status --work=`: running through subagents, and waiting on a
/// deterministic wakeup.
@Suite(.serialized)
@MainActor
struct SidebarAgentWorkStateTests {
    private typealias Glyph = SidebarCompactStatusGlyph

    private static func entry(
        _ key: String,
        _ value: String,
        workState: SidebarAgentWorkState?
    ) -> SidebarStatusEntry {
        SidebarStatusEntry(key: key, value: value, icon: "bolt.fill", color: "#4C8DFF", workState: workState)
    }

    // MARK: Parsing

    @Test
    func parseAcceptsTheReportedSpellingsAndRejectsEverythingElse() {
        #expect(SidebarAgentWorkState.parse("running") == .running)
        #expect(SidebarAgentWorkState.parse(" Subagents ") == .subagents)
        #expect(SidebarAgentWorkState.parse("WAITING") == .waiting)
        #expect(SidebarAgentWorkState.parse("compacting") == nil)
        #expect(SidebarAgentWorkState.parse("") == nil)
        // The singular reads like it should work, and it must not: the
        // control socket rejects the whole `set_status` for it, so a parse
        // that accepted it here would describe a state the app never sees.
        #expect(SidebarAgentWorkState.parse("subagent") == nil)
    }

    /// The wire contract is three raw strings repeated in modules that
    /// deliberately do not depend on each other. Nothing else fails if one
    /// copy is renamed, so pin the two that link here; the CLI's third copy
    /// is pinned on the wire by `ClaudeHookWorkStateTests` and
    /// `ClaudeBackgroundWorkNotifyTests`, which read the emitted `--work=`.
    @Test
    func theThreeCopiesOfTheWireContractAgree() {
        #expect(SidebarAgentWorkState.allCases.map(\.rawValue) == ["running", "subagents", "waiting"])
        #expect(
            ControlSidebarAgentWorkState.allCases.map(\.rawValue)
                == SidebarAgentWorkState.allCases.map(\.rawValue)
        )
        for state in ControlSidebarAgentWorkState.allCases {
            #expect(SidebarAgentWorkState(rawValue: state.rawValue) != nil,
                    "The control socket's '\(state.rawValue)' has no sidebar twin")
        }
    }

    // MARK: Resolution

    @Test
    func subagentsOutranksRunning() {
        let glyph = Glyph.resolve(Glyph.Input(
            agentEntries: [Self.entry("claude_code", "Running subagents", workState: .subagents)],
            lifecycleStates: [.running],
            hasActiveAgent: true
        ))
        #expect(glyph.kind == .subagents)
    }

    /// Waiting reports a running lifecycle on purpose: a pane with live
    /// background work must not look hibernatable. The glyph still has to say
    /// waiting, which is the regression this whole state exists for.
    @Test
    func waitingWinsOverItsOwnRunningLifecycle() {
        let glyph = Glyph.resolve(Glyph.Input(
            agentEntries: [Self.entry("claude_code", "Waiting", workState: .waiting)],
            lifecycleStates: [.running],
            hasActiveAgent: true
        ))
        #expect(glyph.kind == .waiting)
    }

    @Test
    func oneAgentStillWorkingKeepsTheRowRunning() {
        let glyph = Glyph.resolve(Glyph.Input(
            agentEntries: [
                Self.entry("claude_code", "Waiting", workState: .waiting),
                Self.entry("codex", "Running", workState: .running),
            ],
            lifecycleStates: [.running],
            hasActiveAgent: true
        ))
        #expect(glyph.kind == .running)
    }

    /// An agent that reports no work state says nothing about whether it is
    /// parked, so its workspace cannot be called waiting on the strength of
    /// another agent's report.
    @Test
    func anAgentWithoutAWorkStateKeepsTheRowRunning() {
        let glyph = Glyph.resolve(Glyph.Input(
            agentEntries: [
                Self.entry("claude_code", "Waiting", workState: .waiting),
                Self.entry("codex", "Running", workState: nil),
            ],
            lifecycleStates: [.running],
            hasActiveAgent: true
        ))
        #expect(glyph.kind == .running)
    }

    /// Status entries are keyed per workspace and lifecycle states per panel,
    /// so two Claude panes in one workspace share a single `claude_code`
    /// entry: the pane that reports last wins. A pane parked on background
    /// work must not put an hourglass over a sibling pane that is still
    /// working, so a running lifecycle that no waiting report accounts for
    /// keeps the row running.
    @Test
    func aSecondPaneStillWorkingUnderTheSharedKeyKeepsTheRowRunning() {
        let glyph = Glyph.resolve(Glyph.Input(
            agentEntries: [Self.entry("claude_code", "Waiting", workState: .waiting)],
            lifecycleStates: [.running, .running],
            hasActiveAgent: true
        ))
        #expect(glyph.kind == .running)
    }

    /// The same workspace once the sibling pane goes idle: one running
    /// lifecycle, one waiting report, so the hourglass is honest again.
    @Test
    func theHourglassReturnsOnceTheSiblingPaneIsDone() {
        let glyph = Glyph.resolve(Glyph.Input(
            agentEntries: [Self.entry("claude_code", "Waiting", workState: .waiting)],
            lifecycleStates: [.running, .idle],
            hasActiveAgent: true
        ))
        #expect(glyph.kind == .waiting)
    }

    /// Two agents under two keys, both parked, is the ordinary all-waiting
    /// case and still reads as waiting.
    @Test
    func twoAgentsBothParkedStayWaiting() {
        let glyph = Glyph.resolve(Glyph.Input(
            agentEntries: [
                Self.entry("claude_code", "Waiting", workState: .waiting),
                Self.entry("codex", "Waiting", workState: .waiting),
            ],
            lifecycleStates: [.running, .running],
            hasActiveAgent: true
        ))
        #expect(glyph.kind == .waiting)
    }

    @Test
    func needsInputAndErrorStillOutrankBothNewStates() {
        #expect(Glyph.resolve(Glyph.Input(
            agentEntries: [Self.entry("claude_code", "Running subagents", workState: .subagents)],
            lifecycleStates: [.needsInput, .running],
            hasActiveAgent: true
        )).kind == .needsInput)
        #expect(Glyph.resolve(Glyph.Input(
            agentEntries: [
                SidebarStatusEntry(
                    key: "claude_code",
                    value: "Failed",
                    icon: "exclamationmark.triangle.fill",
                    workState: .waiting
                )
            ],
            lifecycleStates: [.running],
            hasActiveAgent: true
        )).kind == .error)
    }

    @Test
    func anEntryWithoutAWorkStateResolvesExactlyAsBefore() {
        let glyph = Glyph.resolve(Glyph.Input(
            agentEntries: [Self.entry("claude_code", "Running", workState: nil)],
            lifecycleStates: [.running],
            hasActiveAgent: true
        ))
        #expect(glyph.kind == .running)
    }

    // MARK: Presentation

    @Test
    func theNewStatesDrawCalmSymbolsRatherThanMoreDots() {
        let subagents = Glyph(kind: .subagents, tooltip: "")
        let waiting = Glyph(kind: .waiting, tooltip: "")
        #expect(subagents.defaultSymbolName == "point.3.filled.connected.trianglepath.dotted")
        #expect(waiting.defaultSymbolName == "hourglass")
        // Symbols draw full size; only the three dots shrink.
        #expect(subagents.sizeScale == 1)
        #expect(waiting.sizeScale == 1)
        #expect(Glyph(kind: .running, tooltip: "").sizeScale == 0.6)
    }

    @Test
    func subagentsPulsesBecauseItIsRunningAndWaitingDoesNot() {
        #expect(Glyph(kind: .subagents, tooltip: "").pulses)
        #expect(!Glyph(kind: .waiting, tooltip: "").pulses)
    }

    @Test
    func bothNewStatesStaySecondaryGrayAndTakeTheSelectionColorWhenActive() {
        for kind in [Glyph.Kind.subagents, .waiting] {
            let glyph = Glyph(kind: kind, tooltip: "")
            #expect(glyph.color(isActive: false, selected: .white, secondary: .secondaryLabelColor) == .secondaryLabelColor)
            #expect(glyph.color(isActive: true, selected: .white, secondary: .secondaryLabelColor) == .white)
        }
    }

    @Test
    func bothNewStatesAreConfigurableIconSlots() {
        #expect(Glyph(kind: .subagents, tooltip: "").iconSlot == .subagents)
        #expect(Glyph(kind: .waiting, tooltip: "").iconSlot == .waiting)
        let overrides = Glyph.validIconOverrides(["subagents": "circle.grid.2x2", "waiting": "clock"])
        #expect(overrides == ["subagents": "circle.grid.2x2", "waiting": "clock"])
        #expect(Glyph(kind: .waiting, tooltip: "", iconOverrides: overrides).symbolName == "clock")
    }

    // MARK: Group headers

    @Test
    func groupHeadersRankSubagentsWithRunningAndWaitingBelowIt() {
        func member(_ title: String, _ kind: Glyph.Kind) -> Glyph.GroupMember {
            Glyph.GroupMember(title: title, glyph: Glyph(kind: kind, tooltip: "detail"))
        }
        #expect(Glyph.rollUp([member("a", .running), member("b", .subagents)])?.kind == .subagents)
        #expect(Glyph.rollUp([member("a", .waiting), member("b", .running)])?.kind == .running)
        #expect(Glyph.rollUp([member("a", .waiting), member("b", .unseen)])?.kind == .waiting)
        #expect(Glyph.rollUp([member("a", .waiting), member("b", .needsInput)])?.kind == .needsInput)
    }

    @Test
    func unreadNotificationsDoNotOverrideEitherNewState() {
        for kind in [Glyph.Kind.subagents, .waiting] {
            let glyph = Glyph(kind: kind, tooltip: "Claude Code: Waiting")
                .applyingUnread(3, latestNotificationText: "Finished")
            #expect(glyph.kind == kind)
            #expect(glyph.tooltip == "Finished\nClaude Code: Waiting")
        }
    }
}
