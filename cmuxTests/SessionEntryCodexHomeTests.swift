import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct SessionEntryCodexHomeTests {
    @Test func indexedAccountWinsOverExternalRolloutLocation() throws {
        let entry = makeEntry(path: "/shared/transcripts/rollout.jsonl", home: "/account")
        #expect(entry.codexHomeForResume == "/account")
        let launch = try #require(entry.resumeLaunch?.startupRestoreAgent?.launchCommand)
        #expect(launch.environment?["CODEX_HOME"] == "/account")
    }

    @Test(arguments: ["sessions", "archived_sessions"])
    func fileIndexCarriesItsAccountIntoTheSharedRestorePath(directory: String) throws {
        let entry = makeEntry(path: "/account/\(directory)/2026/09/rollout.jsonl")
        let launch = try #require(entry.resumeLaunch)
        #expect(launch.strategy == .restoreVerb)
        #expect(launch.startupRestoreAgent?.launchCommand?.environment?["CODEX_HOME"] == "/account")
    }

    private func makeEntry(path: String, home: String? = nil) -> SessionEntry {
        SessionEntry(
            id: "codex:test", agent: .codex, sessionId: UUID().uuidString,
            title: "Fixture", cwd: "/project", gitBranch: nil, pullRequest: nil,
            modified: Date(timeIntervalSince1970: 0), fileURL: URL(fileURLWithPath: path),
            specifics: .codex(model: nil, approvalPolicy: nil, sandboxMode: nil, effort: nil),
            indexedCodexHome: home
        )
    }
}
