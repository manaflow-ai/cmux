import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior tests for the point-in-time diagnostics classifier: tracked vs
/// untracked vs unsupported per pane, the untracked headline count, and the
/// stable untracked-first ordering.
@Suite struct UntrackedAgentSessionDiagnosticsTests {
    typealias PanelKey = RestorableAgentSessionIndex.PanelKey

    private func key(_ n: Int) -> PanelKey {
        PanelKey(
            workspaceId: UUID(uuidString: "00000000-0000-0000-0000-0000000000\(String(format: "%02d", n))")!,
            panelId: UUID(uuidString: "11111111-0000-0000-0000-0000000000\(String(format: "%02d", n))")!
        )
    }

    private let diag = UntrackedAgentSessionDiagnostics()

    @Test func classifiesTrackedUntrackedAndUnsupported() {
        let tracked = key(1)
        let untracked = key(2)
        let unsupported = key(3)
        let agents: [PanelKey: RestorableAgentKind] = [
            tracked: .claude,
            untracked: .claude,
            unsupported: .gemini,
        ]
        let reports = diag.classify(detectedAgents: agents, hasHookSession: { $0 == tracked })
        let byKey = Dictionary(uniqueKeysWithValues: reports.map { ($0.key, $0.status) })
        #expect(byKey[tracked] == .tracked)
        #expect(byKey[untracked] == .untracked)
        #expect(byKey[unsupported] == .unsupportedAgent(.gemini))
    }

    @Test func untrackedCountIsTheHeadline() {
        let agents: [PanelKey: RestorableAgentKind] = [
            key(1): .claude, // untracked
            key(2): .codex,  // untracked
            key(3): .claude, // tracked
            key(4): .gemini, // unsupported
        ]
        let reports = diag.classify(detectedAgents: agents, hasHookSession: { $0 == key(3) })
        #expect(diag.untrackedCount(reports) == 2)
    }

    @Test func untrackedPanesSortFirst() {
        let agents: [PanelKey: RestorableAgentKind] = [
            key(1): .claude, // tracked
            key(2): .claude, // untracked
            key(3): .gemini, // unsupported
        ]
        let reports = diag.classify(detectedAgents: agents, hasHookSession: { $0 == key(1) })
        #expect(reports.first?.status == .untracked)
        #expect(reports.last.map { if case .unsupportedAgent = $0.status { return true } else { return false } } == true)
    }

    @Test func emptyInputYieldsEmptyReport() {
        #expect(diag.classify(detectedAgents: [:], hasHookSession: { _ in false }).isEmpty)
    }

    @Test func codexIsSupportedSoUntrackedNotUnsupported() {
        let k = key(1)
        let reports = diag.classify(detectedAgents: [k: .codex], hasHookSession: { _ in false })
        #expect(reports.first?.status == .untracked)
    }
}
