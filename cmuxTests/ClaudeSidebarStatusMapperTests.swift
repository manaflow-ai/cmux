#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif
import Testing
import CmuxAgentChat
import CmuxSidebar
import Foundation

@MainActor
@Suite struct ClaudeSidebarStatusMapperTests {
    @Test func codexKindIsIgnored() {
        #expect(ClaudeSidebarStatusMapper().decision(for: .working(since: Date()), kind: .codex) == .ignore)
    }
    @Test func otherKindIsIgnored() {
        #expect(ClaudeSidebarStatusMapper().decision(for: .idle, kind: .other("amp")) == .ignore)
    }
    @Test func endedClearsTheClaudeKey() {
        #expect(ClaudeSidebarStatusMapper().decision(for: .ended, kind: .claude) == .clear(key: "claude_code"))
    }
    @Test func idleUpsertsIdleRow() {
        guard case let .upsert(entry) = ClaudeSidebarStatusMapper().decision(for: .idle, kind: .claude) else {
            Issue.record("expected upsert"); return
        }
        #expect(entry.key == "claude_code")
        #expect(entry.value == "Idle")
        #expect(entry.icon == "pause.circle.fill")
    }
    @Test func workingUpsertsRunningRow() {
        guard case let .upsert(entry) = ClaudeSidebarStatusMapper().decision(for: .working(since: Date()), kind: .claude) else {
            Issue.record("expected upsert"); return
        }
        #expect(entry.key == "claude_code")
        #expect(entry.value == "Running")
    }
}
