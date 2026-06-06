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
        let resources = URL(fileURLWithPath: "/tmp/cmux DEV test.app/Contents/Resources", isDirectory: true)
        let expected = AgentSessionWebRenderer.Coordinator.shellURL(
            rendererKind: .react,
            resourceDirectoryURL: resources
        )
        let equivalent = resources
            .appendingPathComponent("markdown-viewer", isDirectory: true)
            .appendingPathComponent("webviews-app", isDirectory: true)
            .appendingPathComponent("..", isDirectory: true)
            .appendingPathComponent("webviews-app", isDirectory: true)
            .appendingPathComponent("agent-session.html", isDirectory: false)
        let otherBundledFile = resources
            .appendingPathComponent("markdown-viewer", isDirectory: true)
            .appendingPathComponent("webviews-app", isDirectory: true)
            .appendingPathComponent("diff-viewer.html", isDirectory: false)

        expectTrue(AgentSessionWebRenderer.Coordinator.isTrustedShellURL(expected, expected: expected))
        expectTrue(AgentSessionWebRenderer.Coordinator.isTrustedShellURL(equivalent, expected: expected))
        expectFalse(AgentSessionWebRenderer.Coordinator.isTrustedShellURL(otherBundledFile, expected: expected))
        expectFalse(AgentSessionWebRenderer.Coordinator.isTrustedShellURL(URL(string: "https://example.com"), expected: expected))
    }
}
