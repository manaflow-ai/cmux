import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct SessionRowDirectoryOpenerTests {
    @Test @MainActor func rowMenuActionRoutesWorkingDirectoryThroughFinderOpener() async {
        let cwd = "/private/tmp/cmux-openwd-\(UUID().uuidString)"
        let entry = makeEntry(cwd: cwd)
        var routed: [URL] = []

        let actions = SessionRowMenuActions { routed.append($0) }
        await actions.openWorkingDirectory(for: entry)

        #expect(routed == [URL(fileURLWithPath: cwd)])
    }

    @Test(arguments: [nil, ""])
    @MainActor func rowMenuActionIgnoresMissingWorkingDirectory(cwd: String?) async {
        let entry = makeEntry(cwd: cwd)
        var routed: [URL] = []

        let actions = SessionRowMenuActions { routed.append($0) }
        await actions.openWorkingDirectory(for: entry)

        #expect(routed.isEmpty)
    }

    private func makeEntry(cwd: String?) -> SessionEntry {
        SessionEntry(
            id: "session-row-opener-test-\(UUID().uuidString)",
            agent: .codex,
            sessionId: "codex-session",
            title: "Session row opener test",
            cwd: cwd,
            gitBranch: nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: 0),
            fileURL: nil,
            specifics: .codex(
                model: nil,
                approvalPolicy: nil,
                sandboxMode: nil,
                effort: nil
            )
        )
    }
}
