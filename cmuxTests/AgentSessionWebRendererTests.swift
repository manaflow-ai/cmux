import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

@Suite(.serialized)
struct AgentSessionWebRendererTests {
    @Test
    func testTrustedShellURLAcceptsOnlyMatchingFileURL() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let expected = directory.appendingPathComponent("agent-session.html")
        let equivalent = directory
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("..", isDirectory: true)
            .appendingPathComponent("agent-session.html")
        let otherBundledFile = directory.appendingPathComponent("diff-viewer.html")

        expectTrue(AgentSessionWebRendererCoordinator.isTrustedShellURL(expected, expected: expected))
        expectTrue(AgentSessionWebRendererCoordinator.isTrustedShellURL(equivalent, expected: expected))
        expectFalse(AgentSessionWebRendererCoordinator.isTrustedShellURL(otherBundledFile, expected: expected))
        expectFalse(AgentSessionWebRendererCoordinator.isTrustedShellURL(URL(string: "https://example.com"), expected: expected))
    }
}
