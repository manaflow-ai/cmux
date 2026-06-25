import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior tests for the monitor's evaluate core: warn exactly once per genuine
/// bypass, never for tracked panes, reset on hook-gain / process-exit / new
/// session, and the grace window across ticks. Driven with fake inputs so no
/// process capture is needed.
@MainActor
@Suite struct UntrackedAgentSessionMonitorTests {
    typealias PanelKey = RestorableAgentSessionIndex.PanelKey

    private func key(_ n: Int) -> PanelKey {
        PanelKey(
            workspaceId: UUID(uuidString: "00000000-0000-0000-0000-0000000000\(String(format: "%02d", n))")!,
            panelId: UUID(uuidString: "11111111-0000-0000-0000-0000000000\(String(format: "%02d", n))")!
        )
    }

    private func agent(_ identity: String, kind: RestorableAgentKind = .claude) -> UntrackedAgentSessionMonitor.DetectedAgent {
        UntrackedAgentSessionMonitor.DetectedAgent(kind: kind, identity: identity)
    }

    /// Builds a monitor with a 10s grace, recording delivered warnings.
    private func makeMonitor(enabled: Bool = true) -> (UntrackedAgentSessionMonitor, () -> [PanelKey]) {
        var delivered: [PanelKey] = []
        let monitor = UntrackedAgentSessionMonitor(
            detector: UntrackedAgentSessionDetector(graceInterval: 10),
            warningEnabled: { enabled },
            deliver: { key, _ in delivered.append(key) }
        )
        return (monitor, { delivered })
    }

    @Test func warnsOncePastGraceAndNotAgainNextTick() {
        let (monitor, delivered) = makeMonitor()
        let k = key(1)
        let agents = [k: agent("sess-A")]
        let noHook: (PanelKey) -> Bool = { _ in false }

        // First sight at t=0: within grace, no warn.
        monitor.evaluate(detectedAgents: agents, hasHookSession: noHook, now: 0)
        #expect(delivered().isEmpty)
        // t=12 (past grace): warn once.
        monitor.evaluate(detectedAgents: agents, hasHookSession: noHook, now: 12)
        #expect(delivered() == [k])
        // t=20 still bypassed: no re-warn.
        monitor.evaluate(detectedAgents: agents, hasHookSession: noHook, now: 20)
        #expect(delivered() == [k]) // still just one
    }

    @Test func trackedPaneNeverWarns() {
        let (monitor, delivered) = makeMonitor()
        let k = key(1)
        let agents = [k: agent("sess-A")]
        // Hook present from the start.
        monitor.evaluate(detectedAgents: agents, hasHookSession: { _ in true }, now: 0)
        monitor.evaluate(detectedAgents: agents, hasHookSession: { _ in true }, now: 60)
        #expect(delivered().isEmpty)
        #expect(monitor.trackedPaneCountForTesting == 0)
    }

    @Test func gainingHookBeforeGraceNeverWarns() {
        // Covers R2: a session that fires SessionStart within grace is never flagged.
        let (monitor, delivered) = makeMonitor()
        let k = key(1)
        let agents = [k: agent("sess-A")]
        monitor.evaluate(detectedAgents: agents, hasHookSession: { _ in false }, now: 0)   // detected, no hook
        monitor.evaluate(detectedAgents: agents, hasHookSession: { _ in true }, now: 5)    // hook arrived within grace
        monitor.evaluate(detectedAgents: agents, hasHookSession: { _ in true }, now: 30)
        #expect(delivered().isEmpty)
    }

