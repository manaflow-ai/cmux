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
    func compactIndicatorUsesOnlyBinaryActiveState() {
        #expect(VaultSessionLiveStatus.live.isActiveForIndicator)
        #expect(!VaultSessionLiveStatus.idle.isActiveForIndicator)
        #expect(!VaultSessionLiveStatus.exited.isActiveForIndicator)
        #expect(
            VaultSessionLiveStatus.live.indicatorLabel
                == String(localized: "sessionIndex.status.activeIndicator", defaultValue: "Active")
        )
        #expect(
            VaultSessionLiveStatus.idle.indicatorLabel
                == String(localized: "sessionIndex.status.inactiveIndicator", defaultValue: "Inactive")
        )
    }

    @Test
    func compactIndicatorTreatsEveryRowAsActiveOrInactive() {
        let inPane = SessionIndexStatusIndicatorModel.make(
            isInPane: true,
            liveStatus: .live
        )
        #expect(inPane.isActive)
        #expect(
            inPane.label
                == String(
                    localized: "sessionIndex.status.activeInPane",
                    defaultValue: "Active in pane"
                )
        )

        let exitedInPane = SessionIndexStatusIndicatorModel.make(
            isInPane: true,
            liveStatus: .exited
        )
        #expect(exitedInPane.isActive)
        #expect(
            exitedInPane.label
                == String(
                    localized: "sessionIndex.status.activeInPane",
                    defaultValue: "Active in pane"
                )
        )

        let liveIndexed = SessionIndexStatusIndicatorModel.make(
            isInPane: false,
            liveStatus: .live
        )
        #expect(!liveIndexed.isActive)
        #expect(
            liveIndexed.label
                == String(
                    localized: "sessionIndex.status.inactiveIndicator",
                    defaultValue: "Inactive"
                )
        )

        let idleIndexed = SessionIndexStatusIndicatorModel.make(
            isInPane: false,
            liveStatus: .idle
        )
        #expect(!idleIndexed.isActive)
        #expect(
            idleIndexed.label
                == String(
                    localized: "sessionIndex.status.inactiveIndicator",
                    defaultValue: "Inactive"
                )
        )

        let unknownIndexed = SessionIndexStatusIndicatorModel.make(
            isInPane: false,
            liveStatus: nil
        )
        #expect(!unknownIndexed.isActive)
        #expect(unknownIndexed.label == idleIndexed.label)
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
