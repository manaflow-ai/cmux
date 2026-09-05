import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct VaultSessionLiveStatusTests {
    private let now = Date(timeIntervalSince1970: 1_755_000_000)

    @Test
    func runningWithRecentActivityIsLive() {
        let status = VaultSessionLiveStatus.derive(
            isProcessRunning: true,
            lastActivity: now.addingTimeInterval(-VaultSessionLiveStatus.liveActivityWindow),
            now: now
        )
        #expect(status == .live)
    }

    @Test
    func runningWithStaleActivityIsIdle() {
        let status = VaultSessionLiveStatus.derive(
            isProcessRunning: true,
            lastActivity: now.addingTimeInterval(-VaultSessionLiveStatus.liveActivityWindow - 1),
            now: now
        )
        #expect(status == .idle)
    }

    @Test
    func notRunningIsExitedRegardlessOfRecency() {
        let status = VaultSessionLiveStatus.derive(
            isProcessRunning: false,
            lastActivity: now,
            now: now
        )
        #expect(status == .exited)
    }

    @Test
    func joinKeyUsesKindAndCanonicalSessionID() {
        // Canonicalization lowercases UUID-shaped ids for pi-family kinds and
        // passes other ids through; the key is always kind-prefixed.
        let key = VaultLiveSessionKeys.key(kind: "claude", sessionID: "ABC-123")
        #expect(key.hasPrefix("claude:"))

        let entry = SessionEntry(
            id: "claude:/tmp/x.jsonl",
            agent: .claude,
            sessionId: "session-1",
            title: "t",
            cwd: nil,
            gitBranch: nil,
            pullRequest: nil,
            modified: now,
            fileURL: nil,
            specifics: .claude(model: nil, permissionMode: nil, configDirectoryForResume: nil)
        )
        #expect(VaultLiveSessionKeys.key(for: entry)
            == VaultLiveSessionKeys.key(kind: "claude", sessionID: "session-1"))
    }

    @Test
    func runningKeysFromNilIndexIsEmpty() {
        #expect(VaultLiveSessionKeys.runningKeys(in: nil).isEmpty)
    }
}
