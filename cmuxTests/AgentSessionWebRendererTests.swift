import CmuxFoundation
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
        let expected = AgentSessionWebRendererCoordinator.shellURL(
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

        expectTrue(expected.isTrustedShellURL(expected: expected))
        expectTrue(equivalent.isTrustedShellURL(expected: expected))
        expectFalse(otherBundledFile.isTrustedShellURL(expected: expected))
        expectFalse(URL(string: "https://example.com")?.isTrustedShellURL(expected: expected) ?? false)
    }
}