    @Test func processExitThenNewBypassedSessionWarnsAgain() {
        let (monitor, delivered) = makeMonitor()
        let k = key(1)
        let noHook: (PanelKey) -> Bool = { _ in false }

        // Session A: warns once past grace.
        monitor.evaluate(detectedAgents: [k: agent("sess-A")], hasHookSession: noHook, now: 0)
        monitor.evaluate(detectedAgents: [k: agent("sess-A")], hasHookSession: noHook, now: 12)
        #expect(delivered() == [k])

        // Process exits (pane no longer detected): state pruned.
        monitor.evaluate(detectedAgents: [:], hasHookSession: noHook, now: 13)
        #expect(monitor.trackedPaneCountForTesting == 0)

        // New bypassed session B in the same pane: clock restarts, warns again past grace.
        monitor.evaluate(detectedAgents: [k: agent("sess-B")], hasHookSession: noHook, now: 14)
        #expect(delivered() == [k]) // within new grace, not yet
        monitor.evaluate(detectedAgents: [k: agent("sess-B")], hasHookSession: noHook, now: 30)
        #expect(delivered() == [k, k]) // second warn for session B
    }

    @Test func sessionIdChangeInSamePaneResetsGrace() {
        let (monitor, delivered) = makeMonitor()
        let k = key(1)
        let noHook: (PanelKey) -> Bool = { _ in false }
        // Session A detected at t=0.
        monitor.evaluate(detectedAgents: [k: agent("sess-A")], hasHookSession: noHook, now: 0)
        // At t=12, session id is now B (a new session) — clock resets, so within grace, no warn.
        monitor.evaluate(detectedAgents: [k: agent("sess-B")], hasHookSession: noHook, now: 12)
        #expect(delivered().isEmpty)
        // t=24: B is now past its own grace -> warn.
        monitor.evaluate(detectedAgents: [k: agent("sess-B")], hasHookSession: noHook, now: 24)
        #expect(delivered() == [k])
    }

    @Test func twoPanesOneTrackedOneBypassedOnlyBypassedWarns() {
        let (monitor, delivered) = makeMonitor()
        let tracked = key(1)
        let bypassed = key(2)
        let agents = [tracked: agent("sess-T"), bypassed: agent("sess-B")]
        let hook: (PanelKey) -> Bool = { $0 == tracked }
        monitor.evaluate(detectedAgents: agents, hasHookSession: hook, now: 0)
        monitor.evaluate(detectedAgents: agents, hasHookSession: hook, now: 15)
        #expect(delivered() == [bypassed])
    }

    // MARK: - Live detection source: claude/codex are detected by process name

    @Test func supportedAgentKindMatchesClaudeAndCodexByExecutableName() {
        // Claude/Codex are NOT in the vault process-detection registry, so the
        // live path must recognize them by executable basename.
        #expect(UntrackedAgentSessionMonitor.supportedAgentKind(processName: "claude", path: nil) == .claude)
        #expect(UntrackedAgentSessionMonitor.supportedAgentKind(processName: "codex", path: nil) == .codex)
        // Full path wins over the (possibly truncated) name.
        #expect(UntrackedAgentSessionMonitor.supportedAgentKind(processName: "claude", path: "/Users/me/.local/bin/claude") == .claude)
        #expect(UntrackedAgentSessionMonitor.supportedAgentKind(processName: "CODEX", path: nil) == .codex) // case-insensitive
    }

    @Test func supportedAgentKindRejectsNonAgentProcesses() {
        #expect(UntrackedAgentSessionMonitor.supportedAgentKind(processName: "node", path: nil) == nil)
        #expect(UntrackedAgentSessionMonitor.supportedAgentKind(processName: "bun", path: nil) == nil)
        #expect(UntrackedAgentSessionMonitor.supportedAgentKind(processName: "zsh", path: "/bin/zsh") == nil)
        #expect(UntrackedAgentSessionMonitor.supportedAgentKind(processName: "", path: nil) == nil)
    }

    @Test func disabledSettingNeverWarns() {
        let (monitor, delivered) = makeMonitor(enabled: false)
        let k = key(1)
        monitor.evaluate(detectedAgents: [k: agent("sess-A")], hasHookSession: { _ in false }, now: 0)
        monitor.evaluate(detectedAgents: [k: agent("sess-A")], hasHookSession: { _ in false }, now: 999)
        #expect(delivered().isEmpty)
    }
}
