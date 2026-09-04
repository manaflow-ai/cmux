import AppKit
import Bonsplit
import CMUXAgentLaunch
import CmuxCore
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Compatibility fallbacks must quote identifiers before a rendered command
/// is typed into a terminal, even when a structured restore snapshot is absent.
@MainActor
@Suite(.serialized)
struct VaultRestoreCompatibilitySecurityTests {
    @Test(arguments: ["claude", "codex"])
    func invalidBuiltInSessionIDsAreQuotedInCompatibilityInput(_ rawKind: String) throws {
        let unsafeSessionID = "bad;echo-pwned"
        let specifics: AgentSpecifics = rawKind == "claude"
            ? .claude(model: nil, permissionMode: nil, configDirectoryForResume: nil)
            : .codex(model: nil, approvalPolicy: nil, sandboxMode: nil, effort: nil)
        let entry = SessionEntry(
            id: "\(rawKind):\(unsafeSessionID)",
            agent: rawKind == "claude" ? .claude : .codex,
            sessionId: unsafeSessionID,
            title: "Unsafe \(rawKind) session",
            cwd: nil,
            gitBranch: nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: 1_800_000_107),
            fileURL: nil,
            specifics: specifics
        )
        let launch = try #require(entry.resumeLaunch)

        #expect(launch.strategy == .legacyCommand)
        #expect(launch.legacyFallbackReason == .missingStructuredSnapshot)
        #expect(!launch.initialInput.contains("--resume \(unsafeSessionID)"))
        #expect(!launch.initialInput.contains("resume \(unsafeSessionID)"))
    }
}
