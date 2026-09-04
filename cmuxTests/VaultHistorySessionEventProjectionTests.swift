import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct VaultHistorySessionEventProjectionTests {
    @Test func projectionProducesStableDerivedEvents() throws {
        let entry = SessionEntry(
            id: "abc123",
            agent: .claude,
            sessionId: "abc123",
            title: "Fix the tests",
            cwd: "/tmp/repo",
            gitBranch: nil,
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: 1_700_000_000),
            fileURL: nil,
            specifics: .claude(
                model: nil,
                permissionMode: nil,
                configDirectoryForResume: nil
            )
        )
        let projection = VaultHistorySessionEventProjection()

        let first = projection.events(from: [entry])
        let second = projection.events(from: [entry])
        #expect(first == second)

        let event = try #require(first.first)
        #expect(event.id == "session:claude:abc123")
        #expect(event.kind == .sessionActivity)
        #expect(event.timestamp == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(event.title == "Fix the tests")
        #expect(event.subject.agent == "claude")
        #expect(event.subject.sessionId == "abc123")
        #expect(event.subject.directory == "/tmp/repo")
    }
}
